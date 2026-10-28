# Device-Tree Gap Analysis: mainline vs vendor

Comparison of the mainline WIP device tree against the vendor ground truth, to drive
mainline bring-up. Sources:
- **Mainline**: `affenull2345/linux mt6771` → `mt6771-planet-cosmocom.dts` (890 lines) +
  `mt6771.dtsi` (44 lines, `#include "mt8183.dtsi"`).
- **Vendor**: decompiled live tree `collected/device-dumps/20260717-194507-rooted/live.dts`
  (7987 lines) + root-readable I2C/SPI client names (see [device-recon-findings](device-recon-findings.md)).

> **Key mapping fact:** mainline `&i2cN` label = vendor `i2c-N` controller (same index/base).
> The vendor comment in `&i2c4` (`reg = 0x11008100`) confirms `&i2c4` = base `0x11008000`,
> matching vendor `i2c-4`. So addresses/bus indices transfer directly.
>
> **Vendor uses MediaTek wrapper compatibles** (`mediatek,cap_touch`, `mediatek,msensor`,
> `mediatek,alsps`, `mediatek,solomon_touch`) — abstract HAL shims, *not* real chip drivers.
> Mainline must replace each with the upstream chip-specific binding.

## What mainline already enables ✅

| Node | Detail |
|---|---|
| `uart0` | serial console 921600n1 |
| `dsi0` + `panel@0` | `planet,cosmocom-x800-datong-panel` (mtk DRM DSI → KMS; framebuffer node is commented out) |
| `mmc0` / `mmc1` | eMMC HS400 8-bit / SD UHS 4-bit |
| `&i2c1,2,3,4,5,6,9,10,11` | enabled (**note: `&i2c0` NOT enabled — see below**) |
| `aw9523_led` (i2c3 @0x5b) | `awinic,aw9523-pinctrl` → gpio-leds (12 LEDs) |
| `aw9523_kb` (i2c4 @0x5b) | `awinic,aw9523-pinctrl` → `gpio-fastmatrix-keyboard` (8×7 matrix) |
| `mt6370` (i2c11 @0x34) | charger, backlight, tcpc (USB-C), regulators (DSV/vib), indicator LED, flashlight |
| `ssusb` + role-switch | USB-C OTG via MT6370 TCPC |
| `auxadc`, cpu/cci supplies | DVFS supplies from MT6358 |
| `&gpu` supplies | mali-supply/sram-supply wired — **but no panfrost node (GPU not actually enabled)** |

## Gap table — what's missing (priority-ordered)

Legend: **P1** near-term & tractable · **P1★** our RE proof-of-concept · **P2** valuable · **P3** hard/large

| # | Peripheral | Vendor evidence | Mainline status | Upstream driver? | Effort |
|---|---|---|---|---|---|
| P1 | **Main touchscreen** | `cap_touch@62` on **i2c0** (Novatek NT36xxx), `mediatek,cap_touch` | **absent** — `&i2c0` not even enabled | Novatek NT36xxx has an out-of-tree `nt36xxx` driver; not mainline. Alt: check `edt-ft5x06`/goodix — no, it's Novatek | med (enable i2c0 + port/write nt36xxx driver) |
| P1★ | **CoDi cover display** | `idc_suart@80207000` (`mediatek,idc_suart` → `/dev/ttyS1`), `stm32_key`, STM32 ctrl GPIOs (dl-fw/wake/reset/irq) | **absent** | **No kernel driver needed** — needs the special UART enumerated + userspace `codid` (`X!X!`) | med (map the nonstandard UART; port daemon) |
| P1★ | **CoDi touch** | `solomon_touch@53` on **i2c0** (`mediatek,solomon_touch`, Solomon SSD20xx) | **absent** | No upstream Solomon touch driver — write one (or userspace) | med-high |
| P1 | **GPU (Panfrost)** | Mali-G72 MP3 | supplies wired, **no panfrost node** | **Yes** — mainline `panfrost` supports Bifrost/G72 | low (add `gpu` compatible + panfrost node) |
| P1 | **Accel/Gyro IMU** | `spi:accelgyrosensor` (BMI160) | absent | **Yes** — mainline `bmi160` (i2c/spi) | low |
| P1 | **ALS/Proximity** | `alsps@48` (STK3x1x) | absent | **Yes** — mainline iio `stk3310` | low |
| P1 | **Barometer** | `barometer@77` (BMP280) | absent | **Yes** — mainline `bmp280` | low |
| P1 | **Magnetometer** | `msensor@0c` (Voltafield AF6133E) | absent | **No** upstream AF6133E — needs driver or skip | med |
| P2 | **NFC** | `nfc@28` on i2c3 (NXP PN553), IRQ GPIO71 | absent | **Yes** — mainline `nxp,nci`/`nxp-nci-i2c` (PN553 compatible) | low-med |
| P2 | **HDMI-out** | `sii9022_hdmi@39` + `siiedid@50` on i2c3 (SiI9022, over USB-C) | absent | **Yes** — mainline `sil,sii9022` DRM bridge | med |
| P2 | **Keyboard backlight** | ~~AW9524~~ SoC PWM_A on GPIO90 (driven from `aw9524_key.c`) | **done**: `pennyos-kbd-backlight.dtsi` | `pwm-mediatek` + `leds-pwm` | low |
| P2 | **Battery/charger validation** | MT6370 charger in DT | node present, **untested** | mt6370-charger upstream | low (validate) |
| P3 | **WiFi/BT/GPS/FM** | MT6631 + on-SoC CONNAC (`wmt_drv`, `wlan_drv_gen3`) | absent | Partial/complex — MTK CONNAC mainline support is limited | high |
| P3 | **Audio** | MT6358 codec + RT5509 smart-amp | mt6358.dtsi included (codec present) but **no sound card/AFE/RT5509** | mt6358 codec + mt8183-afe upstream; RT5509 needs `rt5514`? no — needs amp driver | high |
| P3 | **Cameras** | IMX576 + sub + eeprom/af on i2c2/i2c4 | absent | ISP/CSI on MTK mainline immature | high |
| P3 | **Fingerprint** | `spi:cs_finger` (ChipSailing CS358) / `spi:aw6302` | absent | No libfprint/kernel support | high (avoid) |
| P3 | **Modem** | integrated MTK modem (`md1img`/`md1dsp`) | absent | Not mainlined for MT6771 | very high |

## The single most important quick win to unblock touch

`&i2c0` (controller `0x11007000`) is **not enabled** in the mainline DTS, yet it hosts
**both** touch controllers (`cap_touch@0x62` main + `solomon_touch@0x53` CoDi). Enabling
`&i2c0` + adding the pinctrl is the prerequisite for any touch work.

## Recommended near-term sequence
1. **Build the existing DTB + kernel** (dev loop) — validate toolchain before changing anything.
2. **Panfrost** — smallest diff, biggest visible payoff (GPU accel → usable UI). Add the
   `gpu` compatible + panfrost node; supplies are already wired.
3. **Sensors** (BMP280, STK3310, BMI160) — all have upstream drivers; pure DT additions.
4. **Enable `&i2c0`** and start the **main touchscreen** (Novatek) — needs a driver port.
5. **CoDi PoC** (P1★) — enumerate the `idc_suart`, port `codid`; add `solomon_touch` after.

Concrete DT stubs for items 2–4 go in `devicetree/` as we implement them.
