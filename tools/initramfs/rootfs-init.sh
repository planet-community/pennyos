#!/bin/sh
# PENNYOS boot initramfs: mount the real root filesystem (the eMMC partition whose
# GPT name is `linux`) and hand over to its init. Falls back to the debug shell
# (/debug-init, i.e. tools/initramfs/debug-init.sh) if a key is pressed during the
# 3 s prompt, if `pennyos.debug` is on the cmdline, or if the root cannot be mounted.
BB=/bin/busybox
$BB mount -t proc     proc     /proc 2>/dev/null
$BB mount -t sysfs    sysfs    /sys  2>/dev/null
$BB mount -t devtmpfs devtmpfs /dev  2>/dev/null

say() { echo "pennyos: $1" > /dev/kmsg 2>/dev/null; }
debug() {
  say "$1 -> debug shell"
  $BB umount /dev /sys /proc 2>/dev/null
  exec /debug-init
}

$BB grep -q pennyos.debug /proc/cmdline && debug "pennyos.debug on cmdline"

echo "pennyos: press any key within 3s for the debug shell..." > /dev/console
if read -t 3 -n 1 key < /dev/console 2>/dev/null; then debug "key pressed"; fi

# Only the internal eMMC (mmc0 by DT alias, so always mmcblk0) may provide the root:
# otherwise an SD card carrying a partition named `linux` would hijack the boot.
# `pennyos.anyroot` lifts that, for emulators and deliberate external boots.
ROOTGLOB='/sys/class/block/mmcblk0p*/uevent'
$BB grep -q pennyos.anyroot /proc/cmdline && ROOTGLOB='/sys/class/block/*/uevent'
ROOTDEV=
i=0
while [ -z "$ROOTDEV" ] && [ "$i" -lt 50 ]; do
  for u in $ROOTGLOB; do
    [ -f "$u" ] || continue
    if $BB grep -q '^PARTNAME=linux$' "$u"; then
      ROOTDEV=/dev/$($BB basename "$($BB dirname "$u")")
    fi
  done
  [ -n "$ROOTDEV" ] || { $BB sleep 0.2; i=$((i+1)); }
done
[ -n "$ROOTDEV" ] || debug "no partition named linux"

$BB mkdir -p /sysroot
$BB mount -t ext4 -o rw,noatime "$ROOTDEV" /sysroot || debug "cannot mount $ROOTDEV"
[ -x /sysroot/sbin/init ] || [ -L /sysroot/sbin/init ] || { $BB umount /sysroot; debug "no /sbin/init on $ROOTDEV"; }

say "switching root to $ROOTDEV"
$BB mount --move /dev  /sysroot/dev
$BB mount --move /sys  /sysroot/sys
$BB mount --move /proc /sysroot/proc
exec $BB switch_root /sysroot /sbin/init
