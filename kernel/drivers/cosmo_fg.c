// SPDX-License-Identifier: GPL-2.0
/*
 * Fuel gauge for the Planet Cosmo (pennyos): MT6358 coulomb counter + cell voltage.
 *
 * Mainline has no driver for the MT6358 "FGADC" gauge. This one reads the gauge's
 * instantaneous current and its coulomb counter, and the cell voltage from the
 * MT6370 charger's ADC, and turns them into a state of charge:
 *
 *  - at probe, from the open-circuit voltage (measured voltage corrected for the
 *    current through the cell's internal resistance) and the battery's OCV table;
 *  - from then on by counting charge in and out with the coulomb counter;
 *  - set to full when the charger reports charging done;
 *  - slowly pulled towards the voltage estimate while discharging gently, and
 *    quickly near empty, where the voltage curve is steep and reliable.
 *
 * The battery description (capacity, OCV table, resistance) comes from the
 * "monitored-battery" simple-battery node, generated from the vendor profile by
 * tools/gen-battery-dtsi.py. Register sequence and scaling for the gauge follow the
 * vendor mt6358_gauge.c (fgauge_read_current): latch, read, release.
 */
#include <linux/delay.h>
#include <linux/devm-helpers.h>
#include <linux/iio/consumer.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>
#include <linux/power_supply.h>
#include <linux/regmap.h>
#include <linux/workqueue.h>

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

#define FG_UPDATE_INTERVAL	(10 * HZ)
#define FG_CHARGER		"mt6370-charger"
/* the voltage estimate is trusted while discharging at no more than this */
#define FG_GENTLE_UA		300000
/* per update, move this fraction of the way to the voltage estimate: about 40 min */
#define FG_PULL_SLOW		256
/* below this OCV capacity (%) the curve is steep: pull hard so we never die at 10 % */
#define FG_KNEE_PCT		10
#define FG_PULL_FAST		8

struct cosmo_fg {
	struct device *dev;
	struct regmap *map;
	struct mutex lock;
	struct power_supply *psy;
	struct power_supply_battery_info *bat;
	struct iio_channel *vbat;
	struct delayed_work work;
	unsigned long last_jiffies;	/* time of the last hardware ATTEMPT */
	int last_ua;
	int last_uah;
	int last_ret;			/* its result; failures are cached too */
	bool have_last;

	/* gauge state, updated by the work under lock */
	bool ready;
	int voltage_uv;
	int ocv_uv;
	int car_uah;			/* counter at the previous update */
	s64 charge_uah;			/* remaining usable charge */
	int capacity;
	int status;
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

/* called with fg->lock held */
static int cosmo_fg_read(struct cosmo_fg *fg, int *ua, int *uah)
{
	unsigned int raw = 0, car_lo = 0, car_hi = 0;
	int ret;

	if (fg->have_last && time_before(jiffies, fg->last_jiffies + FG_MIN_INTERVAL)) {
		*ua = fg->last_ua;
		if (uah)
			*uah = fg->last_uah;
		return fg->last_ret;
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
	return ret;
}

static int cosmo_fg_charger(int *online, int *status)
{
	struct power_supply *chg = power_supply_get_by_name(FG_CHARGER);
	union power_supply_propval val;

	*online = 0;
	*status = POWER_SUPPLY_STATUS_UNKNOWN;
	if (!chg)
		return -ENODEV;
	if (!power_supply_get_property(chg, POWER_SUPPLY_PROP_ONLINE, &val))
		*online = val.intval;
	if (!power_supply_get_property(chg, POWER_SUPPLY_PROP_STATUS, &val))
		*status = val.intval;
	power_supply_put(chg);
	return 0;
}

/* remaining usable charge the OCV table gives for this open-circuit voltage */
static s64 cosmo_fg_ocv_charge(struct cosmo_fg *fg, int ocv_uv)
{
	int pct = power_supply_batinfo_ocv2cap(fg->bat, ocv_uv, 25);

	if (pct < 0)
		pct = 0;
	return div_s64((s64)fg->bat->charge_full_design_uah * pct, 100);
}

static void cosmo_fg_update(struct cosmo_fg *fg)
{
	s64 full = fg->bat->charge_full_design_uah, target;
	int ua, uah, mv, online, chg_status, capacity, status, ret;
	bool changed;

	ret = iio_read_channel_processed(fg->vbat, &mv);
	if (ret < 0) {
		dev_warn_ratelimited(fg->dev, "cell voltage: %d\n", ret);
		return;
	}
	cosmo_fg_charger(&online, &chg_status);

	mutex_lock(&fg->lock);
	fg->have_last = false;	/* fresh current and counter for this update */
	ret = cosmo_fg_read(fg, &ua, &uah);
	if (ret) {
		mutex_unlock(&fg->lock);
		dev_warn_ratelimited(fg->dev, "gauge: %d\n", ret);
		return;
	}
	fg->voltage_uv = mv * 1000;
	/* positive current charges: the terminal sits above the OCV by I * R */
	fg->ocv_uv = fg->voltage_uv -
		(int)div_s64((s64)ua * fg->bat->factory_internal_resistance_uohm, 1000000);
	target = cosmo_fg_ocv_charge(fg, fg->ocv_uv);

	if (!fg->ready) {
		fg->charge_uah = target;
		fg->ready = true;
		dev_info(fg->dev, "start: %d mV at %d mA, OCV %d mV -> %lld mAh of %lld\n",
			 mv, ua / 1000, fg->ocv_uv / 1000, target / 1000, full / 1000);
	} else {
		fg->charge_uah += uah - fg->car_uah;
		if (online && chg_status == POWER_SUPPLY_STATUS_FULL) {
			fg->charge_uah = full;
		} else if (!online && ua < 0 && ua > -FG_GENTLE_UA) {
			int ocv_pct = div_s64(target * 100, full);

			if (ocv_pct < FG_KNEE_PCT && target < fg->charge_uah)
				fg->charge_uah += div_s64(target - fg->charge_uah, FG_PULL_FAST);
			else
				fg->charge_uah += div_s64(target - fg->charge_uah, FG_PULL_SLOW);
		}
	}
	fg->car_uah = uah;
	fg->charge_uah = clamp_t(s64, fg->charge_uah, 0, full);

	capacity = div_s64(fg->charge_uah * 100 + full / 2, full);
	if (online && chg_status == POWER_SUPPLY_STATUS_FULL)
		status = POWER_SUPPLY_STATUS_FULL;
	else if (ua > 0)
		status = POWER_SUPPLY_STATUS_CHARGING;
	else if (online && ua > -20000)
		status = POWER_SUPPLY_STATUS_NOT_CHARGING;
	else
		status = POWER_SUPPLY_STATUS_DISCHARGING;
	/* 100 % means the charger finished, not that the estimate got there first */
	if (status == POWER_SUPPLY_STATUS_CHARGING && capacity > 99)
		capacity = 99;
	changed = capacity != fg->capacity || status != fg->status;
	fg->capacity = capacity;
	fg->status = status;
	mutex_unlock(&fg->lock);

	if (changed)
		power_supply_changed(fg->psy);
}

static void cosmo_fg_work(struct work_struct *work)
{
	struct cosmo_fg *fg = container_of(work, struct cosmo_fg, work.work);

	cosmo_fg_update(fg);
	schedule_delayed_work(&fg->work, FG_UPDATE_INTERVAL);
}

static int cosmo_fg_get_property(struct power_supply *psy, enum power_supply_property psp,
				 union power_supply_propval *val)
{
	struct cosmo_fg *fg = power_supply_get_drvdata(psy);
	int dummy, ret = 0;

	mutex_lock(&fg->lock);
	switch (psp) {
	case POWER_SUPPLY_PROP_PRESENT:
		val->intval = 1;
		break;
	case POWER_SUPPLY_PROP_TECHNOLOGY:
		val->intval = POWER_SUPPLY_TECHNOLOGY_LION;
		break;
	case POWER_SUPPLY_PROP_CURRENT_NOW:
		ret = cosmo_fg_read(fg, &val->intval, NULL);
		break;
	case POWER_SUPPLY_PROP_CHARGE_COUNTER:
		ret = cosmo_fg_read(fg, &dummy, &val->intval);
		break;
	case POWER_SUPPLY_PROP_CHARGE_FULL:
	case POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN:
	case POWER_SUPPLY_PROP_VOLTAGE_MIN_DESIGN:
		/* the supply is readable before probe has the battery data */
		if (!fg->bat)
			ret = -ENODATA;
		else if (psp == POWER_SUPPLY_PROP_VOLTAGE_MIN_DESIGN)
			val->intval = fg->bat->voltage_min_design_uv;
		else
			val->intval = fg->bat->charge_full_design_uah;
		break;
	case POWER_SUPPLY_PROP_STATUS:
	case POWER_SUPPLY_PROP_CAPACITY:
	case POWER_SUPPLY_PROP_CHARGE_NOW:
	case POWER_SUPPLY_PROP_VOLTAGE_NOW:
	case POWER_SUPPLY_PROP_VOLTAGE_OCV:
		if (!fg->ready) {
			ret = -ENODATA;
			break;
		}
		if (psp == POWER_SUPPLY_PROP_STATUS)
			val->intval = fg->status;
		else if (psp == POWER_SUPPLY_PROP_CAPACITY)
			val->intval = fg->capacity;
		else if (psp == POWER_SUPPLY_PROP_CHARGE_NOW)
			val->intval = fg->charge_uah;
		else if (psp == POWER_SUPPLY_PROP_VOLTAGE_NOW)
			val->intval = fg->voltage_uv;
		else
			val->intval = fg->ocv_uv;
		break;
	default:
		ret = -EINVAL;
	}
	mutex_unlock(&fg->lock);
	return ret;
}

static enum power_supply_property cosmo_fg_props[] = {
	POWER_SUPPLY_PROP_STATUS,
	POWER_SUPPLY_PROP_PRESENT,
	POWER_SUPPLY_PROP_TECHNOLOGY,
	POWER_SUPPLY_PROP_CAPACITY,
	POWER_SUPPLY_PROP_VOLTAGE_NOW,
	POWER_SUPPLY_PROP_VOLTAGE_OCV,
	POWER_SUPPLY_PROP_VOLTAGE_MIN_DESIGN,
	POWER_SUPPLY_PROP_CURRENT_NOW,
	POWER_SUPPLY_PROP_CHARGE_NOW,
	POWER_SUPPLY_PROP_CHARGE_FULL,
	POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN,
	POWER_SUPPLY_PROP_CHARGE_COUNTER,
};

static const struct power_supply_desc cosmo_fg_desc = {
	.name = "cosmo-battery",
	.type = POWER_SUPPLY_TYPE_BATTERY,
	.properties = cosmo_fg_props,
	.num_properties = ARRAY_SIZE(cosmo_fg_props),
	.get_property = cosmo_fg_get_property,
};

static int cosmo_fg_probe(struct platform_device *pdev)
{
	struct power_supply_battery_info *bat;
	struct power_supply_config cfg = {};
	struct device *dev = &pdev->dev;
	struct platform_device *pmic;
	struct device_node *np;
	struct cosmo_fg *fg;
	unsigned int con0 = 0;
	int ret;

	fg = devm_kzalloc(dev, sizeof(*fg), GFP_KERNEL);
	if (!fg)
		return -ENOMEM;
	fg->dev = dev;
	mutex_init(&fg->lock);
	fg->capacity = -1;

	np = of_parse_phandle(dev->of_node, "mediatek,pmic", 0);
	if (!np)
		return dev_err_probe(dev, -EINVAL, "no mediatek,pmic\n");
	pmic = of_find_device_by_node(np);
	of_node_put(np);
	if (!pmic)
		return -EPROBE_DEFER;
	/* the pwrap bus device owns the PMIC regmap; the MT6358 MFD is its child */
	fg->map = dev_get_regmap(pmic->dev.parent, NULL);
	put_device(&pmic->dev);
	if (!fg->map)
		return -EPROBE_DEFER;

	fg->vbat = devm_iio_channel_get(dev, "vbat");
	if (IS_ERR(fg->vbat))
		return dev_err_probe(dev, PTR_ERR(fg->vbat), "cell voltage channel\n");

	regmap_read(fg->map, MT6358_FGADC_CON0, &con0);
	if (!(con0 & 1))
		dev_warn(dev, "the PMIC's gauge is off (FGADC_CON0=0x%04x)\n", con0);

	cfg.drv_data = fg;
	cfg.of_node = dev->of_node;
	fg->psy = devm_power_supply_register(dev, &cosmo_fg_desc, &cfg);
	if (IS_ERR(fg->psy))
		return dev_err_probe(dev, PTR_ERR(fg->psy), "register\n");

	ret = power_supply_get_battery_info(fg->psy, &bat);
	if (ret)
		return dev_err_probe(dev, ret, "monitored-battery\n");
	if (bat->charge_full_design_uah <= 0 || !bat->ocv_table_size[0] ||
	    bat->factory_internal_resistance_uohm < 0)
		return dev_err_probe(dev, -EINVAL,
				     "battery needs capacity, OCV table and resistance\n");
	/* publish only valid data: the properties are readable from registration on */
	mutex_lock(&fg->lock);
	fg->bat = bat;
	mutex_unlock(&fg->lock);

	ret = devm_delayed_work_autocancel(dev, &fg->work, cosmo_fg_work);
	if (ret)
		return ret;
	cosmo_fg_update(fg);
	schedule_delayed_work(&fg->work, FG_UPDATE_INTERVAL);
	return 0;
}

static const struct of_device_id cosmo_fg_of_match[] = {
	{ .compatible = "planet,cosmo-fuel-gauge" },
	{ }
};
MODULE_DEVICE_TABLE(of, cosmo_fg_of_match);

static struct platform_driver cosmo_fg_driver = {
	.probe = cosmo_fg_probe,
	.driver = {
		.name = "cosmo-fg",
		.of_match_table = cosmo_fg_of_match,
	},
};
module_platform_driver(cosmo_fg_driver);

MODULE_DESCRIPTION("MT6358 fuel gauge (Planet Cosmo, pennyos)");
MODULE_LICENSE("GPL");
