# First-Boot Bring-up Log

Chronological record of attempts to boot the mainline kernel on the physical device,
so we resume cleanly.

## ⭐⭐ ROOT CAUSE FOUND BY DECOMPILING LK (2026-10-06) — mainline is back on
The mainline images never failed *in the kernel*: **LK asserted while preparing our DTB
and reset the phone before jumping.** Four independent fatal DT violations (vendor dtbo
overlay needs `__symbols__` + 61 labels; `/chosen/bootargs` mandatory; a `mediatek,scp`
node mandatory; static reserved-memory nodes that overlap LK's own reservations make it
hang). Full write-up: [lk-dtb-requirements](lk-dtb-requirements.md).

Fixed in `devicetree/mt6771-mtk-lk-compat.dtsi`; new image `boot/boot-mainline.img`
(slim + debug config) also carries a vendor-compatible pstore black box, a simplefb
console, and a dead-man warm reboot. ### ✅ CONFIRMED ON DEVICE 2026-10-06: mainline 6.4 boots to a busybox shell
Third image of the day. Userspace at ~1.0 s. Working: 8 CPUs, 6 GB RAM, PSCI, eMMC
(HS400) + SD, simplefb console on the panel (rotated, stays on), keyboard input device,
AW9523 expanders, MT6370, hardware watchdog, pstore. Log: `collected/slotlog-latest/`.

Learned along the way (all in [lk-dtb-requirements](lk-dtb-requirements.md) terms):
- **LK ignores our DTB's `/chosen/bootargs`** (it must exist, but LK latches bootargs from
  the stock `boot` partition's DTB before the menu). Real args go in the boot.img header.
- LK hands over with the watchdog **armed** (MODE 0x5d); mainline `mtk_wdt` feeds it.
- **A watchdog reset lands on a black screen with no menu and needs a hard (cold) reboot,
  so pstore is useless for now.** Logs are instead saved into the tail of our own slot
  (`tools/read-slotlog.sh`), which survives anything.

Fixed the same day (image #4, all confirmed on device):
- **USB gadget**: 6.4 `mtu3` waits for a hardware VBUS-valid signal that the Cosmo does
  not wire up, so in forced-peripheral mode it never attached. `kernel/patches/0002`
  forces VBUS valid → the Mac sees `/dev/cu.usbmodem*`; `tools/cosmo-sh.py` runs commands
  on the phone through it. (Left port, GPIO79 low.)
- **power-controller / larbs / iommu** now probe (`MTK_MMSYS=y`, `MTK_CMDQ=y`).
- **Unused regulators** stay on (`kernel/patches/0003`; 6.4 has no cmdline switch).

Still open: no battery/charger or thermal devices, keyboard is the only input device
(no touch), a `gpiochip_add_data_with_key` WARNING from the AW9523 driver, and the
watchdog-reset black screen. Display is still LK's framebuffer (no DRM/GPU yet).

### ✅ Debian 13 + GPU confirmed on device (2026-10-06)
Debian boots from the internal `linux` partition to a login prompt (`systemctl
is-system-running` = running, no failed units, root grown to 56 GB, RTC time correct).
`ssh cosmo@172.16.42.1` over the USB ECM gadget works from macOS with no host setup.
**Panfrost works**: `modprobe panfrost` → `mali-g72 id 0x6221`, 3 shader cores; Mesa 25.0
reports `Mali-G72 (Panfrost)`, GL 3.1 / GLES 3.1 on GBM and surfaceless EGL (context
creation verified; no on-screen rendering yet because there is no KMS display driver).
**Display driver is the next real task**: this unit's panel is `aeon_ssd2092_fhd_dsi_solomon`
(LK tries `aeon_nt36672_fhd_dsi_vdo_x800_datong` first and rejects it), not the datong
panel the affenull DTS describes, so `mediatek_drm` + panel-simple must not be loaded
as-is. LK's timings: 1080x2160, vsa 1 / vbp 43 / vfp 76, hsa 4 / hbp 20 / hfp 26, 4 lanes,
sync-pulse video mode, PLL 502 MHz.

### Display + GPU on the panel (2026-10-06, driver-level confirmed; awaiting eyes-on)
`modprobe mt6370_backlight; modprobe mediatek_drm; modprobe panel_simple; modprobe panfrost`
→ `card0-DSI-1: connected 1080x2160`, `fb1: mediatekdrmfb`; `kmscube -D /dev/dri/card0`
runs with renderer `Mali-G72 (Panfrost)` and both the display and GPU job interrupts count
up. Console moved with `con2fbmap 1 1`. Gotchas found:
- **Load order**: 6.4 `mtk_dsi` oopses (NULL drvdata in `mtk_dsi_bind`) if `panel_simple`
  is loaded first; rootfs has `softdep panel_simple pre: mediatek_drm`.
- **Esc is the power key.** logind now ignores a short press. `mtk-pmic-keys` disables the
  PMIC's hold-to-reset unless `mediatek,long-press-mode` is set
  (`devicetree/pennyos-power-key.dtsi`).
- **Reboot: FIXED (confirmed on device).** LK hands the watchdog over in dual /
  interrupt mode (`MODE = 0x5d`); a software reset then only raises an unhandled
  interrupt. `kernel/patches/0001` clears `IRQ_EN | DUAL_EN` at probe; `reboot` now
  resets to the boot menu. Power-off with USB attached is still open (likely the
  PMIC re-powering into Android's power-off-charging mode - unverified).
- Kernel note: `[drm] HFP + HBP less than d-phy, FPS will under 60Hz`.

### Touchscreen works (2026-10-06)
This unit's main touch is the Solomon TDDI itself (`ssd20xx` on EINT9 in Android), at
0x53 on i2c0 - not the Novatek at 0x62 (that is for NT36672-panel units), and not the
cover display's touch as earlier notes guessed. New driver `kernel/drivers/ssd20xx.c`:
`boot status 0x8000`, firmware reports 1080x2160, multitouch events arrive on
`/dev/input/event2`. niri 26.04 is the desktop (built from source; `tools/install-niri.sh`).
Also learned: mediatek-drm 6.4 advertises AFBC on SoCs that cannot scan it out
(`kernel/patches/0006`); niri applies the DT panel orientation itself.

Touch is rotated 180 degrees relative to the panel: fixed in the DT
(`touchscreen-inverted-x/y`). A udev rule (`tools/rootfs/files/99-pennyos-touch.rules`)
applies the same correction through libinput only when the running DT lacks that
property, so old and new boot images both behave.

The whole desktop setup is reproducible: `tools/mkrootfs.sh` now bakes in Mesa, the
session packages, niri (from `out/niri`), its config, the tty1 login hook and the rule.

Open power-state problem: after any reset or power-off from mainline the phone comes
back to a black screen (cover display and an LED stay on) and needs a second hard
reboot to reach the boot menu.

### Power: first measurements (2026-10-07) - the phone is a heavy drinker on mainline
- **Charging did not work at all** until `mt6370-charger` was allowed to load (it had
  been blacklisted). Driver defaults are 500 mA in / 900 mA charge; `penny-charge-setup`
  follows the Type-C advertisement (capped 1.5 A).
- `kernel/drivers/cosmo_fg.c` reads the MT6358 fuel gauge's instantaneous current
  (vendor sequence). First readings with the screen on, Wi-Fi associated, idle:
  **about -1.4 A (discharging)** at 3.3 V - roughly 4.6 W idle. At the same moment the
  charger reported `Not charging` although 5 V was present.
- The phone then **shut down** (battery ~3.3 V under that load) while the charge limits
  were being stepped 500 mA -> 1.5 A for a comparison. Whether the step itself
  contributed is unknown.
- No cpufreq and no cpuidle (removed in `mt6771.dtsi`), `clk_ignore_unused` /
  `pd_ignore_unused` on the cmdline, regulator cleanup disabled (patch 0003), and the
  modem that LK starts is never managed. All are suspects for the idle draw.
- The MT6370 ADC's ibus/ibat channels read 0 here; its vbat/vbus/vsys channels work.

### Debian 13 root filesystem - how it is built
- `tools/mkrootfs.sh` → `out/debian-rootfs.img` (debootstrap trixie minbase + our modules,
  systemd, sshd, networkd DHCP server on `usb0` = 172.16.42.1, user `cosmo`/`cosmo`).
- `tools/install-rootfs.sh` writes it to the internal `linux` partition (replaces Gemian).
- `tools/mkboot.sh rootfs` builds the boot image whose initramfs switches root to that
  partition (any key within 3 s, or a mount failure, drops to the debug shell instead).
- Kernel: slim + debug + `kernel/rootfs.config`. USB gadget is now CDC composite
  (ACM console + ECM ethernet). DRM/Panfrost/MT6370 charger+backlight are built as
  modules and blacklisted in the rootfs: `modprobe` them by hand to experiment.

Test loop: `tools/flash-slot.sh` → boot DEBIAN_KDE → wait for `LOG SAVED` → hold ESC →
boot Rooted Android → `tools/read-slotlog.sh`.

## ⭐ STRATEGY PIVOT (2026-07-19) — abandon hand-built mainline + UART; build pmOS on the vendor kernel; debug via pstore
Two big realizations reframed the whole effort:
1. **UART-over-USB-C is a dead end for us.** After an exhaustive campaign (see below) —
   D+/D− both ports/orientations/±VBUS, then SBU1/SBU2 with a proper **1.8 V FTDI
   (DSD SH-U09C5)** + Thunderbolt cable + CC debug-accessory resistors — we got **zero
   bytes on every one of ~20 configs** (matrix in [serial-test-matrix](serial-test-matrix.md)).
   Loopback PASSED throughout, so the rig was fine; the signal never reached us. The Cosmo's
   AP UART is `apuart0 @0x11002000` (1.8 V) but is evidently only on internal mainboard pads,
   not the external USB-C pins. **Parked; would need teardown.**
2. **We were building the hardest possible thing.** affenull2345's mainline mt6771 tree is
   early WIP (last commit 2023-07-04, no rootfs/init) — it never reaches userspace. The
   **proven** path is the **downstream vendor ~4.4 kernel**: Gemian boots it (user confirmed
   in the DEBIAN_KDE slot), and **postmarketOS `planet-cosmocom` boots to login (software
   rendering)** per its wiki — contributor **shymega**, from a pmaports **fork** (not merged;
   `packaged=no`). Kernel: `planet-community/android_kernel_planetcom_mt6771` branch
   `packaging`, defconfig `k71v1_64_bsp_defconfig`, DTS `k71v1_64_bsp.dts`.

### New plan
- Build **official pmOS for planet-cosmocom** via **pmbootstrap** (in a privileged Alpine
  Docker container — `tools/pmbootstrap/`, since removed; in git history), from shymega's pmaports fork, UI with
  software rendering. Flash to the DEBIAN_KDE slot by `dd` (the path that already boots
  Gemian). No hand-built kernel.
- **Blind debug via pstore/ram_console — VALIDATED END-TO-END on-device (2026-07-19):**
  vendor kernel reserves `ram_console @0x54400000` (→ `/proc/last_kmsg`) and
  `pstore @0x54410000` (→ `/sys/fs/pstore/console-ramoops`). Confirmed the nodes/addresses
  on-device; `/dev/mem` is absent (can't raw-read) but the two interfaces work. Did an
  `adb reboot` and read back a **full 262 KB** previous-boot log from BOTH — so a **warm**
  reboot preserves the region (a cold power-off wipes it; the MTK **watchdog** auto-warm-
  resets a hard hang, so we should still get the log). Reader: `tools/read-lastboot.sh`.
  This is our no-UART black box for any kernel we flash to DEBIAN_KDE.

### ⚠️ RECOVERY PROTOCOL (warm vs cold — tested 2026-07-19)
The region only survives a **WARM** reset. Measured:
- `adb reboot` → `last_kmsg` = **262 KB**, `hw_status: 2` → **WARM, preserved.** ✓
- **hold-ESC/power to force reboot** → `last_kmsg` = **74 B header only**, pstore empty,
  `hw_status: 0` → **COLD, WIPED.** ✗
So when a flashed kernel (pmOS) hangs, to read its log: **do NOT hold ESC.** Instead
(a) let the **MTK watchdog auto-warm-reset** it to the menu (wait ~30–60 s), or (b) if it
reaches a shell, `reboot` in software — then select Android and run `read-lastboot.sh`.
Only use hold-ESC as a last resort (it costs you that attempt's log).
NOTE: our current DEBIAN_KDE kernel (affenull mainline) has NO pstore/ram_console and hangs
early, so it writes nothing to the region — the black box only yields data once we flash a
**pstore-enabled** kernel (the vendor/pmOS 4.4 has it built-in).

---
## (Historical, pre-pivot) mainline bring-up notes
**Old blocker: early-boot hang, no observable output without a hardware UART.**

## What we built (all correct per the authoritative recipe)
- Mainline kernel `Image.gz` (affenull2345 mt6771 base, Linux 6.4) + Cosmo config fragment.
- Packaged `boot-mainline.img` / `boot-mainline-debug.img`: Android boot img **header v1**,
  **appended DTB** (`Image.gz-dtb`), **no MTK header**, offsets base `0x40078000` /
  kernel `0x8000` / ramdisk `0x14f88000` / tags `0x13f88000`, pagesize 2048.
- Verified this matches `planet-community/pmaports` `deviceinfo` exactly (appended DTB,
  no MTK header, same offsets). See [kernel-and-boot](kernel-and-boot.md).

## Hard facts learned
- **Bootloader is LOCKED**: `fastboot boot`/`flash` → "not allowed in locked state". So the
  pmOS `fastboot` path is unavailable; we must use **dd-to-slot + multiboot** (works — that's
  how the rooted-Android `root-boot.img` boots).
- The `DEBIAN_KDE` (p41) slot was an `EMPTY_NORMAL_BOOT` slot, booted by the multiboot with
  the same generic path as `ROOTED_ANDROID` (p42) where `root-boot.img` works. **The slot is
  not special** — so the failure is our kernel/DTB, not the slot.
- The `dtbo` partition holds 3 vendor overlays targeting `&reserved_memory`/`&chosen` via
  phandles. Whether LK applies them to our base DTB is unconfirmed (couldn't prove without
  serial), but the pmOS recipe says the base DTB is delivered appended, not via dtbo.

## Attempts
1. `boot-mainline.img` → p41, boot → **black screen, no USB gadget.** (config false-alarm:
   `COMMON_CLK_MT8183` IS enabled; not the cause.)
2. `fastboot boot` test → **denied (locked bootloader).** Ruled out the multiboot-slot theory
   indirectly; confirmed lock.
3. `boot-mainline-debug.img` (forced `dr_mode=peripheral` to decouple the gadget from mt6370)
   → p41, boot → a USB device appeared, but it was **VID `0x0e8d` (MediaTek preloader/Android/
   modem) emitting "READY"**, NOT our Linux `g_serial` gadget (`0x0525`). So the kernel still
   never reached USB init. Device boot-looped; recovered by power-cycling to Android.

4. **DTB verified CORRECT** (2nd research pass): the mandatory `mt6771.dtsi` deletions
   (`cpu-idle-states`, `operating-points-v2`, `idle-states` — the real MT6771 boot
   workaround) ARE applied in our compiled DTB. Reserved-memory carveouts present. So the
   DTB is not the bug. Also learned: mainline has NO early framebuffer by design (simplefb
   node commented out) → black screen is expected even on a good boot.
5. `boot-mainline-debugshell.img` (busybox initramfs spawning a shell on `/dev/ttyGS0`) →
   selected DEBIAN_KDE → the only USB device seen was **MediaTek preloader `0x0e8d:0x2000`
   ("READY" handshake, USB download mode)**, NEVER our Linux `g_serial` gadget (`0x0525`).
   **This is decisive: the kernel never reaches USB init — the failure is at the
   preloader/LK/early-kernel stage, before our kernel runs.** Device recovered via power-cycle.
6. **Slim-kernel size test inconclusive**: disabling DRM/media/sound only shrank `Image.gz`
   13.55→13.28 MB, because those were *modules* (don't count toward the loaded image). Our
   13.5 MB is builtin core from the generic arm64 defconfig; shrinking to vendor size
   (~9.5 MB) needs heavy builtin surgery. **Open theory:** MediaTek LK may reject/faill to
   load our oversized kernel (vendor is 9.5 MB) — the UART will confirm (LK prints load errors).

7. **Slim-kernel size test — NEGATIVE (size ruled out).** Rebuilt with aggressive builtin
   trims (`kernel/slim.config`): decompressed Image 40 MB → **29 MB**, compressed 13.5 MB →
   **8 MB** (smaller than the vendor's 9.5 MB / 25 MB). Flashed `boot-slim-debugshell.img`
   (9.5 MB total) to p41; user confirmed booting DEBIAN_KDE. Still **only MediaTek 0x0e8d,
   never our Linux gadget 0x0525.** So kernel size is NOT the cause.

## LK binary analysis (from collected/boot-backup/lk.img)
MediaTek LK (magic 0x88168858). Confirmed behaviors: **gunzips the kernel** ("decompress
kernel image...", "gunzip header is bigger than expectation! Error!"), reads the DTB from
**inside the kernel image** ("Can't find device tree. Please check your kernel image" →
appended-DTB is correct), **applies dtbo overlays** ("bldr_load_dtb", "androidboot.dtbo_idx",
dtbo-format asserts, "Bad overlay size!"), and appends the cmdline. Also has verified-boot
paths (bypassed for these unsigned alternate slots).

## Conclusion
The kernel **never reaches USB init** — failure is at LK/early-kernel, before console/USB.
Ruled out (all tested blind): DTB correctness, packaging, config essentials, **kernel size**.
No non-serial feedback can reach a failure this early. **Hardware UART is required and is
the efficient path.** Two remaining candidates, both serial-diagnosable:
1. **LK corrupts our mainline DTB by applying the vendor `dtbo` overlays** (LK does dtbo
   application; the 3 vendor overlays target nodes by phandle, which differ in our mainline
   tree → corruption → early fault). **Leading theory.**
2. Early-kernel fault before console init (MMU/PSCI/memory).

## Serial bring-up attempt 1 — D+/D− method FAILED (2026-07-18)
Got a **CP2102 USB-TTL adapter** (`/dev/cu.usbserial-0001`, 3.3 V IO). Built
`tools/serial-capture.py` (macOS IOSSIOSPEED arbitrary-baud, auto-reconnect,
timestamped log) + `tools/serial-loopback.py`. **Loopback PASSED @ 921600** — capture
path proven good. Then, per the "MediaTek USB-UART on D+/D−" theory, tried **every**
combination and got **ZERO bytes every time**:
- Ports: LEFT (nearest ESC) and RIGHT.
- Data pins: D+ and D−.
- Orientations: both plug flips.
- VBUS: absent, and present (adapter VCC = **measured 5 V** at the breakout pad).
- Multimeter at the LK menu: D+, D−, CC1, CC2 all ~0 V (40 mV/2 mV) in every orientation.

**ROOT CAUSE CONFIRMED: the UART TX is on SBU1 (A8), NOT D+/D−.** Neither breakout on hand
exposes SBU, so every D+/D− test was physically incapable of seeing it (the dead ~40 mV
was correct — nothing is muxed to the data pins).

Authoritative source: the **Unihertz Titan Pocket** pmOS wiki (same **MT6771** SoC), quoted
verbatim: *"UART is available on the USB Type-C port. **TX is SBU1 (A8)**. RX has not been
found yet; it is possibly disabled by eFuse. The logic level is **1.8 V**."* Their tested
BOM: **FT232RL** (3.3/5.5 V FTDI) + **AMS1117 1.8 V** buck feeding the FT232RL **VCCIO** pin
(so its IO reads 1.8 V logic) + a **Type-C male-to-female test board** to reach SBU1.

Key facts:
- **Pin: SBU1 (A8) = device TX** (boot log out). Swaps to SBU2 (B8) if the plug is flipped.
- **Receive-only** — RX is eFused/unavailable; we can read boot logs but not type. Fine.
- **1.8 V logic, 921600 8N1.** A 3.3 V CP2102 (VIH ≈ 2.3 V) can NOT reliably read 1.8 V →
  need a **VCCIO-1.8 V adapter (FT232RL+AMS1117-1.8V)** or a 1.8 V↔3.3 V level shifter.
- **No CC resistors mentioned** — SBU1 UART appears available without Debug Accessory Mode.
  Keep the `2×(10k‖10k)=5k` CC1/CC2→GND DAM trigger only as a fallback if SBU1 is silent.
- **VBUS**: not stated as required; try without first.

### Attempt 2 — BLOCKED on hardware (order these)
1. **SBU access**: a USB-C **male-to-female test/breakout board that exposes SBU1 (A8)**
   (24-pin breakout also works; the two breakouts on hand do NOT expose SBU).
2. **1.8 V-capable read path** — either:
   a. **FT232RL** + **AMS1117 1.8 V** module on its VCCIO (proven Titan-Pocket combo), or
   b. reuse the CP2102 + a **1.8 V↔3.3 V level shifter** (low side powered at 1.8 V).
Then: wire **SBU1 → adapter RXD, GND↔GND**, read **921600 8N1**, cold-boot, capture
preloader→LK→(kernel). Flip plug / try SBU2 if silent; add the CC DAM resistors as fallback.

## Leading hypotheses to test with serial (ranked)
1. **MediaTek LK corrupts the mainline DTB during its fixup pass** (patches `/memory`,
   `/chosen` assuming vendor layout). Most MTK-specific; affenull2345 got past it somehow.
2. Early driver-probe hang (i2c/PMIC path).
3. Memory/reserved-memory layout mismatch vs what LK expects.

## Device state / safety
- On **stock Android** (unrooted, stable). Rooted Android (p42), stock (p30), data, IMEI all
  intact. NVRAM + boot partitions backed up (`collected/nvram-backup`, `collected/boot-backup`).
- **Our failing image is on p41 (`DEBIAN_KDE`).** Do NOT select that multiboot entry until
  fixed (it boot-loops). Use "Rooted Android" or "Default Android". Gemian would need
  reinstalling if wanted (we didn't back up p41's original contents).

## Resume checklist (when UART is ready)
1. Wire UART to left USB-C, `screen /dev/cu.usbserial-* 921600`.
2. Boot rooted Android, re-flash latest `boot-mainline-debug.img` to p41 (dd, bs=1048576).
3. Power off, connect UART, power on, select DEBIAN_KDE, capture preloader→LK→kernel.
4. Diagnose the actual hang point from the log; fix DT/config; iterate.
