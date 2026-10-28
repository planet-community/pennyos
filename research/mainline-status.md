# Mainline Linux Status: Cosmo Communicator (planet-cosmocom / MT6771)

> This is the state of **upstream** before this project started. What works with this
> repo is in [docs/hardware-support.md](../docs/hardware-support.md).

**Snapshot (verified against live sources, mid-2026): mainline is a stalled mid-2023
proof-of-concept.** Boots to a text login with a software-rendered framebuffer and USB
networking. Never packaged into pmaports (cannot be selected in `pmbootstrap`). Anyone
running it uses an out-of-tree personal kernel branch + custom initramfs.

> Do not confuse with **Gemian** (Planet's official Debian on the downstream 4.4 Android
> kernel) — far more complete, but not mainline. See [distro-choice](distro-choice.md).

## The mainline kernel branch

`affenull2345/linux` branch `mt6771` — built on **Linux v6.5** (off v6.5-rc1). All
Cosmo commits landed **2023-07-04**; **no activity since**. Custom out-of-tree commits
(none upstreamed):

- `arm64: dts: mediatek: Add MT6771 and Planet Cosmo Communicator`
- `drm/panel: simple: Add support for the Planet Cosmo Communicator panel`
- `input: keyboard: Add Fast GPIO-driven keyboard/keypad matrix driver`
- `pinctrl: Add driver for Awinic AW9523/B I2C GPIO Expander`
- `usb: typec: Add support for the Fairchild FUSB301 port controller`

DTS: `arch/arm64/boot/dts/mediatek/mt6771-planet-cosmocom.dts`

### Nodes present in the DT (enabled)
- **Display**: `simple-framebuffer` + `planet,cosmocom-x800-datong-panel` (framebuffer/
  software render — this is why "screen works" but no GPU)
- **Physical keyboard**: `gpio-fastmatrix-keyboard` (driver + node exist)
- **LEDs / kbd backlight**: `gpio-leds` (12) + MT6370 indicator LEDs
- **USB**: `fcs,fusb301` Type-C controller, connector, role switch, MT6370 TCPC
- **PMIC (MT6370)**: ADC, backlight, charger, indicator, flashlight (cam flash)
- **Awinic AW9523** GPIO expander pinctrl

### Absent from the DT (unsupported)
GPU/Mali/Panfrost · touchscreen controller · WiFi · Bluetooth · cellular modem · GPS ·
audio codec · sensors · CoDi cover display · fingerprint reader

## Feature matrix (mainline)

| Category | Status |
|---|---|
| Main display/screen | **Works** — framebuffer / software render only |
| Physical keyboard | **Partial** — mainline driver + DT node exist; not validated |
| USB (Type-C, networking) | **Works** — USB networking confirmed |
| LEDs / kbd backlight | **Partial** — LED DT nodes present, untested; kbd backlight done (`pennyos-kbd-backlight.dtsi`, PWM_A on GPIO90) |
| Battery / charging | **Untested** — MT6370 charger in DT |
| Touchscreen | **Broken** — no controller in DT |
| GPU / 3D (Mali-G72 / Panfrost) | **Broken** — not enabled at all |
| WiFi / Bluetooth | **Broken/absent** |
| Modem / calls / SMS / data | **Broken/absent** |
| GPS | **Broken/absent** |
| Audio / speaker / mic / jack | **Broken/absent** — no codec in DT |
| Cameras / flash | **Untested** — only flash node in DT |
| Sensors (accel/gyro/prox/ALS/mag) | **Untested/absent** |
| Fingerprint reader | **Absent** |
| CoDi cover display (AMOLED) | **Absent** |
| eMMC / SD storage | **Untested** |
| Vibration, hardware buttons | **Untested** |
| Graphical shell (Phosh/Plasma) | **Not achieved** — login only, software render |

## pmaports reality
Recursive scan of official `postmarketOS/pmaports` returns **zero** `planet`/`cosmo`
files. No deviceinfo, no APKBUILD, no kernel package. `planet-community` hosts a pmaports
fork + nascent `linux-planet-mainline` (low activity).

## Key URLs
- Wiki: https://wiki.postmarketos.org/wiki/Planet_Computers_Cosmo_Communicator_(planet-cosmocom)
- Kernel branch: https://github.com/affenull2345/linux/commits/mt6771
- DTS: https://github.com/affenull2345/linux/blob/mt6771/arch/arm64/boot/dts/mediatek/mt6771-planet-cosmocom.dts
- pmaports (no cosmocom pkg): https://github.com/postmarketOS/pmaports
- Vendor kernel: https://github.com/planet-community/android_kernel_planetcom_mt6771
