#!/bin/bash
# Build niri (not packaged in Debian 13) for arm64 inside a debian:trixie container,
# so it links against exactly the libraries the phone has. Run via:
#   docker run --rm -v cosmo-niri-build:/build -v "$PWD/tools:/work/tools:ro" -v "$PWD/out:/work/out" \
#     debian:trixie bash /work/tools/rootfs/build-niri.sh <tag> [<expected commit>]
# Output: /work/out/niri/{niri,niri-session,niri.service,niri-shutdown.target,niri.desktop,niri-portals.conf,default-config.kdl}
set -euo pipefail
TAG="$1"
WANT_COMMIT="${2:-}"   # if given, the tag must resolve to exactly this commit
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl git build-essential pkg-config clang \
  libudev-dev libgbm-dev libxkbcommon-dev libegl1-mesa-dev libwayland-dev libinput-dev libdbus-1-dev \
  libsystemd-dev libseat-dev libpango1.0-dev libcairo2-dev libglib2.0-dev libdisplay-info-dev >/dev/null
export CARGO_HOME=/build/cargo RUSTUP_HOME=/build/rustup
[ -x /build/cargo/bin/cargo ] || curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable >/dev/null
. /build/cargo/env
[ -d /build/niri/.git ] || git clone -q https://github.com/YaLTeR/niri.git /build/niri
cd /build/niri
git fetch -q --tags && git checkout -q "$TAG"
GOT_COMMIT=$(git rev-parse HEAD)
if [ -n "$WANT_COMMIT" ] && [ "$GOT_COMMIT" != "$WANT_COMMIT" ]; then
  echo "niri $TAG resolves to $GOT_COMMIT, expected $WANT_COMMIT - refusing to build" >&2
  exit 1
fi
# No PipeWire screencasting for now (drops a large dependency tree); keep systemd + dbus.
cargo build --release --no-default-features --features dbus,systemd
mkdir -p /work/out/niri
cp target/release/niri resources/niri-session resources/niri.service resources/niri-shutdown.target \
   resources/niri.desktop resources/niri-portals.conf resources/default-config.kdl /work/out/niri/
strip /work/out/niri/niri
ls -la /work/out/niri
