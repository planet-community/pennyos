// SPDX-License-Identifier: GPL-2.0
/*
 * Minimal MT6358 fuel-gauge current reader for the Planet Cosmo (pennyos).
 *
 * Mainline has no driver for the MT6358 "FGADC" gauge. This exposes just the
 * instantaneous battery current as a power_supply (cosmo-battery: CURRENT_NOW, in
 * microamps, negative while discharging) so that power work can be measured and the
 * bar can show charge/discharge. It is not a fuel gauge: no capacity, no coulomb
 * counting. Register sequence and scaling follow the vendor mt6358_gauge.c
 * (fgauge_read_current): latch, read FG_CURRENT_OUT, release.
 */
#include <linux/delay.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>
#include <linux/power_supply.h>
#include <linux/regmap.h>

#define MT6358_FGADC_CON0	0x0d08	/* bit 0: FG_ON */
#define MT6358_FGADC_CON1	0x0d0a	/* [3:0] sw read/clear, bit 15: LATCHDATA_ST */
#define MT6358_FGADC_CUR_CON0	0x0d8a	/* FG_CURRENT_OUT, signed 16 bit */
#define MT6358_FGADC_CAR_CON0	0x0d14	/* coulomb counter, bits 15..0 */
#define MT6358_FGADC_CAR_CON1	0x0d16	/* coulomb counter, bits 31..16 (signed) */
#define FG_LATCHDATA_ST		BIT(15)
/*
 * The vendor code uses the counter >> 11 at 108.507 uAh per step (and the same
 * 0.93 scale as the current). Keep the low bits: nAh = raw * 108507 * 0.93 / 2048.
 */
#define FG_NAH_PER_LSB_NUM	(108507LL * 93)
#define FG_NAH_PER_LSB_DEN	(2048LL * 100)

/* vendor: UNIT_FGCURRENT = 381470 (in 0.1 uA per LSB / 100000 -> 0.1 mA), with
 * R_FG = 10 mOhm (no correction) and CAR_TUNE_VALUE = 93 -> x 0.93 */
#define FG_UA_PER_LSB_NUM	(381470LL * 93)
#define FG_UA_PER_LSB_DEN	100000LL	/* result in uA: raw * 381.470 * 0.93 */

/*
 * power_supply attributes are world-readable and every fresh reading costs several
 * PMIC bus writes (latch / release). Serve readings from a cache and touch the
 * hardware at most once per second, so an unprivileged reader cannot hammer the bus
 * and does not get a high-rate view of system activity.
 */
#define FG_MIN_INTERVAL		HZ

struct cosmo_fg {
	struct regmap *map;
	struct mutex lock;
	struct power_supply *psy;
	unsigned long last_jiffies;	/* time of the last hardware ATTEMPT */
	int last_ua;
	int last_uah;
	int last_ret;			/* its result; failures are cached too */
	bool have_last;
};

static int cosmo_fg_wait(struct cosmo_fg *fg, bool set)
{
	unsigned int v;
	int i;

	for (i = 0; i < 200; i++) {
		if (regmap_read(fg->map, MT6358_FGADC_CON1, &v))
			return -EIO;
		if (!!(v & FG_LATCHDATA_ST) == set)
			return 0;
		usleep_range(100, 200);
	}
	return -ETIMEDOUT;
}

static int cosmo_fg_read(struct cosmo_fg *fg, int *ua, int *uah)
{
	unsigned int raw = 0, car_lo = 0, car_hi = 0;
	int ret;

	mutex_lock(&fg->lock);
	if (fg->have_last && time_before(jiffies, fg->last_jiffies + FG_MIN_INTERVAL)) {
		*ua = fg->last_ua;
		if (uah)
			*uah = fg->last_uah;
		ret = fg->last_ret;
		mutex_unlock(&fg->lock);
		return ret;
	}
	ret = regmap_update_bits(fg->map, MT6358_FGADC_CON1, 0x000f, 0x0001);
	if (!ret)
		ret = cosmo_fg_wait(fg, true);
	if (!ret)
		ret = regmap_read(fg->map, MT6358_FGADC_CUR_CON0, &raw);
	if (!ret)
		ret = regmap_read(fg->map, MT6358_FGADC_CAR_CON0, &car_lo);
	if (!ret)
		ret = regmap_read(fg->map, MT6358_FGADC_CAR_CON1, &car_hi);
	/* release the latch whatever happened above */
	regmap_update_bits(fg->map, MT6358_FGADC_CON1, 0x000f, 0x0008);
	cosmo_fg_wait(fg, false);
	regmap_update_bits(fg->map, MT6358_FGADC_CON1, 0x000f, 0x0000);
	if (!ret) {
		*ua = (int)div_s64((s64)(s16)raw * FG_UA_PER_LSB_NUM, FG_UA_PER_LSB_DEN * 100);
		*ua *= 100;	/* keep 0.1 mA resolution, as the vendor code does */
		fg->last_ua = *ua;
		fg->last_uah = (int)div_s64((s64)(s32)(car_hi << 16 | (car_lo & 0xffff)) *
					    FG_NAH_PER_LSB_NUM, FG_NAH_PER_LSB_DEN * 1000);
		if (uah)
			*uah = fg->last_uah;
	}
	/* the limit applies to attempts, not successes: a failing gauge must not
	 * turn every read into another burst of bus traffic */
	fg->last_ret = ret;
	fg->last_jiffies = jiffies;
	fg->have_last = true;
	mutex_unlock(&fg->lock);
	return ret;
}

static int cosmo_fg_get_property(struct power_supply *psy, enum power_supply_property psp,
				 union power_supply_propval *val)
{
	struct cosmo_fg *fg = power_supply_get_drvdata(psy);
	int dummy;

	switch (psp) {
	case POWER_SUPPLY_PROP_CURRENT_NOW:
		return cosmo_fg_read(fg, &val->intval, NULL);
	case POWER_SUPPLY_PROP_CHARGE_COUNTER:
		return cosmo_fg_read(fg, &dummy, &val->intval);
	case POWER_SUPPLY_PROP_PRESENT:
		val->intval = 1;
		return 0;
	default:
		return -EINVAL;
	}
}

static enum power_supply_property cosmo_fg_props[] = {
	POWER_SUPPLY_PROP_CURRENT_NOW,
	POWER_SUPPLY_PROP_CHARGE_COUNTER,
	POWER_SUPPLY_PROP_PRESENT,
};

static const struct power_supply_desc cosmo_fg_desc = {
	.name = "cosmo-battery",
	.type = POWER_SUPPLY_TYPE_BATTERY,
	.properties = cosmo_fg_props,
	.num_properties = ARRAY_SIZE(cosmo_fg_props),
	.get_property = cosmo_fg_get_property,
};

static struct cosmo_fg *cosmo_fg_instance;

static int __init cosmo_fg_init(void)
{
	struct power_supply_config cfg = {};
	struct platform_device *pdev;
	struct device_node *np;
	struct cosmo_fg *fg;
	unsigned int con0 = 0;
	int ua = 0, ret;

	np = of_find_compatible_node(NULL, NULL, "mediatek,mt6358");
	if (!np)
		return -ENODEV;
	pdev = of_find_device_by_node(np);
	of_node_put(np);
	if (!pdev)
		return -EPROBE_DEFER;

	fg = kzalloc(sizeof(*fg), GFP_KERNEL);
	if (!fg)
		return -ENOMEM;
	mutex_init(&fg->lock);
	/* the pwrap bus device owns the PMIC regmap; the MT6358 MFD is its child */
	fg->map = dev_get_regmap(pdev->dev.parent, NULL);
	if (!fg->map) {
		kfree(fg);
		return -ENODEV;
	}
	regmap_read(fg->map, MT6358_FGADC_CON0, &con0);
	ret = cosmo_fg_read(fg, &ua, NULL);
	pr_info("cosmo_fg: FGADC_CON0=0x%04x (gauge %s), first reading %d uA (ret %d)\n",
		con0, con0 & 1 ? "on" : "OFF", ua, ret);

	cfg.drv_data = fg;
	fg->psy = power_supply_register(&pdev->dev, &cosmo_fg_desc, &cfg);
	if (IS_ERR(fg->psy)) {
		ret = PTR_ERR(fg->psy);
		kfree(fg);
		return ret;
	}
	cosmo_fg_instance = fg;
	return 0;
}

static void __exit cosmo_fg_exit(void)
{
	if (cosmo_fg_instance) {
		power_supply_unregister(cosmo_fg_instance->psy);
		kfree(cosmo_fg_instance);
	}
}

module_init(cosmo_fg_init);
module_exit(cosmo_fg_exit);
MODULE_DESCRIPTION("MT6358 fuel-gauge current reader (Planet Cosmo, pennyos)");
MODULE_LICENSE("GPL");
