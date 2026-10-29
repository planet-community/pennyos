#!/bin/bash
# Build fuzzel (the app launcher and every PennyOS menu) for arm64 inside a debian:trixie
# container. Debian 13 has fuzzel 1.12, which ignores the touchscreen; touch came in
# 1.13, and 1.14 fixed touch positions on a scaled display. Run via:
#   docker run --rm -v cosmo-fuzzel-build:/build -v "$PWD/tools:/work/tools:ro" -v "$PWD/out:/work/out" \
#     debian:trixie bash /work/tools/rootfs/build-fuzzel.sh <tag> <commit>
# Output: /work/out/fuzzel/fuzzel, installed as /usr/local/bin/fuzzel, ahead of
# Debian's /usr/bin/fuzzel in PATH (the package stays, for its dependencies).
#
# fuzzel >= 1.13 needs pixman 0.46 (its 16-bit pixel format); Debian 13 has 0.44.
# pixman 0.46 and fcft are therefore built in statically: fcft hands fuzzel pixman
# images, so the two must share one pixman, and the system one is never loaded.
set -euo pipefail
TAG="$1"
WANT_COMMIT="$2"
# fuzzel's own wrap files follow the dependencies' master branches; pin them instead
# (tag and commit, bumped together after reviewing the release)
PIXMAN_TAG=pixman-0.46.4 PIXMAN_COMMIT=9cc163c9da0fb4da430641715313d95a6ec466d9
FCFT_TAG=3.3.3 FCFT_COMMIT=38de2ae450df667ac71ba4811fe535aa1954a217
TLLIST_TAG=1.1.0 TLLIST_COMMIT=8dcb0725c73eee9e350f41a921faf0bcd2ab9920
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates git build-essential meson ninja-build \
  pkg-config scdoc libfontconfig-dev libfreetype-dev libharfbuzz-dev libutf8proc-dev libwayland-dev \
  wayland-protocols libxkbcommon-dev libpng-dev >/dev/null

# fetch REPO DIR TAG COMMIT: a checkout of exactly that commit, or a refusal
fetch() {
  [ -d "$2/.git" ] || git clone -q "$1" "$2"
  git -C "$2" fetch -q --tags
  git -C "$2" -c advice.detachedHead=false checkout -q "$3"
  local got
  got=$(git -C "$2" rev-parse HEAD)
  if [ "$got" != "$4" ]; then
    echo "$(basename "$2") $3 resolves to $got, expected $4 - refusing to build" >&2
    exit 1
  fi
}
fetch https://codeberg.org/dnkl/fuzzel.git /build/fuzzel "$TAG" "$WANT_COMMIT"
cd /build/fuzzel
fetch https://gitlab.freedesktop.org/pixman/pixman.git subprojects/pixman "$PIXMAN_TAG" "$PIXMAN_COMMIT"
fetch https://codeberg.org/dnkl/fcft.git subprojects/fcft "$FCFT_TAG" "$FCFT_COMMIT"
fetch https://codeberg.org/dnkl/tllist.git subprojects/tllist "$TLLIST_TAG" "$TLLIST_COMMIT"
# fuzzel and fcft ask for pixman-1 without naming a fallback: tell meson which
# subproject provides it (the checkout above; nothing is downloaded)
printf '[wrap-git]\ndirectory = pixman\nurl = https://gitlab.freedesktop.org/pixman/pixman.git\nrevision = %s\n\n[provide]\npixman-1 = idep_pixman\n' \
  "$PIXMAN_COMMIT" > subprojects/pixman.wrap

rm -rf build
# fuzzel builds with -Werror, which reaches its subprojects; pixman warns about an
# x86-only attribute on arm64
meson setup build --buildtype=release --wrap-mode=nodownload \
  --force-fallback-for=pixman-1,fcft,tllist -Ddefault_library=static \
  -Dpixman:tests=disabled -Dpixman:demos=disabled -Dpixman:gtk=disabled -Dpixman:libpng=disabled \
  -Dpixman:openmp=disabled -Dpixman:werror=false -Dfcft:docs=disabled -Dfcft:grapheme-shaping=enabled -Dfcft:run-shaping=enabled \
  >/dev/null
ninja -C build fuzzel >/dev/null
# the point of the exercise: no second pixman (or fcft) at run time
if ldd build/fuzzel | grep -E "libpixman|libfcft"; then
  echo "fuzzel still links a shared pixman/fcft - refusing" >&2
  exit 1
fi
mkdir -p /work/out/fuzzel
install -m 755 build/fuzzel /work/out/fuzzel/fuzzel
strip /work/out/fuzzel/fuzzel
/work/out/fuzzel/fuzzel --version
ls -la /work/out/fuzzel
