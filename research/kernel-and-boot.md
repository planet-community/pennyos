# Kernel Strategy & Boot Chain: Cosmo (MT6771)

## The core leverage: MT6771 ≡ MT8183 (aliased)

MT6771 (Helio P70) has **no native mainline support** (no `mt6771*` DTS, no
`pinctrl-mt6771`/`clk-mt6771` upstream). The proven trick in `affenull2345/linux`:

```
// mt6771.dtsi
compatible = "mediatek,mt6771";
#include "mt8183.dtsi"      // inherit all real SoC IP
// then override idle-states / OPP (firmware workaround)
```

MT6771 and MT8183 (Kompanio 500, well-mainlined since ~v5.2) are close siblings (same
A73/A53 8-core layout, same peripheral IP generation). So the Cosmo boots on **mainline
MT8183 clk / pinctrl / i2c / uart / mmc drivers, reused as-is.** MT8183 is our **driver
source of truth**.

## affenull2345/linux `mt6771` — base Linux 6.4.0, frozen 2023-07-04

`mt6771-planet-cosmocom.dts` **is** wired into the Makefile and builds. Enabled:

| Subsystem | Detail |
|---|---|
| Serial console | uart0 @ 921600n1 |
| Display (DSI) | `dsi0`→panel `planet,cosmocom-x800-datong-panel`, 270° rot, MT6370 backlight |
| eMMC/SD | mmc0 eMMC HS400 8-bit 200MHz; mmc1 SD UHS 4-bit |
| I2C | i2c1/2/5/6/9/10 on; i2c3=LED expander, i2c4=keyboard expander, i2c11=MT6370 |
| Keyboard | `gpio-fastmatrix-keyboard`, 8×7 QWERTY matrix via **AW9523** expander @0x5b on i2c4 |
| LEDs | 2nd **AW9523** @0x5b on i2c3, 12 RGB LEDs |
| PMIC/USB-C | **MT6370** MFD @0x34 on i2c11: TCPC (USB-C role), backlight, OTG VBUS, DSV display-bias, vibrator LDO |
| USB | `ssusb` role-switch (GPIO79), OTG via MT6370 TCPC |
| FUSB301 | present but `#if 0`'d (superseded by MT6370) |

**Out-of-tree leaf drivers to upstream** (all 2023-07-04):
- `drm/panel: simple` — Cosmo panel
- `input/keyboard` — `gpio-fastmatrix-keyboard`
- `pinctrl` — Awinic **AW9523/AW9523B** expander *(check: mainline `pinctrl-aw9523` may now exist)*
- `usb/typec` — FUSB301 *(unused)*
- MT6370 block — **now largely upstream**, so may need only DT wiring

## Titan Pocket — NOT a mainline shortcut (premise correction)

Unihertz Titan Pocket (same MT6771) is **not in pmaports** and has **no mainline
status**. Only port is **Ubuntu Touch** on a downstream stock Android-11 BSP kernel
(`kernel-alps-mt6771`), hampered by Unihertz GPL non-compliance (prebuilt kernel, no
sources, missing binder). Value: a **register/config reference** for MT6771-specific
bring-up (touch, modem, audio, camera) — *downstream*, not mainline code.

Same for the **vendor Cosmo kernel** `planet-community/android_kernel_planetcom_mt6771`
(4.x): the authoritative source for exact chips, I2C addresses, GPIO maps, and init
sequences to fold into mainline DT + drivers.

## Boot chain (MediaTek)

`BootROM → Preloader → Little Kernel (LK/aboot, fastboot) → boot.img`

Gotchas for a custom kernel/boot.img on the Cosmo:
- **AVB hash footer required** — LK hard-requires it. Use `avbtool add_hash_footer`; in
  **unlocked/orange state** any throwaway test key is accepted.
- **DTB needs a dtbo-style header** — wrap the kernel DTB with `mkdtboimg create` before
  packing into the boot.img `--dtb` slot.
- **Flash path** — unlock bootloader → `fastboot` (LK exposes it) or SP Flash Tool.
  Need Cosmo `flash_offset_*` + pagesize (2048); crib from the Planet Gemini pmOS
  deviceinfo as a template.

## Strategy takeaways
1. Base work on affenull2345 `mt6771`; **rebase 6.4 → current LTS**. Keep the
   `#include "mt8183.dtsi"` approach.
2. MT8183 mainline = driver source of truth; Titan/Cosmo vendor BSPs = register reference.
3. Upstream the 4 leaf drivers; re-check AW9523 & MT6370 which may now be mainline.
4. Budget for AVB-footer + dtbo-header boot.img packaging.

## Key URLs
- Fork: https://github.com/affenull2345/linux/tree/mt6771
- Cosmo DTS: https://raw.githubusercontent.com/affenull2345/linux/mt6771/arch/arm64/boot/dts/mediatek/mt6771-planet-cosmocom.dts
- MT8183 dtsi: https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/mediatek/mt8183.dtsi
- Titan UT kernel: https://github.com/ubuntu-touch-unihertz-titan/kernel-alps-mt6771
- MTK LK/AVB: http://www.lieberbiber.de/2015/07/05/mediatek-details-little-kernel/ · https://github.com/chenxiaolong/avbroot/issues/238
- pmOS MT8183: https://wiki.postmarketos.org/wiki/MediaTek_MT8183
