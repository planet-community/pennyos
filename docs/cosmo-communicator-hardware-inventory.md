# Planet Computers Cosmo Communicator — Hardware Inventory / Component Teardown

Reference document for a **mainline-Linux porting effort**. Focus: exact part numbers, buses,
I2C addresses, GPIO/interrupt assignments, and how each component connects to the SoC.

- **Device:** Planet Computers Cosmo Communicator (2019), clamshell QWERTY, dual-boot Android/Linux
- **Board / internal codename:** `k71v1_64_bsp` (Planet "aeon" project); mainline compatible `planet,cosmocom`
- **SoC:** MediaTek Helio P70 = **MT6771V** (marked MT6771V/CT or V/WT; databases list the higher "T" bin)
- **FCC ID:** `2AO7Q-COSMO` (variant `2AO7Q-COSMOVE`), grantee **Planet Computers Ltd** (grantee code `2AO7Q`, shared with the Gemini PDA); grant 2019-12-12

**Confidence legend**
- **[K]** confirmed from the shipping Android kernel source (`planet-community/android_kernel_planetcom_mt6771`) — highest confidence
- **[M]** confirmed from the mainline WIP DTS / firmware source (affenull2345, OpenCodi, CoDiOS)
- **[F]** confirmed from FCC filing (photos / test reports)
- **[S]** from spec databases / reviews / vendor product pages
- **[I]** inferred (platform-typical or default value), flagged inline
- **[D]** confirmed on *this* physical device via adb (see §0b) — highest confidence

The stock kernel `[K]` and the FCC filing `[F]` are the authoritative primary sources; the mainline DTS `[M]`
reflects what is *actually ported so far* (very little). Where they disagree it is called out.

---

## 0. Quick-reference bus / address map (the part a porter wants first)

### I2C devices

| Bus | Device | Chip | Addr (7-bit) | IRQ GPIO | Reset/other GPIO | Src |
|---|---|---|---|---|---|---|
| tpd (main touch) | Main touchscreen | Novatek **NT36xxx** | **0x62** (flash 0x01) | GPIO9 | RST GPIO156 | [K] |
| tpd (CoDi) | Cover-display touch (SoC-side path) | Solomon Systech **SSD20xx** | **0x53** | via tpd | — | [K] |
| i2c1 | Accelerometer | Sensortek **STK8BA53** | **0x18** | — | — | [K] |
| i2c1/spi1 | Accel+Gyro IMU (fitted) | Bosch **BMI160** | **0x68** acc / 0x69 gyro | GYRO GPIO4 | also on SPI1 | [K] |
| i2c1 | Accel+Gyro IMU (2nd-source) | ST **LSM6DS3H** | 0x6a acc / 0x6b gyro | — | — | [K] |
| i2c1 | Magnetometer | Voltafield **AF6133E** | **0x0c** | — | RST GPIO79 | [K] |
| i2c1 | ALS + Proximity | Sensortek **STK3x1x** | **0x48** | ALSPS GPIO6 | — | [K] |
| i2c1 | Barometer | Bosch **BMP280** | **0x77** | — | — | [K] |
| i2c11 (3.4MHz) | Sub-PMIC / charger / TCPC | MediaTek **MT6370** | **0x34** | PMU GPIO10 | TCPC GPIO41 | [K][M] |
| audio bus | Speaker smart-amp | Richtek **RT5509** | **0x34** (separate bus) | — | en GPIO153 | [K] |
| i2c (HDMI) | HDMI transmitter | Silicon Image **SiI9022/9024** | TX **0x72**, HDCP 0x74, CBUS 0xC8, EDID 0xA0 | HPD GPIO78 | pwr GPIO160 | [K] |
| i2c | 2nd USB-C mux (alt) | Fairchild **FUSB301A** | 0x25 | GPIO166 | sel GPIO176 | [K][M] |
| (STM32-local) | CoDi touch (MCU-side path) | FocalTech **FT3x67** | 0x38 [I] | — | — | [M] |

> **RT5509 and MT6370 both report I2C 0x34** but sit on different I2C controllers, so there is no conflict.

### Non-I2C buses

| Bus | Device | Chip | Notes | Src |
|---|---|---|---|---|
| MIPI-DSI (dsi0, video) | Main panel | Novatek **NT36672** | 2160×1080, 270° rotated | [K] |
| MIPI-DSI | CoDi cover panel (SoC-side) | Solomon Systech **SSD2092** driver IC | AMOLED 240×536 | [K] |
| MIPI-CSI + I2C 0x10 | Rear camera | Sony **IMX576** | write-id 0x20 | [K] |
| MIPI-CSI | Front camera | undetermined (see §9) | — | [K] |
| SPI0 (≤1.5MHz) | Fingerprint (fitted) | ChipSailing **CS358** | side/power button | [K] |
| SPI2 | Fingerprint (2nd-source) | Awinic **AW6302** | alt driver compiled | [K] |
| UART (LPUART1, 115200 8N1) | CoDi MCU link | **STM32L4R9AII6** | packet magic `X!X!` | [M] |
| UART0 (921600 / 115200) | Debug console | — | RX GPIO95 TX GPIO96 | [K][M] |
| SDIO/UART (on-die CONSYS) | WiFi/BT/GNSS/FM | MT6771 CONNAC + **MT6631** RF | integrated | [K] |
| SPMI / pmic-wrapper | Main PMIC + codec | MediaTek **MT6358** | INT GPIO182 | [K][M] |
| MSDC0 (HS400) | eMMC 5.1 | 128 GB | non-removable | [K][M] |
| MSDC1 (SDR104) | microSD | up to 512 GB | shared w/ SIM2 | [K][M] |

### Interrupt (EINT) map — from the kernel DrvGen worksheet `k71v1_64_bsp.dws`

| GPIO | Function | GPIO | Function |
|---|---|---|---|
| GPIO4 | Gyro INT | GPIO41 | MT6370 TCPC (Type-C PD) INT |
| GPIO5 | Fingerprint INT | GPIO44 | DSI tear-effect (TE) |
| GPIO6 | ALS/Proximity INT | GPIO54 | HDMI detect |
| GPIO7 | **STM32 (CoDi) key** INT | GPIO71 | NFC IRQ (driver not enabled) |
| GPIO8 | **Hall** sensor (lid) INT | GPIO78 | SiI9022 HDMI INT/HPD |
| GPIO9 | Main touch INT | GPIO166 | FUSB301A USB-C INT |
| GPIO10 | MT6370 sub-PMIC INT | GPIO182 | MT6358 main-PMIC INT |
| GPIO11 | Fingerprint-key INT | GPIO12 | AW9523 keyboard INT |

---

## 0b. On-device confirmation (2026-07-17) — [D]

Cross-checked against a live adb dump from the physical device (stock Android 9, kernel
4.4.146, **unrooted**). Raw data + analysis: [`research/device-recon-findings.md`](../research/device-recon-findings.md),
dumps in `collected/device-dumps/20260717-190111/`. `[D]` = confirmed on this device.

**Confirmed present** (I2C address seen in sysfs and/or firmware blob named in `/vendor/firmware`):
- Main touch **0x62** on i2c@11007000 + `novatek_ts_fw.bin` → Novatek main touch ✅ `[D]`
- ALS/prox **0x48**, magnetometer **0x0c**, barometer **0x77** all on i2c@11011000 → STK3x1x + AF6133E + BMP280 ✅ `[D]`
- MT6370 sub-PMIC **0x34** on i2c@11017000 ✅ `[D]`
- Rear camera **0x10** on i2c@11008000 → IMX576 ✅ `[D]`
- Two Awinic expanders at **0x5b** (one on i2c@1100f000, one on i2c@11008000) → AW9523B kbd + AW9524 LED ✅ `[D]`
- `stm32_key` + `idc_suart@80207000` platform devices; **`/dev/ttyS1` mode 0777** → CoDi UART link ✅ `[D]`
- Input devices: `Integrated keyboard` (QWERTY+FN), `mtk-tpd` (2160×1080), `cf-keys`, `mtk-kpd`, `ACCDET` (audio jack) ✅ `[D]`
- Kernel modules `wlan_drv_gen3`/`wmt_drv`/`bt_drv`/`gps_drv`/`fmradio_drv` + `WIFI_RAM_CODE_6759`/`mt6631_*` → MT6631 combo ✅ `[D]`

**Resolves §18 open questions (confirmed with root — live I2C client names):**
- **NFC controller = NXP PN553** — i2c client `nfc` @ i2c3 **0x28** + firmware `libpn553_fw.so`. (§18.3 answered.) `[D]`
- **CoDi touch = Solomon Systech SSD20xx** — live i2c client **`solomon_touch`** @ i2c0 **0x53**,
  driver `mediatek,solomon_touch`. This is the *active* cover-touch path; the `gt1151` firmware
  blob is unused. (§18.2 / §4d resolved in favor of Solomon SoC-side.) `[D]`
- **Main touch** i2c client `cap_touch` @0x62; **AW9523** `aw9523_key` @ i2c4 0x5b (matrix) and
  **AW9524** `aw9524_key` @ i2c3 0x5b (LEDs); **MT6370** `subpmic_pmu` @ i2c5 0x34 — all `[D]`.
- **Fingerprint**: both `spi:cs_finger` (ChipSailing) and `spi:aw6302` (Awinic) register on SPI;
  IMU `spi:accelgyrosensor` (BMI160) on SPI. `[D]`

> Rooted dump (dmesg, vendor defconfig, decompiled **live.dts**, clocks/regulators) lives in
> `collected/device-dumps/20260717-194507-rooted/`. CoDi DT nodes for mainline: `idc_suart@80207000`
> (UART→STM32, `/dev/ttyS1`, nonstandard base), `stm32_key`, STM32 ctrl GPIOs, `solomon_touch@53`.

> Note: vendor-kernel I2C **bus indices** (i2c-0…11) differ from the mainline DTS numbering.
> Always map devices by controller **base address** (e.g. `11008000` = keyboard-expander bus),
> not by index.

---

## 1. SoC — MediaTek Helio P70 (MT6771V)

| Attribute | Value | Conf |
|---|---|---|
| Part number | **MT6771V** (databases list MT6771V/CT or /WT "T" bin) | [S] |
| Process | 12 nm FinFET (TSMC 12FFC) | [S] |
| CPU | Octa-core: **4× Cortex-A73 @ up to 2.1 GHz + 4× Cortex-A53 @ up to 2.0 GHz** (big cluster `cpu@0-3`, LITTLE `cpu@100-103`) | [S][M] |
| GPU | **ARM Mali-G72 MP3** (3 cores) @ up to 900 MHz; `mali-supply=mt6358_vgpu`, `sram=mt6358_vsram_gpu` | [S][M] |
| NPU/APU | MediaTek APU, dual-core (Tensilica Vision P6 DSP), ~280 GMAC/s | [S] |
| Memory controller | LPDDR4X, dual-channel, up to LPDDR4X-3600, SoC max 8 GB | [S] |
| Integrated modem | LTE **Cat-7 DL (300 Mbps) / Cat-13 UL (150 Mbps)**, dual-SIM dual-VoLTE | [S] |
| Co-processors | SCP (512 KB SRAM) enabled; MTK video codec driver enabled | [K] |

**Mainlining note [M]:** the affenull2345 DTS bases MT6771 on the mainline **MT8183** SoC definition
(`mt6771.dtsi` does `#include "mt8183.dtsi"`), then deletes cpuidle/cpufreq nodes as "broken —
firmware issue or misconfiguration." This is the single biggest architectural shortcut in the mainline port
and the reason clocking/idle is not yet functional.

---

## 2. RAM & Storage

| Item | Value | Conf |
|---|---|---|
| RAM | **6 GB LPDDR4X** | [S][M] |
| RAM chip vendor/part | not publicly disclosed | — |
| Internal storage | **128 GB eMMC 5.1** (NOT UFS) — `CONFIG_MTK_EMMC_SUPPORT=y` (+CQ/cache/OTP); mainline `mmc0` = HS400, 1.8 V, 8-bit, non-removable; vmmc=mt6358_vemc, vqmmc=mt6358_vio18, D-lines GPIO122–133 | [K][M][S] |
| eMMC chip vendor/part | not disclosed | — |
| microSD | up to **512 GB**; mainline `mmc1` = UHS SDR104/DDR50, 4-bit; vmmc=mt6358_vmch, vqmmc=mt6358_vmc, lines GPIO29–34, power GPIO178; card-detect EINT3 | [K][M][S] |
| microSD ⇄ SIM2 | tray takes 2× nano-SIM **or** 1× nano-SIM + 1× microSD (mutually exclusive) — but see SIM caveat in §8 | [S] |

---

## 3. Main Display + Touch

**Panel [K]**
- Internal **5.99" IPS TFT LCD, 2160×1080 (FHD+, 18:9), ~403 ppi**
- Controller/panel IC: **Novatek NT36672**
- LCM driver: `aeon_nt36672_fhd_dsi_vdo_x600_xinli` (`drivers/misc/mediatek/lcm/…`); defconfig
  `CONFIG_CUSTOM_KERNEL_LCM="aeon_nt36672_fhd_dsi_vdo_x600_xinli aeon_ssd2092_fhd_dsi_solomon"`,
  `CONFIG_LCM_HEIGHT="2160"`
- Bus: **MIPI-DSI video mode** (`dsi0`); physical rotation 270°
- GPIOs: LCM reset **GPIO45**, panel-bias enable (`lcd_bias_enn`) **GPIO125**; backlight + display-bias via MT6370 (BLED/DSV)
- Tear-effect (TE): GPIO44
- Caveat: bootloader `chosen` still names the older `nt35595_fhd_dsi_cmd_truly_nt50358_drv`; the
  kernel-active panel is the NT36672. Some early units may carry the alternate Truly/NT35595 panel.
- Mainline `[M]` uses a custom `planet,cosmocom-x800-datong-panel` compatible (`drm/panel: simple`) — the
  panel **works** under mainline (software rendering).

**Touch [K]**
- **Novatek NT36xxx** (`NVT-ts`), driver `drivers/input/touchscreen/mediatek/NT36xxx/nt36xxx.c`,
  `CONFIG_TOUCHSCREEN_MTK_NT36xxx=y`
- Bus: **I2C (MTK tpd)**, **addr 0x62** (bootloader/flash addr 0x01)
- INT **GPIO9**, RST **GPIO156**
- Mainline `[M]`: **not yet ported** — no touch node in the mainline DTS; wiki marks main touchscreen "Broken."

---

## 4. CoDi Cover Display + STM32 MCU + Cover Touch

The CoDi (secondary cover display) is the most complex subsystem and has **two connection paths** that
must be understood separately.

### 4a. The STM32 microcontroller [M]
- **STMicroelectronics STM32L4R9AII6** — Cortex-M4F, 120 MHz, 2 MB internal flash, 640 KB RAM, single-precision FPU
- Plus **4 MB external RAM** and **32 MB external NOR flash** (fonts/images/animations)
- Source: CoDiOS `DESIGN_NOTES.md`; corroborated by OpenCodi linker script `STM32L4R9AIIx_FLASH.ld`

### 4b. How CoDi connects to the SoC
- **Primary control link: UART** (Planet wanted a faster line "but this was not possible… communications
  are done over UART" — CoDiOS DESIGN_NOTES). OpenCodi drives **LPUART1, 115200 8N1, no HW flow control**. `[M]`
- **Framing:** packet magic `X!X!` = `0x58215821`, then size/id/sequence. Stock CoDi + CoDiOS use msgpack
  payloads (CoDiOS moving to Protocol Buffers). Command IDs include `CMD_MTK_EXTRA_COMMAND=113`,
  `CMD_MTK_CAMERA_FRAME_IMG=119`, `CMD_MTK_KEY_PRESS_INFO=120`. `[M]`
- **SoC-side GPIO control lines [K]:** STM32 wake **GPIO157**, reset **GPIO77**, firmware-download **GPIO80**,
  key/IRQ line **EINT7 = GPIO7** (`STM32_KEY`). No dedicated STM32 kernel driver in the stock tree — it is
  driven via GPIO + serial from userspace/firmware.
- **Video path (SoC → cover panel):** the stock kernel ALSO carries a **Solomon Systech SSD2092** DSI LCM
  driver (`aeon_ssd2092_fhd_dsi_solomon`, reset `tp_solomon_rst` GPIO156) and a **SSD20xx** cover-touch
  driver (`mediatek,solomon_touch`, I2C **0x53**). This is the path used when the main SoC drives the cover
  panel directly (mirror / "camera preview when closed" mode), distinct from the STM32's standalone mode.

### 4c. The CoDi display panel
- **AMOLED, 240×536 native** (marketed "1.91-inch, 570×240" = 536×240 rotated) `[M][S]`
- Driven (in standalone STM32 mode) by the STM32's internal **MIPI-DSI command mode + LTDC**; init is a
  sequence of DSI DCS short writes (page-select `0xFE…`, brightness `0x51`) `[M]`

### 4d. The CoDi touch panel — **conflicting evidence, verify on-device**
- **[M]** OpenCodi firmware: **FocalTech FT3x67** capacitive controller (`ft3x67_ts_drv`, `FT3X67_ID_VALUE`),
  2-touch, on the **STM32's own local I2C** (addr 0x38 = FocalTech default `[I]`).
- **[K]** Stock Android kernel: **Solomon Systech SSD20xx** (`mediatek,solomon_touch`) on the **main SoC I2C**, addr 0x53.
- **Reconciliation:** most likely the physical touch panel is the FocalTech FT3x67 read locally by the STM32,
  while the SSD20xx path is the main SoC reading touch when it drives the cover panel directly. Treat both as
  present; confirm which is live in each mode via `i2cdetect` (see §17).

**Relevant CoDi source:** `Treeki/OpenCodi` (STM32Cube C: display + FT3x67 touch + UART), and the
`Cosmo-CoDiOS` org: `CoDiOS` (Rust firmware), `codi_boot`, `codid` (cross-ROM daemon with Android/Droidian/
Gemian/postmarketOS/SailfishOS/UBports backends), `codi_protocols`, `planet-cosmo-stm32-kernel-driver`.

---

## 5. Physical Keyboard

- **Scanning/expander chip: Awinic AW9523B** I2C GPIO-expander/LED driver — handles the QWERTY matrix `[K][M]`
- Stock kernel `[K]`: `mediatek,aw9523_key` (+ `mediatek,aw9523_eint`), driver
  `drivers/misc/mediatek/aw9523/aw9523_key.c`, `CONFIG_MTK_AW9523=y`; INT **GPIO12**, SHDN/HWEN **GPIO175**.
  Also `CONFIG_KEYBOARD_MTK=y`; power key routed through the PMIC (`CONFIG_KPD_PWRKEY_USE_PMIC=y`).
- Mainline `[M]`: modelled as an **8-row × 7-col GPIO matrix** via a custom `gpio-fastmatrix-keyboard`
  driver hung off the AW9523B (`aw9523_kb`) on **i2c4 @400 kHz** (SCL/SDA GPIO105/106), expander addr
  **0x5b**, INT GPIO12, reset GPIO175. (New mainline drivers: "Fast GPIO-driven keyboard/keypad matrix" +
  "Awinic AW9523/B I2C GPIO Expander" pinctrl.)
- **Second expander: Awinic AW9524** (`mediatek,aw9524_key`, `CONFIG_MTK_AW9524=y`, SHDN/HWEN GPIO109) —
  used for status/lock LEDs and also toggles the SiI9022 HDMI hot-plug line. Mainline routes 12 indicator LEDs
  through a second AW9523B on **i2c3** (addr 0x5b, reset GPIO109). `[K][M]`
- **Backlight:** keyboard-backlight LED node via MT6370 / expander; keyboard-backlight flex marked
  `DOK-V532BU BLM VER:02` in FCC photos. `[K][F]`

---

## 6. Connectivity — WiFi / Bluetooth / GNSS / FM

- **WiFi + Bluetooth: MT6771 integrated CONSYS (CONNAC)** with **MediaTek MT6631** RF front-end —
  `CONFIG_MTK_COMBO_CHIP_CONSYS_6771=y`. On-die connectivity subsystem, no discrete Broadcom/Qualcomm combo. `[K]`
  - WiFi: **802.11 a/b/g/n/ac dual-band** (Wi-Fi 5); interface **SDIO** to SoC `[K][F][S]`
  - Bluetooth: interface **UART** (+PCM/I2S for audio). **Version conflict:** Planet marketing + reviews say
    **5.0**; GSMchoice/PhoneDB say 4.2. MT6631 supports BT5, so 5.0 is plausible; FCC tested BR/EDR + BLE. `[F][S]`
- **GNSS/GPS:** integrated in CONSYS (GPS/GLONASS/Galileo/BeiDou); external **GPS LNA control GPIO155**
  (`gpslna_pins`). Receive-only, so no FCC transmitter exhibit. `[K][F]`
- **FM radio:** `CONFIG_MTK_FM_CHIP="MT6631_FM"` (full FM RX via the MT6631 combo). `[K]`

---

## 7. Cellular Modem & SIM

- **Modem:** MT6771 integrated — LTE Cat-7 DL / Cat-13 UL, dual-SIM dual-VoLTE, 4G/3G/2G. `[S]`
- **RF transceiver:** **MT6177** (40 nm multimode 2G–4G/LTE-CA) — platform-typical, **inferred** (RF lives
  under RF shields / in modem firmware, not visible in kernel or FCC photos). Note: MT6169 is the *older*
  transceiver; the 12 nm P70 generation uses MT6177. `[I]`
- **Power amplifiers / antenna switch:** discrete multiband PAs (vendor varies per band plan). `[I]`
- **Bands (US SKU, from FCC test reports) [F]:** LTE **B2/4/5/7/12/17/25/26/41/66/71**; WCDMA 850/900/1900/2100;
  GSM 850/900/1800/1900. Other regional SKUs add bands (e.g. Japan adds B18/19/28).
- **SIM configuration — conflicting sources:**
  - FCC-agent finding `[F/S]`: **1× nano-SIM + eSIM** dual-SIM dual-standby, with a **separate/dedicated**
    microSD slot.
  - Spec-database finding `[S]`: hybrid tray = **2× nano-SIM OR 1× nano-SIM + microSD**.
  - **Verify on-device** — the two descriptions imply different tray hardware; confirm with the physical tray
    and `dmesg`/RIL logs.

---

## 8. Cameras

- **Rear / main camera [K]:** **Sony IMX576** (sensor ID `0x0576`), 24 MP, autofocus + LED flash.
  Driver folder is Cosmo-specific: `…/imgsensor/src/mt6771/camera_project/k71v1_64_bsp/imx576_mipi_raw/`.
  Bus **MIPI-CSI + I2C write-id 0x20 (7-bit 0x10)**. Cam0 GPIOs: **RST GPIO101, PDN GPIO97, MCLK GPIO99
  (CMMCLK0)**, digital-LDO enable GPIO91. Flash via MT6370 FLED. This is the outward-facing camera and doubles
  as the "selfie/video" camera when the clamshell is closed (feeding the CoDi preview).
- **Front / inner camera:** 5 MP fixed-focus. Cam1 GPIOs: **RST GPIO102, PDN GPIO98, MCLK GPIO100 (CMMCLK1)**.
  Exact sensor **undetermined** — no Cosmo-specific driver folder; defconfig lists generic candidates
  (`s5k2x7 sp5509 gc5035 gc5025`). Low confidence on the exact part. `[K][S]`
- MIPI-CSI lane counts not documented at device level. There is **no 24 MP front sensor** — the single 24 MP
  module faces out. `[S]`

---

## 9. Audio

- **Codec: MediaTek MT6358** (integrated in the main PMIC die, talks over the PMIC-wrapper) —
  `CONFIG_MTK_SND_SOC_CODEC="mt6358"`; includes **ACCDET** headset detection (`&accdet`). `[K][M]`
- **Correction (2026-10-13):** no RT5509 is present. The vendor kernel enables the driver, but the
  running Android system has no such I2C device; the speakers are driven from the MT6358 through
  amplifiers enabled by GPIO153 / GPIO111 (see the audio control GPIOs below).
- **Speaker smart-amp: Richtek RT5509** — `richtek,rt5509`, `sound/soc/codecs/rt5509.c`,
  `CONFIG_SND_SOC_RT5509=y`, **I2C addr 0x34** (own bus). `[K]`
- **Speakers:** stereo ("HD stereo speakers", grilles on left/right edges) + separate handset earpiece. `[S][F]`
- **Microphones:** 2–3 MEMS mics with silicone ducts and noise suppression (FCC teardown shows two MEMS mic
  assemblies). `[S][F]`
- **3.5 mm headphone jack:** present. `[S]`
- Audio control GPIOs `[K]`: ext-amp enable GPIO153, ext-amp2 GPIO111, HP-enable GPIO108, HP-cs GPIO107;
  PMIC audio bus GPIO136/138/139/142/143.

---

## 10. Power — PMIC / Sub-PMIC / Charging

- **Main PMIC: MediaTek MT6358** (9 bucks, 33 LDOs) — `CONFIG_MTK_PMIC_CHIP_MT6358=y`; INT **GPIO182**;
  SPMI / MediaTek pmic-wrapper. Hosts the **audio codec, vibrator, RTC, and power key**. Supplies vproc11/12,
  vsram, vgpu, vemc, vio18, vmch, vmc, vusb, vdram2. `[K][M]`
  - **Note:** the prompt hypothesized MT6357 — that is the low-end/IoT PMIC and is **not** used here.
- **Sub-PMIC / charger: MediaTek MT6370** (Richtek RT-family MFD) — `CONFIG_MFD_MT6370_PMU=y`, node
  `&mt6370_pmu` (I2C **0x34** on i2c11 @3.4 MHz, INT **GPIO10**). A true multifunction PMIC integrating: `[K][M]`
  - `MT6370_PMU_CHARGER` — single-cell Li-ion switching charger (integrated FETs)
  - `MT6370_PMU_FLED` — 2-channel camera flash LED
  - `MT6370_PMU_BLED` — display backlight (WLED, PWM mode 5)
  - `MT6370_PMU_RGBLED` — RGB notification LED
  - `MT6370_PMU_DSV` — panel display-bias (VPOS/VNEG boost)
  - `MT6370_PMU_LDO` (incl. a vibrator LDO on mainline)
  - `TCPC_MT6370` — USB Type-C / PD port controller (INT **GPIO41**)
- **Fast charge:** MediaTek **Pump Express Plus + PE Plus 2.0** — `CONFIG_MTK_PUMP_EXPRESS_PLUS_SUPPORT=y`,
  `…_20_SUPPORT=y`, `CONFIG_MTK_SWCHR_SUPPORT=y`; charger algorithm "SwitchCharging", 2 A AC. No official
  wattage published; GSMchoice claims "no quick charging" (contradicted by kernel). `[K][S]`
- A secondary Richtek **RT9465** charger (@0x4b) node exists but is **commented out/disabled** — Cosmo ships
  single-charger MT6370 only. `[K]`

---

## 11. Sensors

All on **I2C bus 1** unless noted. The MediaTek stack lists multiple second-source candidates and probes at
runtime, binding whichever is populated. `[K]`

| Sensor | Chip (fitted / candidates) | Compatible | I2C addr | IRQ | Conf |
|---|---|---|---|---|---|
| Accelerometer | Sensortek **STK8BA53** | mtk accel | 0x18 | — | [K] |
| Accel+Gyro IMU | Bosch **BMI160** (also on SPI1) | `mediatek,accelgyrosensor` / `bmi160-i2c` | 0x68 acc / 0x69 gyro | GYRO GPIO4 | [K] — best-supported fitted IMU |
| Accel+Gyro IMU (alt) | ST **LSM6DS3H** | `lsm6ds3hg` | 0x6a / 0x6b | — | [K] |
| Magnetometer | **Voltafield AF6133E** | `af6133e-new` / `mediatek,msensor` | **0x0c** | RST GPIO79 | [K] |
| ALS + Proximity | Sensortek **STK3x1x** | `mediatek,stk3x1x` | **0x48** | ALSPS GPIO6 | [K] |
| Barometer | Bosch **BMP280** | `barometer/BMP280-new` | 0x77 | — | [K] |
| Hall (lid open/close) | — (magnet + hall switch) | via EINT | — | **GPIO8** | [K] |

`CONFIG_CUSTOM_KERNEL_MAGNETOMETER=y`, `CONFIG_MTK_ALSPSHUB=y`. BMI160 default I2C 0x68 (0x69 if SDO high) —
matches the DTS. The STK3x1x ALS/prox node is the only one left `status="okay"` and fully tuned in the mainline
tree.

---

## 12. Fingerprint Reader

- Location: **side / power-button** area (front cover, below the CoDi display, doubles as a rocker/button
  flanked by two blue LEDs). Capacitive "sub-glass sensor." `[S][F]`
- **Fitted sensor: ChipSailing CS358** — `mediatek,cs_finger`, driver
  `drivers/input/fingerprint/chips_driver/cf_ctl.c`, `CONFIG_MTK_FINGERPRINT_CHIPSAILING_CS358=y`. `[K]`
  - Bus **SPI0** (≤1.5 MHz): MISO GPIO85, MOSI GPIO87, CLK GPIO88, CS GPIO86; **INT GPIO5** (edge-rising),
    **RESET GPIO53**; fingerprint-key INT GPIO11. Pins in `ChipSailing_pin.dtsi`.
- **2nd-source: Awinic AW6302** — `mediatek,aw6302`, driver `…/aw6302_driver/cf_ctl.c`, on **SPI2**. Both
  drivers compiled → sensor is dual-sourced across production runs; confirm which is fitted on a given unit. `[K]`

---

## 13. Battery

| Item | Value | Conf |
|---|---|---|
| Model | Planet **"Gemini Standard Battery"** (Cosmo reuses the Gemini cell) | [F] |
| Serial/part prefix | `SXX600…` (e.g. `SXX6002018061200752`) | [F] |
| Capacity | **4220 mAh** | [F][S] |
| Nominal / charge voltage | 3.85 V / 4.4 V | [F] |
| Chemistry | Li-ion pouch, built-in protection PCB (dual MOSFET + controller); connector carries ID + "Test" lines | [F] |
| Cell dimensions | ~136 × 62 × 3 mm | [F/I] |

Charge management via MT6370 (see §10). USB-C wired charging; exact wattage / USB-PD profile not officially
published; no wireless charging.

---

## 14. USB-C, Type-C & Video-Out

- **Two USB-C ports** (one each side), **USB 2.0 High-Speed** (SoC MU3D dual-role / XHCI-MTK;
  `CONFIG_USB_MU3D_DRV=y`, `CONFIG_USB_XHCI_MTK=y`, `CONFIG_USB_MTK_DUALMODE=y`). SuperSpeed disabled
  (`u3p-dis-msk=1`). vusb33 = mt6358_vusb. `[K][M][S]`
- **Type-C CC / PD controller:** **MT6370 TCPC** (INT GPIO41) — no separate standalone Type-C controller. `[K][M]`
- **Second USB-C orientation/mux: Fairchild FUSB301A** — `mediatek,fusb301a-pin`,
  `CONFIG_USB_C_SWITCH_FUSB302=y`; INT **GPIO166**, switch-enable GPIO177, switch-select GPIO176; left/right
  port D+/D- switch **GPIO79**. (Mainline notes a `fcs,fusb301` @0x25 alternative TCPC that is `#if 0`-disabled.) `[K][M]`
- **HDMI transmitter (video-out over USB-C): Silicon Image SiI9022/9024** — `CONFIG_CUSTOM_KERNEL_HDMI="sil9024"`,
  `CONFIG_MTK_HDMI_SUPPORT=y`, driver `drivers/misc/mediatek/hdmi/sil9024/`. I2C: **TX 0x72**, HDCP 0x74,
  CBUS 0xC8, EDID ROM 0xA0. INT/HPD **GPIO78**, power-enable GPIO160, hot-plug GPIO178, detect GPIO54
  (`hdmi_plug` node). `[K]`

---

## 15. Vibrator, LEDs, Buttons, Misc

- **Vibrator:** `mediatek,vibrator` (MT6358 timer-based); vib_vol level 9, 25 ms timer. `[K]`
- **LEDs:** RGB notification LED via MT6370 RGBLED (`mediatek,red/green/blue`); plus `keyboard-backlight`,
  `button-backlight`, `jogball-backlight`, `lcd-backlight` (MT6370 BLED). Two blue call LEDs flank the
  fingerprint rocker. Status/lock LEDs via the AW9523/AW9524 expanders. `[K][F]`
- **Hardware buttons:** power key via MT6358 PMIC; volume/side keys via the keypad matrix; fingerprint area is
  a physical rocker. `[K][S]`
- **Hall sensor:** lid open/close detect, INT GPIO8. `[K]`
- **IR transmitter:** `&irtx_pwm` node on GPIO90 exists but is **commented out** in the Cosmo DTS → **not
  fitted**. `[K]`
- **NFC — conflicting evidence:**
  - **[F]** FCC filing includes a **13.56 MHz NFC test report** → NFC hardware is present; Planet marketed NFC
    (a headline addition over the Gemini). `[F][S]`
  - **[K]** Stock kernel defines NFC pins (`aeon_gpio.dtsi`: VEN GPIO17, IRQ GPIO20 / EINT71) but **no NFC chip
    driver is enabled in defconfig**.
  - **Reconciliation:** NFC hardware is almost certainly present (FCC-tested + marketed); the exact controller
    chip is not identified in the kernel and the driver is either out-of-tree or vendor-blob. **Identify the
    NFC controller on-device / from a fuller teardown before relying on it for mainline.**

---

## 16. Notable "phantom" nodes to ignore (aeon template inheritance)

The `aeon_gpio.dtsi` file is shared across Planet's "aeon" hardware and contains named pins for features the
Cosmo does **not** have — e.g. `larser`/laser, `tof`, `aim`, `ill`, `camscan`. These are inherited templates,
not Cosmo components. The authoritative pin sources are `k71v1_64_bsp.dws` (EINT map) and `k71v1_64_bsp.dts`.

---

## 17. On-device verification (Android) — how to confirm each item

Run from an Android root shell (`adb shell` + `su`) on the Android side of the dual-boot. `i2c-tools`
(`i2cdetect`, `i2cget`) may need to be pushed as static binaries; MediaTek exposes I2C at `/dev/i2c-*`.

### SoC / CPU / clocks
```sh
cat /proc/cpuinfo                         # 8 cores; Cortex-A73/A53 part numbers (0xd09 / 0xd03)
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq
cat /proc/device-tree/model               # board/model string
ls /proc/device-tree/                     # walk the live DT
cat /sys/devices/platform/*.mali/…        # Mali GPU (or /proc/mali)
```

### Memory / storage
```sh
cat /proc/meminfo                         # ~6 GB total
cat /sys/block/mmcblk0/device/type        # "MMC" => eMMC (vs "SD")
cat /sys/block/mmcblk0/device/name /sys/block/mmcblk0/device/manfid /sys/block/mmcblk0/device/cid
cat /proc/emmc                            # MTK eMMC partition map
```

### I2C bus scan (fastest way to confirm addresses in §0)
```sh
ls /dev/i2c-*
for b in $(seq 0 11); do echo "== bus $b =="; i2cdetect -y -r $b 2>/dev/null; done
# Expect: touch 0x62; sensors 0x18/0x68/0x0c/0x48/0x77 on the sensor bus;
#         MT6370 0x34; RT5509 0x34 (other bus); SiI9022 0x72; CoDi-touch 0x53/0x38
```

### Displays / touch
```sh
dmesg | grep -iE 'nt36|nt35|lcm|dsi|panel|solomon|ssd20|touch|tpd'
ls /sys/class/graphics/ /sys/class/drm/
getevent -lp                              # lists input devices incl. touch controllers + keyboard
cat /proc/bus/input/devices               # names of NVT-ts, ssd20xx, aw9523 keypad, etc.
```

### CoDi / STM32
```sh
dmesg | grep -iE 'stm32|codi|solomon|ft3x67'
ls -l /dev/ttyS* /dev/ttyMT*              # UART to the STM32 (LPUART side is on the MCU)
ps -A | grep -i codi                      # codid daemon if a CoDi ROM is installed
cat /proc/device-tree/…/stm32*/…          # wake/reset/download GPIO wiring
```

### Keyboard
```sh
getevent -lp | grep -iA20 -E 'aw9523|matrix|keypad'
dmesg | grep -iE 'aw9523|aw9524|keypad|kpd'
cat /sys/class/leds/keyboard-backlight/brightness
```

### Connectivity / modem / GNSS
```sh
dmesg | grep -iE 'consys|connac|mt6631|wlan|bt_|gps|wmt'
lsmod | grep -iE 'wmt|conn|wlan|fmradio'
cat /proc/driver/wmt_dbg 2>/dev/null
# Modem/RIL:
getprop | grep -iE 'ril|gsm|modem|baseband'
dmesg | grep -iE 'ccci|md1|modem'         # MediaTek CCCI modem interface
```

### Sensors
```sh
dumpsys sensorservice | sed -n '1,60p'    # lists accel/gyro/mag/als/prox with vendor+part
dmesg | grep -iE 'bmi160|stk3x1x|stk8ba|af6133|lsm6ds3|bmp280|alsps|accel|gyro|msensor'
```

### Fingerprint
```sh
dmesg | grep -iE 'chipsailing|cs_finger|cs358|aw6302|fingerprint|fpc'
ls /dev/ | grep -iE 'finger|goodix|cs_'
ls /sys/bus/spi/devices/                  # SPI0 = fingerprint
```

### Power / PMIC / charging / battery
```sh
dmesg | grep -iE 'mt6358|mt6370|pmic|charger|pump_express|pe_?plus|typec|tcpc'
cat /sys/class/power_supply/battery/uevent   # capacity, voltage, status, technology
cat /sys/class/power_supply/*/type
cat /sys/class/power_supply/battery/charge_full_design   # ~4220000 (µAh)
```

### USB-C / HDMI
```sh
dmesg | grep -iE 'mu3d|xhci|typec|fusb30|mt6370_typec|sil9024|hdmi'
cat /sys/class/typec/port*/…
```

### Vibrator / LEDs / hall / buttons
```sh
ls /sys/class/leds/                       # red/green/blue, *-backlight nodes
dmesg | grep -iE 'vibrator|hall|smartpa|rt5509'
getevent -lp | grep -iA10 hall
```

### Generic
```sh
dmesg > /sdcard/cosmo-dmesg.txt           # full boot log — richest single artifact
lsmod                                     # loaded modules ≈ populated chips
cat /proc/interrupts                      # confirms EINT/GPIO map in §0
```

---

## 18. Open questions / lowest-confidence items (verify before relying on them)

1. **Front camera sensor** — exact part undetermined (candidates s5k2x7 / sp5509 / gc5035 / gc5025). `[K]`
2. **CoDi touch controller** — FT3x67 (STM32-local, `[M]`) vs SSD20xx (SoC-side, `[K]`); both present on
   different paths, confirm which is live per mode.
3. **NFC controller chip** — hardware present (FCC 13.56 MHz test) but no in-kernel driver identifies the part.
4. **RF transceiver** — MT6177 inferred (platform-typical), not proven in kernel/FCC.
5. **Bluetooth version** — 5.0 (marketing) vs 4.2 (databases).
6. **SIM topology** — eSIM+nano-SIM vs dual-nano/hybrid-microSD; sources conflict.
7. **DRAM / eMMC vendor parts**, main-panel exact glass, MIPI lane counts — not published; read from
   `mmcblk0/cid` and DT on-device.
8. **Main panel variant** — some units may carry the alternate Truly/NT35595 panel named in the bootloader.

---

## 19. Primary sources

**Stock Android kernel `[K]`** — `github.com/planet-community/android_kernel_planetcom_mt6771` (board `k71v1_64_bsp`):
- `arch/arm64/boot/dts/mediatek/k71v1_64_bsp.dts`, `mt6771.dts`, `aeon_gpio.dtsi`, `ChipSailing_pin.dtsi`
- `arch/arm64/configs/k71v1_64_bsp_defconfig`
- `drivers/misc/mediatek/dws/mt6771/k71v1_64_bsp.dws` (EINT map)
- driver dirs under `drivers/input/touchscreen/mediatek/`, `drivers/input/fingerprint/`,
  `drivers/misc/mediatek/{sensors-1.0,lcm,hdmi/sil9024,aw9523,aw9524,imgsensor}`, `sound/soc/codecs/`

**Mainline WIP / firmware `[M]`**
- affenull2345 kernel branch `mt6771`: `github.com/affenull2345/linux/commits/mt6771`
  (`arch/arm64/boot/dts/mediatek/mt6771-planet-cosmocom.dts`, `mt6771.dtsi`)
- postmarketOS wiki: `wiki.postmarketos.org/wiki/Planet_Computers_Cosmo_Communicator_(planet-cosmocom)`
  (status: boots to login, software-render only; touch/3D broken; radios/sensors untested; not yet in pmaports)
- CoDi firmware: `github.com/Treeki/OpenCodi`; `github.com/Cosmo-CoDiOS` (`CoDiOS/DESIGN_NOTES.md`, `codid`,
  `planet-cosmo-stm32-kernel-driver`)

**FCC `[F]`** — FCC ID `2AO7Q-COSMO`: `fccid.io/2AO7Q-COSMO`, `fcc.report/FCC-ID/2AO7Q-COSMO`
(internal photos `4548212.pdf` etc.; cellular test reports; U-NII/DFS/2.4G Wi-Fi; BT/BLE; NFC 13.56 MHz
`4548198.pdf`; two SAR reports). Teardown photos by AUDIX; RF tests by Shenzhen UnionTrust (UTT), report
`190725019RFM-2`. Shared grantee with Gemini (`2AO7Q-X600M1` / `-X600W1`).

**Specs / community `[S]`** — MediaTek Helio P70 product page; WikiChip; Notebookcheck;
GSMchoice (`gsmchoice.com/en/catalogue/planet/cosmocommunicator/`); PhoneDB (`id=14708`); Pocketnow review;
OESF Portables forum teardown/battery threads (`oesf.org/forum` topics 36134, 36950).

---

*Compiled 2026-07-17 for mainline-Linux porting reference. Highest-trust data comes from the shipping kernel
`[K]` and the FCC filing `[F]`; the mainline DTS `[M]` reflects current (limited) port progress. Re-verify the
§18 open items on real hardware.*
