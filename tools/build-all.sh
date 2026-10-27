#!/usr/bin/env bash
# build-all.sh - build everything this repo produces for the Planet Cosmo Communicator,
# from a clean checkout, in dependency order:
#
#   boot/boot-mainline.img      mainline kernel + DTB + initramfs  (tools/flash-slot.sh)
#   out/debian-rootfs.img       Debian 13 + niri desktop + Wi-Fi   (tools/install-rootfs.sh)
#
# Needs Docker, ~15 GB of disk, and (on the host) dtc/fdtoverlay for the LK check
# (`brew install dtc`). Takes 30-60 minutes the first time.
#
# Before running, once per phone (see README "Build and install"):
#   - clone the kernel:   git clone --depth 1 -b mt6771 https://github.com/affenull2345/linux.git kernel/linux-mt6771
#   - back up the phone's boot partitions into collected/boot-backup/ (research/rooting.md;
#     the LK check needs the phone's own dtbo there)
#   - tools/android-recon.sh         (the vendor live device tree, for the same check)
#   - tools/collect-radio-blobs.sh   (radio firmware + this phone's Wi-Fi calibration)
set -euo pipefail
cd "$(dirname "$0")/.."
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

step "kernel: toolchain image + source"
./tools/kbuild.sh image >/dev/null
./tools/kbuild.sh src
step "kernel: our patches, drivers and device tree"
./tools/kbuild.sh patch
./tools/kbuild.sh drivers-sync
./tools/kbuild.sh dts-sync
step "kernel: configure and build (Image, DTB, modules)"
./tools/kbuild.sh config slim debug rootfs | tail -3
./tools/kbuild.sh modules
step "radio: vendor connectivity stack (Wi-Fi/BT control layer)"
./tools/conn-setup.sh
step "desktop: niri"
# Pinned: third-party source is built at a known tag AND commit (bump both together
# after reviewing the release). The build container gets the repo read-only and can
# only write to out/.
NIRI_TAG=v26.04
NIRI_COMMIT=8ed0da44d974c32c6877d2f4630c314da0717ecb
if [ ! -x out/niri/niri ] || [ "$(cat out/niri/TAG 2>/dev/null)" != "$NIRI_TAG" ]; then
  mkdir -p out/niri
  docker volume create cosmo-niri-build >/dev/null
  docker run --rm -v cosmo-niri-build:/build -v "$PWD/tools:/work/tools:ro" -v "$PWD/out:/work/out" \
    debian:trixie bash /work/tools/rootfs/build-niri.sh "$NIRI_TAG" "$NIRI_COMMIT" | tail -3
  echo "$NIRI_TAG" > out/niri/TAG
else
  echo "out/niri already built ($NIRI_TAG)"
fi
step "voice typing: whisper.cpp and its model"
# Pinned like niri: tag AND commit for the source, checksum for the model.
WHISPER_TAG=v1.9.5
WHISPER_COMMIT=d1be6fde11ac6e0407606b4e42fe72d34add8037
WHISPER_MODEL=ggml-tiny.en.bin
WHISPER_MODEL_SHA256=921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f
if [ ! -x out/whisper/whisper-cli ] || [ "$(cat out/whisper/TAG 2>/dev/null)" != "$WHISPER_TAG" ]; then
  mkdir -p out/whisper
  docker volume create cosmo-whisper-build >/dev/null
  docker run --rm -v cosmo-whisper-build:/build -v "$PWD/tools:/work/tools:ro" -v "$PWD/out:/work/out" \
    debian:trixie bash /work/tools/rootfs/build-whisper.sh "$WHISPER_TAG" "$WHISPER_COMMIT" | tail -3
  echo "$WHISPER_TAG" > out/whisper/TAG
else
  echo "out/whisper already built ($WHISPER_TAG)"
fi
if [ "$(shasum -a 256 "out/whisper/$WHISPER_MODEL" 2>/dev/null | cut -d' ' -f1)" != "$WHISPER_MODEL_SHA256" ]; then
  curl -fL -o "out/whisper/$WHISPER_MODEL" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$WHISPER_MODEL"
  [ "$(shasum -a 256 "out/whisper/$WHISPER_MODEL" | cut -d' ' -f1)" = "$WHISPER_MODEL_SHA256" ] || { echo "model checksum mismatch"; exit 1; }
fi
step "desktop: start-up animation"
./tools/splash/build.sh
step "boot image"
./tools/mkboot.sh rootfs
step "Debian root filesystem image"
./tools/mkrootfs.sh | grep -E "^==>|^    |rootfs.img|WARNING"
step "done"
ls -la boot/boot-mainline.img out/debian-rootfs.img
echo "Install: boot Rooted Android, then tools/install-rootfs.sh and tools/flash-slot.sh"
