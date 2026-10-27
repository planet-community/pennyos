# On-Device Recon Findings (ground truth)

Captured from the physical Cosmo over adb on 2026-07-17 (stock Android, **unrooted** —
so `dmesg`, live DTB, gpio/clocks/regulators were permission-denied; the data below is
what an unprivileged shell + SELinux allowed). Raw dumps:
`collected/device-dumps/20260717-190111/`.

> Re-run with root (Magisk `su`) to also get: `dmesg`, `/proc/config.gz`, live device
> tree (`/sys/firmware/fdt`), `clk_summary`, `regulator_summary`, gpio, pinmux. Those
> are the highest-value missing pieces for DT authoring.

## System identity
- Vendor kernel: **Linux 4.4.146** aarch64 (built 2020-07-06)
- SoC: **MT6771** · board `k71v1_64_bsp` · Android **9** · MediaTek `alps-mp-p0.mp1-V5.225`
- `ro.product.device/model = Cosmo_Communicator`

## Confirmed chips (from firmware blob names + kernel modules)
Firmware filenames were readable even where `ls` was denied — high-confidence chip IDs:

| Function | Chip / evidence |
|---|---|
| WiFi/BT/GPS/FM combo | **MediaTek MT6631** connectivity (`mt6631_fm_v1_coeff/patch.bin`, `WIFI_RAM_CODE_6759`, `WMT_SOC.cfg`); modules `wlan_drv_gen3`, `wmt_drv`, `bt_drv`, `gps_drv`, `fmradio_drv` (MTK connac/gen3, connsys) |
| NFC | **NXP PN553** (`libpn553_fw.so`) — *new find, not in prior web research* |
| Main touchscreen | **Novatek** (`novatek_ts_fw.bin`) — input dev `mtk-tpd`, 2160×1080 |
| Secondary touch (CoDi) | **Goodix GT1151** (`gt1151_default_firmware2.img`) — likely the cover-display touch |
| PMIC | **MT6370** on i2c bus @11017000, addr 0x34 (matches mainline DTS) |
| CoDi STM32 firmware | `/vendor/firmware/Cosmo_firmwarestem_ospi23.bin`, `Cosmo_resourceMB1314_EWIZ_resources.bin` (OSPI = STM32 octal-SPI flash) |
| Modem | MediaTek integrated (`md1img`/`md1dsp` partitions; C2K + reference-ril; `MNL.bin`) |

## CoDi cover display — on-device confirmation of the RE target
- Platform devices present: **`stm32_key`** and **`80207000.idc_suart`** (inter-die-comms
  serial UART) → the STM32 CoDi link.
- **`/dev/ttyS1`** exists, major 4 minor 65, mode **`crwxrwxrwx` (0777)** — matches the
  documented CoDi command channel (`init.project.rc` chmods it 0777). ✅
- Input devices: `cf-keys` (cover/function keys: HOME/MENU/WAKEUP/BACK/F18/F20/F21) and
  an **unnamed multitouch input** (`event4`, BTN_TOOL_FINGER + ABS_MT, zeroed ranges) —
  consistent with the CoDi cover touch (Goodix GT1151).

## Input devices (getevent -pl)
- `Integrated keyboard` (event3): full QWERTY + **KEY_FN** — the AW9523B matrix keyboard
- `mtk-tpd` (event5): main touch, ABS_X max 2160 / ABS_Y max 1080
- `cf-keys` (event2): cover/function keys
- `mtk-kpd` (event1): power/volume (PMIC keypad)
- `ACCDET` (event0): headset jack accessory-detect (audio present)
- unnamed (event4): CoDi cover touch (see above)

## I2C map (vendor 4.4 kernel — index differs from mainline!)
Map devices by **controller base address**, not bus index (mainline renumbers):

| Bus (base) | Addresses present | Likely |
|---|---|---|
| i2c-0 `11007000` | 0x53, 0x62 | (tbd) |
| i2c-1 `11011000` | 0x0c, 0x48, 0x77 | 0x0c NFC(PN553)? 0x48/0x77 sensors |
| i2c-2 `11009000` | 0x33, 0x40, 0x54, 0x72 | sensors / charger |
| i2c-3 `1100f000` | 0x25, 0x28, 0x39, 0x50, **0x5b** | 0x5b = **AW9523/AW9524 expander** |
| i2c-4 `11008000` | 0x10, 0x11, 0x35, 0x36, 0x43, 0x51, 0x54, **0x5b**, 0x72 | 0x5b = 2nd Awinic expander; touch/cam |
| i2c-5 `11017000` | **0x34**, 0x4e | 0x34 = **MT6370 PMIC** |

(Buses i2c-6..i2c-11 present but no client devices bound in sysfs.)

## Battery
Li-ion, `POWER_SUPPLY_CHARGE_FULL=2946000` (~**2946 mAh**), status Charging at ~1.5 A,
temp 23.0 °C, health Good. (Cosmo nominal is ~3550 mAh design; this unit's learned
full-charge is lower — expected for an aged cell.)

## Dual-boot partition layout (mmcblk0, by-name)
`boot`(p30) · `dtbo`(p32) · `lk`(p28)/`lk2`(p29) bootloader · `logo`(p31) ·
`md1img`(p15)/`md1dsp`(p16) modem · `DEBIAN_KDE`(p41) · `linux`(p43) ·
`EMPTY_NORMAL_BOOT_4`(p42)/`EMPTY_RECOVERY_BOOT_2`(p38) · `recovery` via boot ·
`super`/`system`/`userdata` standard. Gemian dual-boot layout — a spare `linux`/empty
boot slot is a candidate install target that preserves Android.

## Gaps to fill with a rooted re-run
dmesg (driver probe order, chip strings), `/proc/config.gz` (vendor defconfig), live DTB
(exact reg/gpio/interrupts per node — decompile with `dtc -I dtb -O dts`), clk/regulator
summaries, full sensor list.

---

# Rooted capture (2026-07-17) — device rooted via Magisk 26.1

Device rooted (recovery-installed `root-boot.img` on slot p42 `ROOTED_ANDROID`; Magisk
26.1). Full-privilege dump in `collected/device-dumps/20260717-194507-rooted/`:
`dmesg.txt` (510KB), `config-vendor.txt` (vendor defconfig, 4498 opts), **`live.dtb` +
`live.dts`** (decompiled, 7987 lines), `clk_summary.txt`, `regulator_summary.txt` (131
regulators), `i2c-names.txt`, `spi-names.txt`, `interrupts.txt`, `iomem.txt`, `pinmux.txt`.

> IMEI verified intact after rooting. NVRAM/modem partitions backed up + checksum-verified
> to `collected/nvram-backup/` (git-ignored — contains IMEI). See [rooting.md](rooting.md).

## Definitive I2C client names (root-readable)

| sysfs | name | Chip (per inventory) |
|---|---|---|
| 0-0053 | **solomon_touch** | CoDi cover touch = **Solomon Systech SSD20xx** (SoC-side) |
| 0-0062 | cap_touch | Main touch (Novatek) |
| 1-000c | msensor | Magnetometer AF6133E |
| 1-0048 | alsps | ALS/proximity STK3x1x |
| 1-0077 | barometer | BMP280 |
| 2-0040 / 4-0010 / 4-0035 | camera_main / _two / _sub | Cameras (+ eeprom/af nodes) |
| 3-0025 | fusb301a | Fairchild FUSB301A USB-C |
| 3-0028 | **nfc** | **NXP PN553** (@0x28 on i2c-3, IRQ GPIO71) |
| 3-0039 / 3-0050 | sii9022_hdmi / siiedid | SiI9022 HDMI-over-USB-C |
| 3-005b | aw9524_key | Awinic AW9524 (keyboard LEDs) |
| 4-005b | aw9523_key | Awinic AW9523B (keyboard matrix) |
| 5-0034 | subpmic_pmu | **MT6370** sub-PMIC |
| 5-004e | usb_type_c | USB-C controller @0x4e |

**SPI:** `spi:accelgyrosensor` (BMI160 IMU), `spi:cs_finger` (ChipSailing fingerprint),
`spi:aw6302` (Awinic fingerprint, 2nd driver). Both fingerprint drivers register.

## Resolves hardware-inventory open questions (§18)
- **CoDi touch = Solomon Systech** (`solomon_touch@53`, live driver `mediatek,solomon_touch`)
  — NOT GT1151/FocalTech. (§18.2 / §4d resolved.)
- **NFC = PN553 on i2c-3 @0x28** (`nfc` client + `libpn553_fw.so`). (§18.3 resolved.)

## CoDi / STM32 device-tree nodes (mainline authoring targets)
From `live.dts`:
- `idc_suart@80207000` — compatible `mediatek,idc_suart`. The inter-die-comms UART to the
  STM32 (exposed as **`/dev/ttyS1`**). **Nonstandard base (0x80207000, in the coprocessor/
  modem address region) — NOT one of the normal `apuart0-2` @ 0x1100_2000/3000/4000.** This
  is a key nuance for CoDi bring-up: mainline must map this special UART, not a generic one.
- `stm32_key` — compatible `mediatek, STM32_KEY-eint` (STM32 key/wake EINT).
- STM32 control GPIOs (pinctrl `aeon@77..84`): `stm32_download_fw`, `wake_stm32`,
  `reset_stm32`, `irq_stm32` — the lines to replicate for CoDi control/firmware-load.
- `solomon_touch@53` with reset GPIOs `aeon_tp_solomon_rst0/1` — the CoDi touch (I2C, SoC-side).

Implication for the RE plan: the CoDi's **display/control** path is the `idc_suart` UART +
STM32 GPIOs; the CoDi's **touch** is a separate I2C device (Solomon @0x53). Both must be
described in the mainline DT.
