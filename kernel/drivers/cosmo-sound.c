// SPDX-License-Identifier: GPL-2.0
/*
 * Sound card for the Planet Cosmo Communicator: the SoC audio front end
 * (mt8183-afe-pcm, the MT6771 has the same block) wired to the MT6358 codec.
 *
 * Only the codec path is described: one playback and one capture PCM. Bluetooth
 * audio is not connected.
 *
 * The codec's analogue outputs reach the speakers and the headphone jack through
 * external amplifiers and switches that are each controlled by one GPIO (vendor
 * device tree: extamp, extamp2, headphone_en, headphone_cs). There is no RT5509
 * on this phone, whatever the vendor kernel config suggests.
 *
 * Speakers: codec line out L into two amplifiers, enabled by extamp and extamp2.
 * The codec's "LoudSPK Playback" headphone mux setting is what powers line out
 * fully (charge pump and regulators); the plain "LOL Mux" path does not. The
 * amplifiers pick their mode from the number of rising edges on the enable pin;
 * Planet's kernel (Ext_Speaker_Amp_Change) sends 3 and waits 25 ms, as does the
 * "Speakers" widget here. The headphone GPIOs are still plain mixer switches.
 * Modelled on mt8183-mt6358-ts3a227-max98357.c.
 */
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <sound/soc.h>

SND_SOC_DAILINK_DEFS(playback1,
	DAILINK_COMP_ARRAY(COMP_CPU("DL1")),
	DAILINK_COMP_ARRAY(COMP_DUMMY()),
	DAILINK_COMP_ARRAY(COMP_EMPTY()));

SND_SOC_DAILINK_DEFS(capture1,
	DAILINK_COMP_ARRAY(COMP_CPU("UL1")),
	DAILINK_COMP_ARRAY(COMP_DUMMY()),
	DAILINK_COMP_ARRAY(COMP_EMPTY()));

SND_SOC_DAILINK_DEFS(primary_codec,
	DAILINK_COMP_ARRAY(COMP_CPU("ADDA")),
	DAILINK_COMP_ARRAY(COMP_CODEC("mt6358-sound", "mt6358-snd-codec-aif1")),
	DAILINK_COMP_ARRAY(COMP_EMPTY()));

static struct snd_soc_dai_link cosmo_sound_dai_links[] = {
	/* FE */
	{
		.name = "Playback_1",
		.stream_name = "Playback_1",
		.trigger = {SND_SOC_DPCM_TRIGGER_PRE,
			    SND_SOC_DPCM_TRIGGER_PRE},
		.dynamic = 1,
		.dpcm_playback = 1,
		SND_SOC_DAILINK_REG(playback1),
	},
	{
		.name = "Capture_1",
		.stream_name = "Capture_1",
		.trigger = {SND_SOC_DPCM_TRIGGER_PRE,
			    SND_SOC_DPCM_TRIGGER_PRE},
		.dynamic = 1,
		.dpcm_capture = 1,
		SND_SOC_DAILINK_REG(capture1),
	},
	/* BE */
	{
		.name = "Primary Codec",
		.no_pcm = 1,
		.dpcm_playback = 1,
		.dpcm_capture = 1,
		.ignore_suspend = 1,
		SND_SOC_DAILINK_REG(primary_codec),
	},
};

enum { COSMO_GPIO_EXTAMP, COSMO_GPIO_EXTAMP2, COSMO_GPIO_HP_EN, COSMO_GPIO_HP_CS, COSMO_GPIO_NUM };

static const char * const cosmo_gpio_names[COSMO_GPIO_NUM] = {
	"ext-amp", "ext-amp2", "hp-en", "hp-cs",
};

struct cosmo_sound_priv {
	struct gpio_desc *gpio[COSMO_GPIO_NUM];
	bool on[COSMO_GPIO_NUM];
};

static int cosmo_gpio_get(struct snd_kcontrol *kcontrol,
			  struct snd_ctl_elem_value *ucontrol)
{
	struct snd_soc_card *card = snd_kcontrol_chip(kcontrol);
	struct cosmo_sound_priv *priv = snd_soc_card_get_drvdata(card);

	ucontrol->value.integer.value[0] = priv->on[kcontrol->private_value];
	return 0;
}

static int cosmo_gpio_put(struct snd_kcontrol *kcontrol,
			  struct snd_ctl_elem_value *ucontrol)
{
	struct snd_soc_card *card = snd_kcontrol_chip(kcontrol);
	struct cosmo_sound_priv *priv = snd_soc_card_get_drvdata(card);
	unsigned int i = kcontrol->private_value;
	bool on = !!ucontrol->value.integer.value[0];

	if (priv->on[i] == on)
		return 0;
	priv->on[i] = on;
	gpiod_set_value_cansleep(priv->gpio[i], on);
	return 1;
}

#define COSMO_GPIO_SWITCH(xname, xindex) \
	{ .iface = SNDRV_CTL_ELEM_IFACE_MIXER, .name = xname, \
	  .info = snd_ctl_boolean_mono_info, .get = cosmo_gpio_get, \
	  .put = cosmo_gpio_put, .private_value = xindex }

/* vendor amplifier mode, as rising edges on the enable pins */
#define COSMO_SPK_AMP_MODE	3
#define COSMO_SPK_WARM_UP_MS	25

static void cosmo_spk_amps_pulse(struct cosmo_sound_priv *priv, int edges)
{
	unsigned long flags;
	int i;

	/* the amplifiers count edges; a long gap from an interrupt reads as "off" */
	local_irq_save(flags);
	for (i = 0; i < edges; i++) {
		gpiod_set_value(priv->gpio[COSMO_GPIO_EXTAMP], 0);
		gpiod_set_value(priv->gpio[COSMO_GPIO_EXTAMP2], 0);
		udelay(2);
		gpiod_set_value(priv->gpio[COSMO_GPIO_EXTAMP], 1);
		gpiod_set_value(priv->gpio[COSMO_GPIO_EXTAMP2], 1);
		udelay(2);
	}
	local_irq_restore(flags);
}

static int cosmo_spk_event(struct snd_soc_dapm_widget *w,
			   struct snd_kcontrol *kcontrol, int event)
{
	struct snd_soc_card *card = w->dapm->card;
	struct cosmo_sound_priv *priv = snd_soc_card_get_drvdata(card);

	switch (event) {
	case SND_SOC_DAPM_POST_PMU:
		/* off long enough to forget the previous mode, then select it */
		gpiod_set_value(priv->gpio[COSMO_GPIO_EXTAMP], 0);
		gpiod_set_value(priv->gpio[COSMO_GPIO_EXTAMP2], 0);
		usleep_range(1000, 2000);
		cosmo_spk_amps_pulse(priv, COSMO_SPK_AMP_MODE);
		msleep(COSMO_SPK_WARM_UP_MS);
		break;
	case SND_SOC_DAPM_PRE_PMD:
		gpiod_set_value(priv->gpio[COSMO_GPIO_EXTAMP], 0);
		gpiod_set_value(priv->gpio[COSMO_GPIO_EXTAMP2], 0);
		udelay(500);
		break;
	}
	return 0;
}

static const struct snd_soc_dapm_widget cosmo_sound_widgets[] = {
	SND_SOC_DAPM_SPK("Speakers", cosmo_spk_event),
};

static const struct snd_soc_dapm_route cosmo_sound_routes[] = {
	/* line out L, powered through the codec's HPL Mux "LoudSPK Playback" */
	{ "Speakers", NULL, "LINEOUT L HSSPK" },
};

static const struct snd_kcontrol_new cosmo_sound_controls[] = {
	SOC_DAPM_PIN_SWITCH("Speakers"),
	COSMO_GPIO_SWITCH("Headphone Enable Switch", COSMO_GPIO_HP_EN),
	COSMO_GPIO_SWITCH("Headphone Select Switch", COSMO_GPIO_HP_CS),
};

static struct snd_soc_card cosmo_sound_card = {
	.name = "cosmo",
	.owner = THIS_MODULE,
	.controls = cosmo_sound_controls,
	.num_controls = ARRAY_SIZE(cosmo_sound_controls),
	.dapm_widgets = cosmo_sound_widgets,
	.num_dapm_widgets = ARRAY_SIZE(cosmo_sound_widgets),
	.dapm_routes = cosmo_sound_routes,
	.num_dapm_routes = ARRAY_SIZE(cosmo_sound_routes),
	.dai_link = cosmo_sound_dai_links,
	.num_links = ARRAY_SIZE(cosmo_sound_dai_links),
};

static int cosmo_sound_probe(struct platform_device *pdev)
{
	struct snd_soc_card *card = &cosmo_sound_card;
	struct device_node *platform_node;
	struct snd_soc_dai_link *dai_link;
	struct cosmo_sound_priv *priv;
	int ret, i;

	priv = devm_kzalloc(&pdev->dev, sizeof(*priv), GFP_KERNEL);
	if (!priv)
		return -ENOMEM;
	for (i = 0; i < COSMO_GPIO_NUM; i++) {
		priv->gpio[i] = devm_gpiod_get_optional(&pdev->dev,
							cosmo_gpio_names[i],
							GPIOD_OUT_LOW);
		if (IS_ERR(priv->gpio[i]))
			return dev_err_probe(&pdev->dev, PTR_ERR(priv->gpio[i]),
					     "%s gpio\n", cosmo_gpio_names[i]);
	}
	snd_soc_card_set_drvdata(&cosmo_sound_card, priv);

	platform_node = of_parse_phandle(pdev->dev.of_node,
					 "mediatek,platform", 0);
	if (!platform_node) {
		dev_err(&pdev->dev, "Property 'mediatek,platform' missing or invalid\n");
		return -EINVAL;
	}

	card->dev = &pdev->dev;
	for_each_card_prelinks(card, i, dai_link)
		dai_link->platforms->of_node = platform_node;

	ret = devm_snd_soc_register_card(&pdev->dev, card);
	of_node_put(platform_node);
	return ret;
}

static const struct of_device_id cosmo_sound_dt_match[] = {
	{ .compatible = "planet,cosmo-sound" },
	{}
};
MODULE_DEVICE_TABLE(of, cosmo_sound_dt_match);

static struct platform_driver cosmo_sound_driver = {
	.driver = {
		.name = "cosmo-sound",
		.of_match_table = cosmo_sound_dt_match,
		.pm = &snd_soc_pm_ops,
	},
	.probe = cosmo_sound_probe,
};
module_platform_driver(cosmo_sound_driver);

MODULE_DESCRIPTION("Planet Cosmo Communicator sound card (MT6771 AFE + MT6358)");
MODULE_LICENSE("GPL");
