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
 * on this phone, whatever the vendor kernel config suggests. Each GPIO is a
 * mixer switch here.
 * Modelled on mt8183-mt6358-ts3a227-max98357.c.
 */
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

static const struct snd_kcontrol_new cosmo_sound_controls[] = {
	COSMO_GPIO_SWITCH("Ext Amp Switch", COSMO_GPIO_EXTAMP),
	COSMO_GPIO_SWITCH("Ext Amp 2 Switch", COSMO_GPIO_EXTAMP2),
	COSMO_GPIO_SWITCH("Headphone Enable Switch", COSMO_GPIO_HP_EN),
	COSMO_GPIO_SWITCH("Headphone Select Switch", COSMO_GPIO_HP_CS),
};

static struct snd_soc_card cosmo_sound_card = {
	.name = "cosmo",
	.owner = THIS_MODULE,
	.controls = cosmo_sound_controls,
	.num_controls = ARRAY_SIZE(cosmo_sound_controls),
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
