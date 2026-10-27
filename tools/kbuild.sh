#!/usr/bin/env bash
#
# kbuild.sh — containerized kernel dev loop for the Cosmo (arm64 / MT6771).
#
# The macOS host filesystem is case-insensitive, which corrupts case-colliding
# kernel source files. So the kernel tree lives in a case-sensitive Docker volume
# and all builds run inside a Linux container. Source is cloned from the host's
# intact .git (no re-download).
#
# Usage:
#   ./tools/kbuild.sh image                 # build the toolchain image (first run)
#   ./tools/kbuild.sh src                    # clone kernel source into the volume
#   ./tools/kbuild.sh make <targets...>      # run make (ARCH/CROSS preset)
#   ./tools/kbuild.sh config [frag...]       # defconfig + kernel/cosmocom.config (+ kernel/<frag>.config) -> .config
#   ./tools/kbuild.sh patch                  # apply kernel/patches/*.patch to the tree in the volume
#   ./tools/kbuild.sh drivers-sync           # install kernel/drivers/* into the tree and hook them into Kbuild
#   ./tools/kbuild.sh dts-sync               # install devicetree/*.dtsi into the tree + hook them into the board DTS
#   ./tools/kbuild.sh kernel                  # build + export Image.gz (+DTB) to boot/
#   ./tools/kbuild.sh modules                 # build Image + DTB + all modules; modules -> rootfs volume
#   ./tools/kbuild.sh dtb                     # build + export the Cosmo DTB to boot/
#   ./tools/kbuild.sh defconfig               # arm64 defconfig (baseline)
#   ./tools/kbuild.sh shell                   # interactive shell in the build env
#   ./tools/kbuild.sh clean-src               # delete the source volume
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE=cosmo-kbuild
VOL="${COSMO_KSRC_VOL:-cosmo-kernel-src}"   # override to build in a scratch volume
ROOTFS_VOL="${COSMO_ROOTFS_VOL:-cosmo-rootfs}"
HOST_KERNEL="$REPO/kernel/linux-mt6771"
DTB_REL=arch/arm64/boot/dts/mediatek/mt6771-planet-cosmocom.dtb

in_container() {
  docker run --rm -it \
    -v "$VOL:/src" -v "$REPO:/work" \
    -w /src "$IMAGE" "$@"
}
in_container_q() {  # non-interactive
  docker run --rm \
    -v "$VOL:/src" -v "$REPO:/work" \
    -w /src "$IMAGE" "$@"
}

cmd="${1:-help}"; shift || true

case "$cmd" in
  image)
    docker build -t "$IMAGE" "$REPO/tools/kbuild"
    ;;

  src)
    docker volume create "$VOL" >/dev/null
    if [ ! -d "$HOST_KERNEL/.git" ]; then
      echo "ERROR: $HOST_KERNEL/.git not found. Clone it first:" >&2
      echo "  git clone --depth 1 --single-branch -b mt6771 https://github.com/affenull2345/linux.git $HOST_KERNEL" >&2
      exit 1
    fi
    echo "==> Cloning kernel source from host .git into volume '$VOL' (case-sensitive)..."
    in_container_q bash -c '
      if [ -d /src/.git ]; then echo "source already present; pulling"; cd /src && git pull --ff-only || true;
      else git clone /work/kernel/linux-mt6771/.git /src && echo "cloned"; fi
      cd /src && git log -1 --oneline'
    ;;

  defconfig)
    in_container_q make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
    ;;

  config)
    # arm64 defconfig + Cosmo fragment (kernel/cosmocom.config), then olddefconfig.
    # Prints which requested symbols actually stuck (deps satisfied).
    docker run --rm -e FRAGS="$*" -v "$VOL:/src" -v "$REPO:/work" -w /src "$IMAGE" bash -c '
      set -e
      make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
      ./scripts/kconfig/merge_config.sh -m .config /work/kernel/cosmocom.config
      for f in $FRAGS; do ./scripts/kconfig/merge_config.sh -m .config /work/kernel/$f.config; done
      make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
      echo "=== requested Cosmo symbols in final .config ==="
      for s in KEYBOARD_GPIO_FASTMATRIX PINCTRL_AW9523 DRM_MEDIATEK DRM_PANEL_SIMPLE \
               DRM_PANFROST MFD_MT6370 REGULATOR_MT6370 CHARGER_MT6370 BACKLIGHT_MT6370 \
               MEDIATEK_MT6370_ADC TYPEC_TCPM TYPEC_TCPCI TYPEC_TCPCI_MT6370; do
        v=$(grep -E "^CONFIG_$s=" .config || echo "CONFIG_$s=(dropped)")
        echo "  $v"
      done'
    ;;

  kernel)
    # build the arm64 kernel Image.gz. Assumes ./tools/kbuild.sh config was run.
    in_container_q bash -c '
      set -e
      [ -f /src/.config ] || { echo "no .config — run: ./tools/kbuild.sh config"; exit 1; }
      make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" Image.gz mediatek/mt6771-planet-cosmocom.dtb
      mkdir -p /work/boot
      cp /src/arch/arm64/boot/Image.gz /work/boot/
      cp /src/'"$DTB_REL"' /work/boot/
      echo "exported: boot/Image.gz ($(stat -c %s /src/arch/arm64/boot/Image.gz) bytes) + DTB"'
    ;;

  patch)
    # apply kernel/patches/*.patch to the tree in the volume (skips ones already applied)
    in_container_q bash -c '
      set -e
      # devicetree/*.patch are edits to the upstream board DTS itself (the rest of our
      # DT lives in devicetree/*.dtsi, hooked in by dts-sync)
      for p in /work/devicetree/*.patch /work/kernel/patches/*.patch; do
        if git apply -R --check "$p" 2>/dev/null; then echo "already applied: $(basename $p)";
        else git apply "$p" && echo "applied: $(basename $p)"; fi
      done'
    ;;

  drivers-sync)
    # out-of-tree drivers kept in kernel/drivers/ -> into the tree, hooked into Kbuild once
    in_container_q bash -c '
      set -e
      # battery current reader (MT6358 fuel gauge)
      p=drivers/power/supply
      cp /work/kernel/drivers/cosmo_fg.c $p/cosmo_fg.c
      grep -q BATTERY_COSMO_FG $p/Makefile || echo "obj-\$(CONFIG_BATTERY_COSMO_FG)	+= cosmo_fg.o" >> $p/Makefile
      if ! grep -q BATTERY_COSMO_FG $p/Kconfig; then
        python3 - $p/Kconfig <<PY
import sys
p=sys.argv[1]; s=open(p).read(); i=s.rstrip().rfind("endif")
s=s[:i]+"config BATTERY_COSMO_FG\\n\\ttristate \\"MT6358 fuel-gauge current reader (Planet Cosmo)\\"\\n\\tdepends on MFD_MT6397\\n\\thelp\\n\\t  Instantaneous battery current from the MT6358 FGADC.\\n\\n"+s[i:]
open(p,"w").write(s)
PY
      fi
      # main panel with its own reset/init sequence
      g=drivers/gpu/drm/panel
      cp /work/kernel/drivers/panel-planet-ssd2092.c $g/panel-planet-ssd2092.c
      grep -q DRM_PANEL_PLANET_SSD2092 $g/Makefile || echo "obj-\$(CONFIG_DRM_PANEL_PLANET_SSD2092) += panel-planet-ssd2092.o" >> $g/Makefile
      if ! grep -q DRM_PANEL_PLANET_SSD2092 $g/Kconfig; then
        python3 - $g/Kconfig <<PY
import sys
p=sys.argv[1]; s=open(p).read(); i=s.rstrip().rfind("endmenu")
s=s[:i]+"config DRM_PANEL_PLANET_SSD2092\\n\\ttristate \\"Planet Cosmo SSD2092 DSI panel\\"\\n\\tdepends on OF && DRM_MIPI_DSI\\n\\tdepends on BACKLIGHT_CLASS_DEVICE\\n\\thelp\\n\\t  Main display of the Planet Cosmo Communicator (Solomon SSD2092).\\n\\n"+s[i:]
open(p,"w").write(s)
PY
      fi
      # sound card (SoC audio front end + MT6358 codec)
      a=sound/soc/mediatek
      cp /work/kernel/drivers/cosmo-sound.c $a/mt8183/cosmo-sound.c
      grep -q SND_SOC_COSMO $a/mt8183/Makefile || echo "obj-\$(CONFIG_SND_SOC_COSMO) += cosmo-sound.o" >> $a/mt8183/Makefile
      if ! grep -q SND_SOC_COSMO $a/Kconfig; then
        python3 - $a/Kconfig <<PY
import sys
p=sys.argv[1]; s=open(p).read(); i=s.find("config SND_SOC_MT8183_MT6358_TS3A227E_MAX98357A")
s=s[:i]+"config SND_SOC_COSMO\\n\\ttristate \\"Planet Cosmo sound card (MT6771 AFE + MT6358)\\"\\n\\tdepends on SND_SOC_MT8183\\n\\tselect SND_SOC_MT6358\\n\\thelp\\n\\t  Sound card of the Planet Cosmo Communicator.\\n\\n"+s[i:]
open(p,"w").write(s)
PY
      fi
      t=drivers/input/touchscreen
      cp /work/kernel/drivers/ssd20xx.c $t/ssd20xx.c
      grep -q TOUCHSCREEN_SSD20XX $t/Makefile || echo "obj-\$(CONFIG_TOUCHSCREEN_SSD20XX)	+= ssd20xx.o" >> $t/Makefile
      if ! grep -q TOUCHSCREEN_SSD20XX $t/Kconfig; then
        # insert just before the final "endif" of the touchscreen menu
        python3 - $t/Kconfig <<PY
import sys
p=sys.argv[1]; s=open(p).read(); i=s.rstrip().rfind("endif")
s=s[:i]+"config TOUCHSCREEN_SSD20XX\\n\\ttristate \\"Solomon SSD20xx TDDI touchscreen (Planet Cosmo)\\"\\n\\tdepends on I2C\\n\\thelp\\n\\t  Touch half of the Solomon SSD2092/SSD2098 TDDI.\\n\\n"+s[i:]
open(p,"w").write(s)
PY
      fi
      grep -n -A5 "config TOUCHSCREEN_SSD20XX" $t/Kconfig | head -7; tail -1 $t/Makefile'
    ;;

  dts-sync)
    # devicetree/*.dtsi are the source of truth for our additions; the board DTS
    # in the volume only gains the two #include lines (appended once, order matters:
    # the LK compat layer must come last so its /delete-node/s win).
    in_container_q bash -c '
      set -e
      d=arch/arm64/boot/dts/mediatek
      # rebuild our include list from scratch so a fragment dropped from the repo
      # is also dropped from the tree
      rm -f $d/pennyos-*.dtsi
      sed -i -E "/^#include \"(pennyos-[a-z0-9-]+|mt6771-mtk-lk-compat)\.dtsi\"$/d" $d/mt6771-planet-cosmocom.dts
      cp /work/devicetree/*.dtsi $d/
      for inc in pennyos-debug.dtsi pennyos-panel-ssd2092.dtsi pennyos-power-key.dtsi pennyos-touch-ssd20xx.dtsi pennyos-consys.dtsi pennyos-lid-keys.dtsi pennyos-sound.dtsi mt6771-mtk-lk-compat.dtsi; do
        grep -q "#include \"$inc\"" $d/mt6771-planet-cosmocom.dts || printf "\n#include \"%s\"\n" "$inc" >> $d/mt6771-planet-cosmocom.dts
      done
      tail -5 $d/mt6771-planet-cosmocom.dts'
    ;;

  modules)
    # build all modules and install them (stripped) into the rootfs volume at /vol/mods,
    # where tools/mkrootfs.sh picks them up. Also re-exports Image.gz + DTB.
    docker volume create "$ROOTFS_VOL" >/dev/null
    docker run --rm -v "$VOL:/src" -v "$ROOTFS_VOL:/vol" -v "$REPO:/work" -w /src "$IMAGE" bash -c '
      set -eo pipefail
      M="make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc)"
      $M Image.gz mediatek/mt6771-planet-cosmocom.dtb modules 2>&1 | grep -E "rror|GZIP|DTC" || true
      test -f arch/arm64/boot/Image.gz
      # start clean: modules_install never removes modules that have since become
      # built-in or been disabled, and a stale .ko would shadow the built-in driver
      mkdir -p /vol/mods && find /vol/mods -mindepth 1 -delete
      $M INSTALL_MOD_PATH=/vol/mods INSTALL_MOD_STRIP=1 modules_install >/dev/null
      mkdir -p /work/boot
      cp arch/arm64/boot/Image.gz '"$DTB_REL"' /work/boot/
      echo "modules: $(find /vol/mods/lib/modules -name "*.ko" | wc -l) installed for $(ls /vol/mods/lib/modules)"'
    ;;

  make)
    in_container_q make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" "$@"
    ;;

  dtb)
    # ensure a config exists, then build the Cosmo DTB and export it.
    # NOTE: this kernel's %.dtb rule prepends the dts tree path, so the make
    # target must be RELATIVE to arch/arm64/boot/dts (mediatek/...), while the
    # output artifact lives at the full path.
    in_container_q bash -c '
      set -e
      [ -f /src/.config ] || make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
      make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" mediatek/mt6771-planet-cosmocom.dtb
      mkdir -p /work/boot
      cp /src/'"$DTB_REL"' /work/boot/
      echo "exported: boot/'"$(basename "$DTB_REL")"' ($(stat -c %s /src/'"$DTB_REL"') bytes)"'
    ;;

  shell)
    in_container bash
    ;;

  clean-src)
    docker volume rm "$VOL"
    ;;

  help|*)
    grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '2,25p'
    ;;
esac
