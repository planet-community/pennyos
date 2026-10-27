#!/usr/bin/env bash
#
# android-recon.sh — Capture hardware ground-truth from a Cosmo Communicator
# running its stock (rooted) Android, over adb.
#
# This dumps everything useful for mainline-Linux porting and reverse
# engineering: kernel version/config, dmesg, device tree, i2c/spi/input
# devices, sysfs, gpio, regulators, clocks, partition layout, loaded
# modules, firmware blobs, and the vendor kernel command line.
#
# Usage:
#   ./tools/android-recon.sh            # writes to collected/device-dumps/<timestamp>/
#   OUT=/path ./tools/android-recon.sh  # custom output dir
#
# Requirements: adb in PATH, device in Android with USB debugging enabled.
# Root (adb root / Magisk su) massively improves coverage but is optional.
#
set -uo pipefail

TS="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT:-collected/device-dumps/$TS}"
mkdir -p "$OUT"

echo "==> Output directory: $OUT"

if ! command -v adb >/dev/null 2>&1; then
  echo "ERROR: adb not found in PATH. Install Android platform-tools." >&2
  exit 1
fi

echo "==> Waiting for device..."
adb wait-for-device || { echo "No device."; exit 1; }

# Try to elevate. Cosmo stock Android is commonly rooted; if adb root fails
# we fall back to 'su -c' (Magisk), then to unprivileged.
SU_PREFIX=""
if adb root 2>/dev/null | grep -qiv "cannot\|unable\|not"; then
  adb wait-for-device
fi
if adb shell 'id' 2>/dev/null | grep -q 'uid=0'; then
  echo "==> Running as root (adbd root)."
elif adb shell 'su -c id' 2>/dev/null | grep -q 'uid=0'; then
  echo "==> Root available via su; commands will be wrapped in 'su -c'."
  SU_PREFIX="su -c "
else
  echo "==> WARNING: no root. Coverage will be limited (dmesg, most sysfs, DT blocked)."
fi

# run <label> <shell-command>  -> saves stdout+stderr to $OUT/<label>.txt
run() {
  local label="$1"; shift
  local cmd="$*"
  echo "  - $label"
  if [ -n "$SU_PREFIX" ]; then
    adb shell "su -c '$cmd'" >"$OUT/$label.txt" 2>&1
  else
    adb shell "$cmd" >"$OUT/$label.txt" 2>&1
  fi
}

echo "==> Collecting system identity..."
run 00-getprop            "getprop"
run 00-uname              "uname -a"
run 00-cmdline            "cat /proc/cmdline"
run 00-version            "cat /proc/version"
run 00-cpuinfo            "cat /proc/cpuinfo"
run 00-meminfo            "cat /proc/meminfo"

echo "==> Kernel log & modules..."
run 01-dmesg              "dmesg"
run 01-last_kmsg          "cat /proc/last_kmsg"
run 01-lsmod             "lsmod || cat /proc/modules"
run 01-kconfig            "zcat /proc/config.gz"
run 01-kallsyms_count     "wc -l /proc/kallsyms"

echo "==> Buses: i2c / spi / input / usb..."
run 02-i2c-list           "ls -l /sys/bus/i2c/devices/"
run 02-i2c-names          "for d in /sys/bus/i2c/devices/*/name; do echo \"\$d: \$(cat \$d)\"; done"
run 02-spi-list           "ls -l /sys/bus/spi/devices/"
run 02-platform-list      "ls -l /sys/bus/platform/devices/"
run 02-input-devices      "cat /proc/bus/input/devices"
run 02-input-evtest       "ls -l /dev/input/"
run 02-usb-list           "ls -l /sys/bus/usb/devices/ 2>&1; cat /sys/kernel/debug/usb/devices 2>&1"

echo "==> Device tree (live)..."
run 03-dt-model           "cat /proc/device-tree/model /proc/device-tree/compatible"
run 03-dt-tree            "find /proc/device-tree -maxdepth 3 | sort"
# Pull the full live DT as a blob for offline decompilation with dtc.
echo "  - 03-devicetree.dtb (pull)"
if [ -n "$SU_PREFIX" ]; then
  adb shell "su -c 'ls /sys/firmware/fdt'" >/dev/null 2>&1 && \
    adb pull /sys/firmware/fdt "$OUT/03-live.dtb" 2>/dev/null
else
  adb pull /sys/firmware/fdt "$OUT/03-live.dtb" 2>/dev/null
fi

echo "==> Clocks / regulators / gpio / pinctrl..."
run 04-clk-summary        "cat /sys/kernel/debug/clk/clk_summary"
run 04-regulators         "cat /sys/kernel/debug/regulator/regulator_summary"
run 04-gpio               "cat /sys/kernel/debug/gpio"
run 04-pinctrl            "cat /sys/kernel/debug/pinctrl/*/pinmux-pins"
run 04-interrupts         "cat /proc/interrupts"
run 04-iomem              "cat /proc/iomem"

echo "==> Storage & partitions..."
run 05-mounts             "cat /proc/mounts"
run 05-partitions         "cat /proc/partitions"
run 05-by-name            "ls -l /dev/block/by-name/ 2>&1; ls -l /dev/block/platform/*/by-name/ 2>&1"
run 05-blkid              "blkid"

echo "==> Power / thermal / battery..."
run 06-power-supply       "for d in /sys/class/power_supply/*; do echo \"== \$d ==\"; cat \$d/uevent; done"
run 06-thermal            "for d in /sys/class/thermal/*/; do echo \"== \$d ==\"; cat \$d/type 2>/dev/null; cat \$d/temp 2>/dev/null; done"

echo "==> Sensors / misc / firmware..."
run 07-sensors-list       "ls -l /sys/class/sensors/ 2>&1; ls -l /dev/*sensor* 2>&1"
run 07-misc               "cat /proc/misc"
run 07-firmware-blobs     "ls -lR /vendor/firmware /system/etc/firmware /vendor/etc/firmware 2>&1"
run 07-tty               "ls -l /dev/tty* /dev/ttyS* /dev/ttyMT* 2>&1"

echo "==> Keyboard & CoDi hunt (Cosmo-specific)..."
run 08-keyboard-input     "getevent -pl 2>&1"
run 08-codi-hunt          "ls -lR /sys/devices/platform 2>/dev/null | grep -iE 'codi|cover|stm32|second|aux|slc|uart' ; getprop | grep -iE 'codi|cover|keyboard|kpd'"
run 08-kpd                "ls -l /sys/devices/platform/*keypad* /sys/devices/platform/*kpd* 2>&1; cat /proc/keypad* 2>&1"

echo "==> Done. Summary:"
ls -la "$OUT"
echo
echo "Next steps:"
echo "  - Decompile the live device tree:   dtc -I dtb -O dts $OUT/03-live.dtb -o $OUT/03-live.dts"
echo "  - Grep i2c/spi names against known chip drivers to identify sensors."
echo "  - Review 01-kconfig.txt for which vendor drivers are compiled in."
