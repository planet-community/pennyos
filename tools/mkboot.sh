#!/usr/bin/env bash
#
# mkboot.sh — package the mainline kernel into a flashable Cosmo boot image.
#
# Replicates the EXACT format of the known-good `root-boot.img` (Android boot
# image header v1, appended-DTB kernel, page size 2048, same load offsets and
# cmdline, NO AVB footer — the device boots alternate slots unsigned in the
# unlocked/orange state). Produces boot/boot-mainline.img.
#
# The kernel is `Image.gz` with the Cosmo DTB concatenated (Image.gz-dtb), which
# is how MediaTek LK on this device consumes the device tree.
#
# The ramdisk is a minimal bring-up initramfs (static PID1 from
# tools/initramfs/init.c) that proves the kernel reaches userspace over serial.
# Swap it for a real distro initramfs once boot is confirmed.
#
# Usage:  ./tools/mkboot.sh [debug|rootfs]   # needs boot/Image.gz + boot/*.dtb (run kbuild.sh kernel first)
#
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE=cosmo-kbuild
VOL="${COSMO_KSRC_VOL:-cosmo-kernel-src}"

[ -f "$REPO/boot/Image.gz" ] || { echo "missing boot/Image.gz — run ./tools/kbuild.sh kernel"; exit 1; }
[ -f "$REPO/boot/mt6771-planet-cosmocom.dtb" ] || { echo "missing DTB — run ./tools/kbuild.sh dtb"; exit 1; }

# Boot header params extracted from the working root-boot.img (see research/rooting.md):
#   header v1, pagesize 2048, kernel@0x40080000 ramdisk@0x55000000 tags@0x54000000
#   second@0x40f00000, os 9.0.0 / patch 2020-04. Using base 0x40078000 + offsets.
# LK asserts unless tags==0x54000000, ramdisk==0x55000000 and ramdisk <= 16 MiB.
#
# LK builds the kernel cmdline as:
#   <bootargs of the STOCK boot partition's DTB> + <this string> + <LK's own args>
# (it latches bootargs from the first DTB it loads, before the boot menu, and never
# re-reads ours). So we inherit "console=tty0 console=ttyS0,921600n1 vmalloc=496M
# slub_max_order=0 slub_debug=OFZPU ..." and must put everything we need here:
#  - bootopt=: parsed by LK itself to pick a 64-bit kernel
#  - tty0 last so /dev/console (init output) lands on the panel
#  - no clk_ignore_unused / pd_ignore_unused any more: the display driver is built in
#    and owns its clocks, so the kernel may gate everything nobody uses
#  - slub_debug=-: undo the vendor's (slow) slab debugging
#  - panic=10: never sit dead forever (the watchdog is fed by the kernel until
#    userspace opens it: the debug init or systemd)
CMDLINE='bootopt=64S3,32N2,64N2 earlycon console=ttyGS0,115200 console=tty0 fbcon=rotate:3 slub_debug=- panic=10 ignore_loglevel mem_sleep_default=s2idle'

# LK force-applies the vendor dtbo to our DTB and asserts/hangs on several DT
# conditions (research/lk-dtb-requirements.md). Refuse to package a DTB it would reject.
echo "==> checking the DTB against LK's requirements"
python3 "$REPO/tools/check-lk-dtb.py" "$REPO/boot/mt6771-planet-cosmocom.dtb"

# Which /init the initramfs runs: the busybox debug shell (default), or the one
# that mounts the `linux` partition and boots the distro on it (debug shell stays
# available as a fallback inside it).
case "${1:-debug}" in
  debug)  INIT=debug-init.sh ;;
  rootfs) INIT=rootfs-init.sh ;;
  *) echo "usage: $0 [debug|rootfs]"; exit 1 ;;
esac
# The installed system keeps the screen free of kernel and systemd messages (they
# are all still in dmesg and the journal): no text between the login screen and the
# desktop, and no blinking console cursor. The debug image keeps every message.
if [ "$INIT" = rootfs-init.sh ]; then
  CMDLINE=$(echo "$CMDLINE" | sed 's/ ignore_loglevel/ quiet loglevel=1 vt.global_cursor_default=0/')
fi

# Both inits are busybox shell scripts. Static arm64 busybox from Debian 12
# (busybox-static 1.35.0), fetched once; not in git.
BUSYBOX="$REPO/tools/initramfs/busybox-arm64"
if [ ! -f "$BUSYBOX" ]; then
  echo "==> fetching static arm64 busybox (Debian 12 busybox-static)"
  docker run --rm -v "$REPO/tools/initramfs:/out" debian:bookworm sh -euc '
    dpkg --add-architecture arm64 && apt-get update -qq
    cd /tmp && apt-get download -qq busybox-static:arm64
    dpkg-deb -x busybox-static_*_arm64.deb x && cp x/bin/busybox /out/busybox-arm64'
fi

docker run --rm -e INIT="$INIT" -v "$VOL:/src" -v "$REPO:/work" -w /work "$IMAGE" bash -euo pipefail -c '
  mkdir -p build

  echo "==> cross-compiling minimal init (static)"
  aarch64-linux-gnu-gcc -static -Os -o build/init tools/initramfs/init.c
  aarch64-linux-gnu-strip build/init

  echo "==> building initramfs (gen_init_cpio with a /dev/console node)"
  cc -O2 -o build/gen_init_cpio /src/usr/gen_init_cpio.c
  if [ -f tools/initramfs/busybox-arm64 ]; then
    echo "    using the busybox debug initramfs (tools/initramfs/debug-init.sh)"
    cat > build/initramfs.list <<EOF
dir /dev 0755 0 0
nod /dev/console 0600 0 0 c 5 1
dir /proc 0755 0 0
dir /sys 0755 0 0
dir /bin 0755 0 0
file /bin/busybox /work/tools/initramfs/busybox-arm64 0755 0 0
slink /bin/sh busybox 0777 0 0
file /debug-init /work/tools/initramfs/debug-init.sh 0755 0 0
file /init /work/tools/initramfs/$INIT 0755 0 0
EOF
  else
    cat > build/initramfs.list <<EOF
dir /dev 0755 0 0
nod /dev/console 0600 0 0 c 5 1
dir /proc 0755 0 0
dir /sys 0755 0 0
file /init /work/build/init 0755 0 0
EOF
  fi
  build/gen_init_cpio build/initramfs.list | gzip -9 > build/initramfs.cpio.gz

  echo "==> assembling Image.gz-dtb (kernel + appended DTB)"
  cat boot/Image.gz boot/mt6771-planet-cosmocom.dtb > build/Image.gz-dtb

  echo "==> mkbootimg (header v1, Cosmo offsets)"
  python3 tools/kbuild/mkbootimg.py \
    --header_version 1 \
    --kernel build/Image.gz-dtb \
    --ramdisk build/initramfs.cpio.gz \
    --base 0x40078000 \
    --kernel_offset 0x00008000 \
    --ramdisk_offset 0x14f88000 \
    --second_offset 0x00e88000 \
    --tags_offset 0x13f88000 \
    --pagesize 2048 \
    --os_version 9.0.0 \
    --os_patch_level 2020-04 \
    --cmdline "'"$CMDLINE"'" \
    --output boot/boot-mainline.img

  echo "==> verifying by unpacking"
  python3 tools/kbuild/unpack_bootimg.py --boot_img boot/boot-mainline.img --out build/verify | \
    grep -E "header version|page size|load address|command line|os version"
  echo "==> done: boot/boot-mainline.img ($(stat -c %s boot/boot-mainline.img) bytes)"
'
