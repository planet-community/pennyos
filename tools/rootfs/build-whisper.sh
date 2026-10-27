#!/bin/bash
# Build whisper.cpp (speech recognition for voice typing, not packaged in Debian 13)
# for arm64 inside a debian:trixie container. Run via:
#   docker run --rm -v cosmo-whisper-build:/build -v "$PWD/tools:/work/tools:ro" -v "$PWD/out:/work/out" \
#     debian:trixie bash /work/tools/rootfs/build-whisper.sh <tag> [<expected commit>]
# Output: /work/out/whisper/whisper-cli (one self-contained binary)
set -euo pipefail
TAG="$1"
WANT_COMMIT="${2:-}"   # if given, the tag must resolve to exactly this commit
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates git build-essential cmake >/dev/null
[ -d /build/whisper.cpp/.git ] || git clone -q https://github.com/ggml-org/whisper.cpp.git /build/whisper.cpp
cd /build/whisper.cpp
git fetch -q --tags && git checkout -q "$TAG"
GOT_COMMIT=$(git rev-parse HEAD)
if [ -n "$WANT_COMMIT" ] && [ "$GOT_COMMIT" != "$WANT_COMMIT" ]; then
  echo "whisper.cpp $TAG resolves to $GOT_COMMIT, expected $WANT_COMMIT - refusing to build" >&2
  exit 1
fi
# The build machine's CPU is not the phone's: no -mcpu=native. The MT6771 is
# Cortex-A73 + A53 (ARMv8.0: NEON, no dot-product, no fp16).
cmake -S . -B /build/out -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
  -DCMAKE_C_FLAGS="-mcpu=cortex-a73" -DCMAKE_CXX_FLAGS="-mcpu=cortex-a73" >/dev/null
cmake --build /build/out --target whisper-cli -j"$(nproc)" | tail -2
mkdir -p /work/out/whisper
cp /build/out/bin/whisper-cli /work/out/whisper/
strip /work/out/whisper/whisper-cli
echo "$GOT_COMMIT" > /work/out/whisper/COMMIT
ls -la /work/out/whisper
