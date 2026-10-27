#!/bin/sh
# Write out/debian-rootfs.img to the internal `linux` partition (mmcblk0p43, 56 GB)
# over adb from rooted Android, and verify it.
#
# THIS ERASES WHATEVER IS ON THE `linux` PARTITION (the old Gemian/Debian 10 install).
# Nothing else is written: Android, its userdata, the boot slots and NVRAM are untouched.
#
# Usage: tools/install-rootfs.sh [out/debian-rootfs.img]
set -e
IMG="${1:-out/debian-rootfs.img}"
PART=/dev/block/by-name/linux
ADB="${ADB:-adb}"
[ -f "$IMG" ] || { echo "no such image: $IMG (run tools/mkrootfs.sh)"; exit 1; }
SIZE=$(wc -c < "$IMG" | tr -d ' ')
WANT=$(shasum -a 256 "$IMG" | cut -d' ' -f1)

"$ADB" get-state >/dev/null
"$ADB" shell "su -c 'ls -l $PART'"
printf 'About to ERASE the linux partition and write %s (%s MiB). Type yes to continue: ' "$IMG" "$((SIZE / 1048576))"
read ans
[ "$ans" = "yes" ] || { echo "aborted"; exit 1; }

"$ADB" push "$IMG" /sdcard/pennyos-rootfs.img
"$ADB" shell "su -c 'dd if=/sdcard/pennyos-rootfs.img of=$PART bs=1048576 && sync'"
# read back with dd: Android's `head -c` fails on an image over 2 GiB (the image is
# a whole number of MiB, mkrootfs.sh makes it so)
GOT=$("$ADB" shell "su -c 'dd if=$PART bs=1048576 count=$((SIZE / 1048576)) 2>/dev/null | sha256sum'" | cut -d' ' -f1)
"$ADB" shell "su -c 'rm /sdcard/pennyos-rootfs.img'"
echo "want $WANT"
echo "got  $GOT"
[ "$WANT" = "$GOT" ] && echo "OK: Debian is on the linux partition" || { echo "MISMATCH"; exit 1; }
