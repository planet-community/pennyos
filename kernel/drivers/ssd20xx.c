// SPDX-License-Identifier: GPL-2.0
/*
 * Solomon Systech SSD20xx TDDI touchscreen (SSD2092 / SSD2098), as found in the
 * Planet Computers Cosmo Communicator's main panel.
 *
 * Minimal driver written for the pennyos mainline port from the protocol used
 * by the vendor driver (drivers/input/touchscreen/mediatek/SSD209XX): firmware
 * lives in the chip's flash, the host only has to release the touch MCU from
 * reset and then read 6-byte point records when the interrupt line goes low.
 * No firmware update, gestures, low-power mode or ESD recovery.
 */

#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/input.h>
#include <linux/input/mt.h>
#include <linux/input/touchscreen.h>
#include <linux/interrupt.h>
#include <linux/module.h>
#include <linux/notifier.h>
#include <linux/workqueue.h>
#include <linux/of.h>

/* "DS" (boot ROM) commands, valid right after reset */
#define SSD_DS_CLEAR_INT	0x0001
#define SSD_DS_CPU_CONTROL	0x0002
#define SSD_DS_EFLASH_WRITE	0x0004

/* Touch MCU ("TMC") registers, valid once the firmware runs */
#define SSD_INT_CLEAR		0x0043
#define SSD_TOUCH_MODE		0x0050
#define SSD_X_RESOLUTION	0x0056
#define SSD_Y_RESOLUTION	0x0057
#define SSD_AFE_MAX_LIMIT	0x0102
#define SSD_AFE_MIN_LIMIT	0x0103
#define SSD_STATUS_LENGTH	0x0af0
#define SSD_POINT_DATA		0x0af1

#define SSD_STATUS_BOOT		0x80	/* firmware (re)booted, needs config */
#define SSD_STATUS_EVENTS	0x7f

#define SSD_MAX_POINTS		10
#define SSD_POINT_SIZE		6
#define SSD_ID_AXIS_LAST	0x0e

/* the vendor driver leaves ~200us between I2C packets */
#define SSD_I2C_DELAY_US	200

struct ssd20xx {
	struct i2c_client *client;
	struct input_dev *input;
	struct gpio_desc *reset_gpio;
	struct gpio_desc *irq_gpio;
	struct touchscreen_properties prop;
	struct notifier_block panel_nb;
	struct work_struct reboot_work;
	bool irq_off;
};

#if IS_REACHABLE(CONFIG_DRM_PANEL_PLANET_SSD2092)
/* panel half of the TDDI, see drivers/gpu/drm/panel/panel-planet-ssd2092.c */
extern struct blocking_notifier_head cosmo_ssd2092_panel_notifier;
#define SSD_HAVE_PANEL_NOTIFIER 1
#endif

static int ssd20xx_write(struct ssd20xx *ts, u16 reg, const u8 *data, int len)
{
	u8 buf[8];
	int ret;

	if (len > sizeof(buf) - 2)
		return -EINVAL;
	buf[0] = reg & 0xff;
	buf[1] = reg >> 8;
	memcpy(buf + 2, data, len);
	ret = i2c_master_send(ts->client, buf, len + 2);
	usleep_range(SSD_I2C_DELAY_US, SSD_I2C_DELAY_US + 100);
	return ret < 0 ? ret : 0;
}

static int ssd20xx_write16(struct ssd20xx *ts, u16 reg, u16 val)
{
	u8 d[2] = { val & 0xff, val >> 8 };

	return ssd20xx_write(ts, reg, d, 2);
}

/* select with a write, then read in a separate transfer (no repeated start) */
static int ssd20xx_read_sel(struct ssd20xx *ts, const u8 *sel, int sel_len,
			    u8 *data, int len)
{
	int ret;

	ret = i2c_master_send(ts->client, sel, sel_len);
	if (ret < 0)
		return ret;
	usleep_range(SSD_I2C_DELAY_US, SSD_I2C_DELAY_US + 100);
	ret = i2c_master_recv(ts->client, data, len);
	usleep_range(SSD_I2C_DELAY_US, SSD_I2C_DELAY_US + 100);
	return ret < 0 ? ret : 0;
}

static int ssd20xx_read(struct ssd20xx *ts, u16 reg, u8 *data, int len)
{
	u8 sel[2] = { reg & 0xff, reg >> 8 };

	return ssd20xx_read_sel(ts, sel, 2, data, len);
}

/* The chip signals "ready / data pending" by pulling INT low. */
static int ssd20xx_wait_int(struct ssd20xx *ts, int ms)
{
	if (!ts->irq_gpio) {
		msleep(ms);
		return 0;
	}
	while (ms-- > 0) {
		if (gpiod_get_value_cansleep(ts->irq_gpio))	/* active low */
			return 0;
		usleep_range(1000, 1100);
	}
	return -ETIMEDOUT;
}

static int ssd20xx_configure(struct ssd20xx *ts)
{
	struct device *dev = &ts->client->dev;
	u8 d[2];
	int ret;

	ret = ssd20xx_write16(ts, SSD_TOUCH_MODE, 0);	/* point mode */
	if (ret)
		return ret;
	if (!ssd20xx_read(ts, SSD_X_RESOLUTION, d, 2))
		dev_info(dev, "firmware X resolution %u\n", d[0] | d[1] << 8);
	if (!ssd20xx_read(ts, SSD_Y_RESOLUTION, d, 2))
		dev_info(dev, "firmware Y resolution %u\n", d[0] | d[1] << 8);
	ssd20xx_write16(ts, SSD_AFE_MAX_LIMIT, 2700);
	ssd20xx_write16(ts, SSD_AFE_MIN_LIMIT, 50);
	return 0;
}

static int ssd20xx_boot(struct ssd20xx *ts)
{
	struct device *dev = &ts->client->dev;
	static const u8 zero4[4];
	u8 st[2];
	u8 d[4];
	int ret;

	if (ts->reset_gpio) {
		gpiod_set_value_cansleep(ts->reset_gpio, 0);
		msleep(10);
		gpiod_set_value_cansleep(ts->reset_gpio, 1);
		msleep(20);
		gpiod_set_value_cansleep(ts->reset_gpio, 0);
		msleep(80);
	}
	if (ssd20xx_wait_int(ts, 200))
		dev_warn(dev, "INT did not go low after reset\n");

	ret = ssd20xx_read_sel(ts, zero4, 4, st, 2);
	if (ret)
		return dev_err_probe(dev, ret, "cannot read boot status\n");
	dev_info(dev, "boot status 0x%04x\n", st[0] | st[1] << 8);

	/* same two "init code" writes the vendor driver does */
	d[0] = 0x03; d[1] = 0xe0; d[2] = 0x07; d[3] = 0x00;
	ret = ssd20xx_write(ts, SSD_DS_EFLASH_WRITE, d, 4);
	d[0] = 0x00; d[1] = 0xe0; d[2] = 0x48; d[3] = 0x00;
	ret = ret ?: ssd20xx_write(ts, SSD_DS_EFLASH_WRITE, d, 4);
	ret = ret ?: ssd20xx_write16(ts, SSD_DS_CLEAR_INT, 0);
	/* release the touch MCU: it boots the firmware from flash */
	ret = ret ?: ssd20xx_write16(ts, SSD_DS_CPU_CONTROL, 0);
	if (ret)
		return dev_err_probe(dev, ret, "boot sequence failed\n");

	if (ssd20xx_wait_int(ts, 300))
		dev_warn(dev, "INT did not go low after starting the firmware\n");

	return ssd20xx_configure(ts);
}

static void ssd20xx_release_all(struct ssd20xx *ts)
{
	input_mt_sync_frame(ts->input);	/* drops every slot not reported */
	input_sync(ts->input);
}

static irqreturn_t ssd20xx_irq(int irq, void *dev_id)
{
	struct ssd20xx *ts = dev_id;
	u8 snl[4];
	u8 buf[SSD_MAX_POINTS * SSD_POINT_SIZE + 2];
	u8 status, length;
	int i, n;

	if (ssd20xx_read(ts, SSD_STATUS_LENGTH, snl, sizeof(snl)))
		goto out;

	length = snl[0];
	status = snl[1];
	if (!length && !status)
		goto out;

	if (status & SSD_STATUS_BOOT) {
		dev_info(&ts->client->dev, "firmware restarted, reconfiguring\n");
		ssd20xx_release_all(ts);
		ssd20xx_configure(ts);
		goto out;
	}

	if (!length) {
		ssd20xx_release_all(ts);
		goto out;
	}
	if (!(status & SSD_STATUS_EVENTS))
		goto out;

	length = min_t(u8, length, SSD_MAX_POINTS * SSD_POINT_SIZE);
	if (ssd20xx_read(ts, SSD_POINT_DATA, buf, length + 2))
		goto out;

	n = length / SSD_POINT_SIZE;
	for (i = 0; i < n; i++) {
		const u8 *p = &buf[i * SSD_POINT_SIZE];
		unsigned int id = p[0], x, y, w = p[4];

		if (id > SSD_ID_AXIS_LAST || id >= SSD_MAX_POINTS)
			continue;	/* key / gesture / aux records */
		x = ((p[3] & 0xf0) << 4) | p[1];
		y = ((p[3] & 0x0f) << 8) | p[2];

		input_mt_slot(ts->input, id);
		if (input_mt_report_slot_state(ts->input, MT_TOOL_FINGER, w)) {
			touchscreen_report_pos(ts->input, &ts->prop, x, y, true);
			input_report_abs(ts->input, ABS_MT_PRESSURE, w);
		}
	}
	input_mt_report_pointer_emulation(ts->input, true);
	input_sync(ts->input);

out:
	ssd20xx_write16(ts, SSD_INT_CLEAR, 1);
	return IRQ_HANDLED;
}

static void ssd20xx_irq_off(struct ssd20xx *ts)
{
	if (!ts->irq_off) {
		disable_irq(ts->client->irq);
		ts->irq_off = true;
	}
}

/* the panel was reset, which reset the touch MCU with it: boot it again */
static void ssd20xx_reboot_work(struct work_struct *work)
{
	struct ssd20xx *ts = container_of(work, struct ssd20xx, reboot_work);

	ssd20xx_irq_off(ts);
	ssd20xx_release_all(ts);
	if (ssd20xx_boot(ts))
		dev_err(&ts->client->dev, "touch did not come back after panel reset\n");
	ssd20xx_write16(ts, SSD_INT_CLEAR, 1);
	enable_irq(ts->client->irq);
	ts->irq_off = false;
}

#ifdef SSD_HAVE_PANEL_NOTIFIER
static int ssd20xx_panel_event(struct notifier_block *nb, unsigned long on, void *data)
{
	struct ssd20xx *ts = container_of(nb, struct ssd20xx, panel_nb);

	if (on) {
		schedule_work(&ts->reboot_work);
	} else {
		cancel_work_sync(&ts->reboot_work);
		ssd20xx_irq_off(ts);
		ssd20xx_release_all(ts);
	}
	return NOTIFY_OK;
}

static void ssd20xx_unregister_notifier(void *data)
{
	struct ssd20xx *ts = data;

	blocking_notifier_chain_unregister(&cosmo_ssd2092_panel_notifier, &ts->panel_nb);
	cancel_work_sync(&ts->reboot_work);
}
#endif

static int ssd20xx_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	struct ssd20xx *ts;
	int ret;

	ts = devm_kzalloc(dev, sizeof(*ts), GFP_KERNEL);
	if (!ts)
		return -ENOMEM;
	ts->client = client;

	ts->reset_gpio = devm_gpiod_get_optional(dev, "reset", GPIOD_OUT_LOW);
	if (IS_ERR(ts->reset_gpio))
		return dev_err_probe(dev, PTR_ERR(ts->reset_gpio), "reset gpio\n");
	ts->irq_gpio = devm_gpiod_get_optional(dev, "irq", GPIOD_IN);
	if (IS_ERR(ts->irq_gpio))
		return dev_err_probe(dev, PTR_ERR(ts->irq_gpio), "irq gpio\n");

	ts->input = devm_input_allocate_device(dev);
	if (!ts->input)
		return -ENOMEM;
	ts->input->name = "Solomon SSD20xx Touchscreen";
	ts->input->id.bustype = BUS_I2C;
	input_set_abs_params(ts->input, ABS_MT_POSITION_X, 0, 1079, 0, 0);
	input_set_abs_params(ts->input, ABS_MT_POSITION_Y, 0, 2159, 0, 0);
	input_set_abs_params(ts->input, ABS_MT_PRESSURE, 0, 255, 0, 0);
	touchscreen_parse_properties(ts->input, true, &ts->prop);
	ret = input_mt_init_slots(ts->input, SSD_MAX_POINTS,
				  INPUT_MT_DIRECT | INPUT_MT_DROP_UNUSED);
	if (ret)
		return ret;

	ret = ssd20xx_boot(ts);
	if (ret)
		return ret;

	ret = input_register_device(ts->input);
	if (ret)
		return ret;

	ret = devm_request_threaded_irq(dev, client->irq, NULL, ssd20xx_irq,
					IRQF_ONESHOT, "ssd20xx", ts);
	if (ret)
		return dev_err_probe(dev, ret, "irq %d\n", client->irq);

	/* acknowledge anything raised while we were configuring */
	ssd20xx_write16(ts, SSD_INT_CLEAR, 1);

	INIT_WORK(&ts->reboot_work, ssd20xx_reboot_work);
#ifdef SSD_HAVE_PANEL_NOTIFIER
	ts->panel_nb.notifier_call = ssd20xx_panel_event;
	ret = blocking_notifier_chain_register(&cosmo_ssd2092_panel_notifier, &ts->panel_nb);
	if (ret)
		return ret;
	ret = devm_add_action_or_reset(dev, ssd20xx_unregister_notifier, ts);
	if (ret)
		return ret;
#endif
	return 0;
}

static const struct of_device_id ssd20xx_of_match[] = {
	{ .compatible = "solomon,ssd2092-touch" },
	{ .compatible = "solomon,ssd20xx-touch" },
	{ }
};
MODULE_DEVICE_TABLE(of, ssd20xx_of_match);

static const struct i2c_device_id ssd20xx_id[] = {
	{ "ssd20xx-touch", 0 },
	{ }
};
MODULE_DEVICE_TABLE(i2c, ssd20xx_id);

static struct i2c_driver ssd20xx_driver = {
	.driver = {
		.name = "ssd20xx-touch",
		.of_match_table = ssd20xx_of_match,
	},
	.probe_new = ssd20xx_probe,
	.id_table = ssd20xx_id,
};
module_i2c_driver(ssd20xx_driver);

MODULE_DESCRIPTION("Solomon SSD20xx TDDI touchscreen driver");
MODULE_LICENSE("GPL");
