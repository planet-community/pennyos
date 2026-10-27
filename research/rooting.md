# Rooting the Cosmo (V23) — safe, IMEI-preserving path

**Device confirmed on V23** (`ro.build.display.id = Cosmo-9.0-Planet-07062020-V23`), so
the `root-boot.img` from `planet-community/cosmo-v23-rooted-android` matches exactly.

## The IMEI question — answered

IMEI loss reported on the Cosmo (OESF thread 35879) was caused by **flashing full
firmware with SP Flash Tool** (which wipes NVRAM), *not* by the rooting method. One user
(usagi87) lost IMEI via SP Flash Tool v23 flash; another (HAL) recovered it by restoring
the **nvram** partition from a TWRP backup.

**We avoid SP Flash Tool entirely.** IMEI lives in `nvram`(p27), `nvdata`(p7),
`nvcfg`(p6), `protect1`(p9)/`protect2`, `proinfo`(p14). The recovery-based root method
never touches any of them (verified below).

## What the v23 installer actually does (verified from its scripts)

`cosmo-customos-installer/Cosmo_Installer_Rooted_Android.sh` does exactly two things:
```sh
dd if=$MBF/root-boot.img of=/dev/block/mmcblk0p$N bs=1m   # write Magisk boot img to chosen slot
parted /dev/block/mmcblk0 name $N ROOTED_ANDROID          # relabel that partition
```
That's it. **No NVRAM, no nvdata, no protect, no proinfo, no modem, no userdata writes.**
No SP Flash Tool, no bootloader unlock, no data wipe. `list_installers.sh` offers the
target boot slots **38, 41, 42**.

## Boot-slot map (from device recon) — pick carefully

| Slot | Label | Use? |
|---|---|---|
| p30 | `boot` (active stock Android) | leave as fallback |
| p41 | **`DEBIAN_KDE`** (your Linux install) | **DO NOT pick — would erase Linux** |
| p38 | `EMPTY_RECOVERY_BOOT_2` | recovery slot |
| **p42** | **`EMPTY_NORMAL_BOOT_4`** | **← pick this** (empty normal-boot slot) |

Installing to p42 adds a rooted-Android boot entry that shares the same /system and
/data, leaving stock boot (p30) and Debian (p41) intact — non-destructive and reversible.

## Procedure

1. Download `cosmo-customos-installer/` from `planet-community/cosmo-v23-rooted-android`.
2. Copy it to a microSD so the paths are `/sdcard/cosmo-customos-installer/$FILE`
   (`Cosmo_Installer_Rooted_Android.sh`, `list_installers.sh`, `root-boot.img`).
3. Boot to recovery: power on holding the **cover Volume-Up** (fingerprint side).
4. Hold **ESC** (top-left key) + press cover **Volume-Up**, release both → installer menu.
5. Select **"Install Rooted Android for Firmware v23"**, target slot **EMPTY_NORMAL_BOOT_4 (p42)**.
6. Boot the rooted Android; tap the **Magisk** app; approve the upgrade to finish setup.

## Immediately after root (do first)

Belt-and-suspenders insurance for all *future* flashing (mainline, experiments):
```sh
# back up IMEI/modem-critical partitions to files, then pull off-device
mkdir -p collected/nvram-backup collected/boot-backup
for p in nvram nvdata nvcfg proinfo protect1 protect2; do
  adb shell "su -c 'dd if=/dev/block/by-name/$p of=/sdcard/${p}.img'"
  adb pull /sdcard/${p}.img collected/nvram-backup/
done
# the boot chain: stock boot, its device-tree overlay, the bootloader (LK) and the
# multiboot config. The PennyOS build needs dtbo.img: tools/check-lk-dtb.py applies it
# to every DTB, as LK does, before a boot image is made.
for p in boot dtbo lk lk2 boot_para para; do
  adb shell "su -c 'dd if=/dev/block/by-name/$p of=/sdcard/${p}.img'"
  adb pull /sdcard/${p}.img collected/boot-backup/
done
for p in nvram nvdata nvcfg proinfo protect1 protect2 boot dtbo lk lk2 boot_para para; do
  adb shell "su -c 'rm /sdcard/${p}.img'"
done
shasum -a 256 collected/nvram-backup/* collected/boot-backup/* > collected/backup.sha256
```
Keep a copy of `collected/nvram-backup/` somewhere other than this computer: it is the
only way back if the IMEI or calibration is ever lost, and it is unique to the phone.
Then re-run `tools/android-recon.sh` **with root** to capture dmesg, `/proc/config.gz`,
the live device tree, clocks/regulators/gpio (the high-value pieces missing from the
unrooted dump).

## Notes
- Staying on **V23 rooted is sufficient** for all porting/RE work; no need for V25. (V25
  rooted is an upgrade that expects an already-rooted/updated setup — sidestepped here.)
- Alternative: `fastboot flash boot root-boot.img` roots the main boot directly, but
  needs bootloader unlock (wipes userdata, though not IMEI). The recovery method is
  easier and non-destructive — prefer it.

## Sources
- Repo (scripts + boot img): https://github.com/planet-community/cosmo-v23-rooted-android
- Planet rooted-Android guide: https://support.planetcom.co.uk/index.php/Rooted_Android_For_Cosmo
- IMEI-loss thread (SP Flash Tool cause; TWRP-nvram recovery): https://www.oesf.org/forum/index.php?topic=35879.150
- TWRP recovery: https://support.planetcom.co.uk/index.php/TWRP_Manual_Recovery
