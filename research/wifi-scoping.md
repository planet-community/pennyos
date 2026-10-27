# Internal Wi-Fi / Bluetooth: scoping pass (2026-10-06)

Question: how hard is it to get the Cosmo's built-in Wi-Fi/BT (MT6771 "consys" +
MT6631 RF) working on our mainline 6.4 kernel? Method: fetched the vendor sources,
measured them, and trial-compiled them unmodified against our kernel tree.

## What exists as source
`planet-community/android_kernel_planetcom_mt6771` (branch `packaging`),
`drivers/misc/mediatek/`:

| Part | Vendor module | Size | Notes |
|---|---|---|---|
| Control layer ("WMT"/STP) | `wmt_drv` | 57.5k lines / 39 files (all platforms) | includes `platform/mt6771.c`, the consys power-up sequence (1067 lines) |
| Wi-Fi | `wlan_drv_gen3` | 149.6k lines / 89 files | host interface `ahb_sdioLike` (memory-mapped + DMA), not real SDIO |
| Wi-Fi char-dev shim | `wmt_chrdev_wifi` | 1k lines | |
| Bluetooth | `bt_drv` | 5.5k lines | a char device (`/dev/stpbt`) for Android's BT stack, **not** an HCI driver |
| BT transport | `btif` | 7.3k lines | |
| GPS / FM | `gps_drv` / `fmradio_drv` | 1.8k / 20.9k lines | same control layer |

Binary-only pieces: firmware for the radio's own CPU (`WIFI_RAM_CODE_6759`,
`ROMv4_be_patch_1_{0,1}_hdr.bin`, `WMT_SOC.cfg`, in `/vendor/firmware`) - loaded, never
modified - and Android's `wmt_loader` / `wmt_launcher` daemons that feed them in.

## Trial compile against 6.4 (no changes, `-Wno-error`)

| Part | Result |
|---|---|
| Control layer | **30 of 45 files compile as-is.** 15 files, 75 error lines, all mechanical: `struct timeval`/`do_gettimeofday` (19), `ioremap_nocache` (7), `proc_create` ops type (5), `class_create` signature (4), `linux/wakelock.h` (1 header), one PMIC enum. |
| Wi-Fi gen3 | Only 19 files reached before `make -k` gave up on dependents: 207 error lines in 17 files. Same mechanical classes plus real cfg80211 drift (`net_device->ieee80211_ptr` users, `station_parameters` layout, `NL80211_TESTMODE` required), `get_fs`/`mm_segment_t` file I/O, `access_ok`. 809 cfg80211/nl80211 call sites in total. |
| btif, bt | Not exercised (their Makefiles only build built-in; needs a small Kbuild wrapper). |

## Vendor-kernel dependencies (the part that is not mechanical)
Surprisingly few. `platform/mt6771.c` uses mostly standard APIs (regulators, `clk_*`,
`of_iomap`, reserved memory). The MediaTek-only pieces:
- 12 raw PMIC register writes (`KERNEL_pmic_set_register_value`) -> regmap on the
  mainline MT6358 MFD
- the `conn` power domain (present in mainline's MT8183 scpsys - shows as `conn` in
  `pm_genpd_summary` on the device)
- clock-buffer control for the 26 MHz RF clock (`mtk_clkbuf_ctl.h`)
- one EMI MPU call (memory protection for the region shared with the radio)
- wakelocks (65 uses), early-suspend, AEE crash hooks, DVFS/CPU-boost hints -> stubs
- reserved memory: LK already hands us `consys-reserve-memory` (2 MiB) via the DT

## Prior art
The same driver family (WMT + `wlan` for the MT6625L combo chip on the Banana Pi R2,
MT7623) has been carried out-of-tree against mainline kernels for years, with the
`wmt-tools` userspace replacing Android's daemons. Mainline also has `btmtkuart`, which
drives MediaTek BT over the BTIF serial block on MT7622. Neither is our generation
(gen3 / consys 6771), but both show the approach works and give fixes to copy.

## Estimate
1. Control layer compiling + loading on 6.4, consys powering up, firmware patch
   downloaded (visible success: WMT reports the chip ID): **about a week**. Main risk:
   power sequencing details hidden in vendor PMIC/clock-buffer code.
2. Wi-Fi gen3 compiling and associating: **two to four weeks** on top. Mostly volume
   (150k lines against six kernel-years of cfg80211 changes), moderate risk.
3. Bluetooth usable from BlueZ: needs an HCI front-end instead of `/dev/stpbt`
   (either adapt `btmtkuart`-style code or a small shim): **about a week** after step 1.

Not verified: that the firmware blobs load under our power-up, that EMI MPU setup can
be skipped or done from the kernel, and how much of gen3 beyond the first 19 files breaks.

## Stage 1 result (2026-10-06): the radio is alive on mainline
With `devicetree/pennyos-consys.dtsi`, the four out-of-tree modules and `penny-wmtd`
(`penny-conn-up bt` on the device):
- consys powers up through the CONN power domain; `polling_consys_chipid` reads
  **0x0788** from the radio; `CONSYS-HW-PWR-ON, finish(0)`
- the daemon is asked `srh_patch`, sees chip 0x788 / hw 0x8a00 / fw 0x8a00, and hands
  over `ROMv4_be_patch_1_1_hdr.bin` (seq 1) and `..._1_0_hdr.bin` (seq 2)
- `BT_open: WMT turn on BT OK!` / `STP is ready!` 1.7 s after power-on start
- power-off on close is clean

What turned out not to matter (so far): the EMI MPU call (stubbed, firmware still runs),
clock-buffer control (hardware-driven), the modem coexistence bridge (stubbed).
Real fixes needed on the way: CONN as a genpd instead of a clock; the 6.4 MT6358 driver
registers one `ldo_vcn33`, not `_bt`/`_wifi`; vendor code dereferenced `ERR_PTR` supplies.
`WMT_STEP.cfg` is requested and absent (optional debug config).

## Stage 2 result (2026-10-06): Wi-Fi scans on mainline
`wlan_drv_gen3.ko` + `wmt_chrdev_wifi.ko` (ported the same way; 6.4 cfg80211, patch 0007
for wireless extensions) with `wifi@180f0000` in the DT and `penny-conn-up wifi`:
- NVRAM calibration accepted (`WR-BUF:NVRAM`, 1024 bytes from the July nvdata backup)
- firmware `WIFI_RAM_CODE_6759` loaded from `/etc/firmware`, `wlan0` registered with the
  NVRAM MAC address
- `iw dev wlan0 scan` returns networks on both 2.4 GHz and 5 GHz (38 channels scanned)
Gotchas: the helper's default char major 153 is SPI's in mainline (use `WIFI_major=155`);
one firmware complaint seen at power-on: `RF Stat WF_Sx LPAON_LPCR Fail!` (unexplained).
Not yet tested: association, data, throughput, power save, AP/P2P, suspend.
