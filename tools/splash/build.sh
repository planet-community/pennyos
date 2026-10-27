#!/bin/sh
# Build penny-splash (arm64) into out/splash/, and render its frames for a preview.
# Runs the compiler in a Debian trixie container; on an arm64 Mac that is native.
#   tools/splash/build.sh            -> out/splash/penny-splash
#   tools/splash/build.sh preview    + out/splash/preview.gif (needs Pillow on the host)
set -e
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$REPO/out/splash"
docker run --rm --platform linux/arm64 -v "$REPO/tools/splash:/src:ro" -v "$REPO/out/splash:/out" \
  -e PREVIEW="${1:-}" debian:trixie sh -euc '
  apt-get update -qq >/dev/null
  apt-get install -y -qq --no-install-recommends gcc libc6-dev pkg-config libgtk-3-dev \
    libgtk-layer-shell-dev fonts-inter-variable >/dev/null 2>&1
  gcc -O2 -Wall -Wextra -o /out/penny-splash /src/penny-splash.c \
    $(pkg-config --cflags --libs gtk+-3.0 gtk-layer-shell-0) -lm
  strip /out/penny-splash
  if [ -n "$PREVIEW" ]; then
    rm -rf /out/frames && mkdir /out/frames
    /out/penny-splash --render /out/frames 1234 617 30
  fi'
ls -la "$REPO/out/splash/penny-splash"
if [ "${1:-}" = preview ]; then
  python3 - "$REPO/out/splash" <<'PY'
import glob, sys
from PIL import Image
d = sys.argv[1]
frames = [Image.open(f).convert("RGB") for f in sorted(glob.glob(d + "/frames/frame*.png"))]
frames[0].save(d + "/preview.gif", save_all=True, append_images=frames[1:], duration=33, loop=0)
print("preview:", d + "/preview.gif", len(frames), "frames")
PY
fi
