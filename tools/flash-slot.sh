#!/bin/sh
# Flash a boot image to the repurposed DEBIAN_KDE multiboot slot (mmcblk0p41) over adb
# from rooted Android, and verify it byte-for-byte. Touches nothing else: stock `boot`,
# ROOTED_ANDROID, boot_para and NVRAM are never written.
#
# Usage: tools/flash-slot.sh [boot/boot-mainline.img]
set -e
IMG="${1:-boot/boot-mainline.img}"
SLOT=/dev/block/by-name/DEBIAN_KDE
ADB="${ADB:-adb}"
[ -f "$IMG" ] || { echo "no such image: $IMG"; exit 1; }
SIZE=$(wc -c < "$IMG" | tr -d ' ')
[ "$SIZE" -le 33554432 ] || { echo "image is larger than the 32 MiB slot"; exit 1; }
WANT=$(shasum -a 256 "$IMG" | cut -d' ' -f1)

"$ADB" get-state >/dev/null
"$ADB" shell "su -c 'ls -l $SLOT'"
"$ADB" push "$IMG" /sdcard/pennyos-boot.img
# toybox dd needs a NUMERIC bs (bs=1M fails)
"$ADB" shell "su -c 'dd if=/sdcard/pennyos-boot.img of=$SLOT bs=1048576 && sync'"
# clear the debug initramfs's log records (24..28 MiB, see tools/read-slotlog.sh) so
# a later read never shows a previous image's logs
"$ADB" shell "su -c 'dd if=/dev/zero of=$SLOT bs=1048576 seek=24 count=4 2>/dev/null && sync'"
GOT=$("$ADB" shell "su -c 'head -c $SIZE $SLOT | sha256sum'" | cut -d' ' -f1)
echo "want $WANT"
echo "got  $GOT"
[ "$WANT" = "$GOT" ] && echo "OK: $IMG is on DEBIAN_KDE" || { echo "MISMATCH - do not boot this slot"; exit 1; }
