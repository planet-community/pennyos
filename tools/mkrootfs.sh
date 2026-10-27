#!/usr/bin/env bash
# mkrootfs.sh - build a minimal Debian arm64 root filesystem image for the Cosmo.
#
# debootstraps into a Docker volume (case-sensitive, real ownership), adds our
# kernel modules (run the kernel build first), and writes out/debian-rootfs.img
# (ext4, grown to the partition size on first boot). Install it with
# tools/install-rootfs.sh. Re-running reuses the debootstrap and just reconfigures.
#
# Login: cosmo / cosmo (sudo). ~/.ssh/id_ed25519.pub is authorized if present.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
KEY="$HOME/.ssh/id_ed25519.pub"
KEYARG=()
[ -f "$KEY" ] && KEYARG=(-v "$KEY:/pubkey:ro")
docker run --privileged -v cosmo-rootfs:/vol -v "$REPO:/work" "${KEYARG[@]}" \
  cosmo-kbuild bash /work/tools/rootfs/build-in-container.sh
