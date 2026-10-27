#!/usr/bin/env bash
# conn-setup.sh - (re)create and build the vendor connectivity stack (Wi-Fi/BT control
# layer, kernel/connectivity/README.md) for the kernel in the cosmo-kernel-src volume.
#
# Fetches MediaTek's vendor sources at the pinned commit into the Docker volume
# `cosmo-conn`, applies kernel/connectivity/pennyos-conn.patch, builds the six
# modules and our daemon, and exports them to out/conn-mods/ and out/penny-wmtd.
# Run the kernel build first (the modules are built against that tree).
#
# Usage: tools/conn-setup.sh            # set up if needed, then build + export
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_REPO=https://github.com/planet-community/android_kernel_planetcom_mt6771.git
VENDOR_COMMIT=5ba79b000e56509dae238a647114ebbe1e32e3a2

docker volume create cosmo-conn >/dev/null
docker volume create cosmo-vendor-src >/dev/null
docker run --rm -e VENDOR_REPO="$VENDOR_REPO" -e VENDOR_COMMIT="$VENDOR_COMMIT" \
  -v cosmo-vendor-src:/v -v cosmo-conn:/c -v "$REPO:/work:ro" cosmo-kbuild \
  bash /work/tools/rootfs/conn-import.sh
mkdir -p "$REPO/out/conn-mods"
docker run --rm -v cosmo-kernel-src:/src:ro -v cosmo-conn:/c -v "$REPO:/work" cosmo-kbuild bash -c '
  set -e
  bash /c/conn/build.sh | tail -12
  cd /c/conn
  for f in compat/pennyos_shim.ko btif/common/btif.ko connectivity/common/wmt_drv.ko \
           connectivity/bt/mt66xx/bt_drv.ko connectivity/wlan/adaptor/wmt_chrdev_wifi.ko \
           connectivity/wlan/core/gen3/wlan_drv_gen3.ko; do cp $f /work/out/conn-mods/; done
  aarch64-linux-gnu-strip --strip-debug /work/out/conn-mods/*.ko
  aarch64-linux-gnu-gcc -O2 -Wall -o /work/out/penny-wmtd /work/tools/wmt/penny-wmtd.c
  aarch64-linux-gnu-gcc -O2 -Wall -Wextra -o /work/out/penny-btd /work/tools/wmt/penny-btd.c
  ls -la /work/out/conn-mods /work/out/penny-wmtd'
