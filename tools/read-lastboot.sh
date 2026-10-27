#!/bin/sh
# Read the PREVIOUS boot's kernel log from the Cosmo's MTK ram_console / pstore,
# over adb from rooted Android. This is our no-UART "black box" for debugging a
# kernel (e.g. pmOS on the DEBIAN_KDE slot) that hangs/panics: boot it, let it
# fail, then WARM-reboot into Android (adb reboot, a panic auto-reboot, or the
# MTK watchdog) and run this — the log survives in reserved DRAM
# (ram_console @0x54400000 -> /proc/last_kmsg, pstore @0x54410000 -> /sys/fs/pstore).
#
# IMPORTANT: only a WARM reboot preserves the region; a cold power-off wipes it.
# Verified on V23 rooted Android 2026-07-19: adb reboot preserved a full 262 KB log.
#
# Usage: tools/read-lastboot.sh [outdir]   (default: ./collected/lastboot-<ts is not available; uses 'latest'>)
set -e
OUT="${1:-collected/lastboot-latest}"
ADB="${ADB:-adb}"
mkdir -p "$OUT"

echo "=== device ==="; "$ADB" devices
echo "=== pulling /proc/last_kmsg (ram_console) ==="
"$ADB" exec-out 'su -c "cat /proc/last_kmsg"' > "$OUT/last_kmsg.txt" 2>/dev/null || true
echo "  -> $OUT/last_kmsg.txt ($(wc -c < "$OUT/last_kmsg.txt" 2>/dev/null || echo 0) bytes)"

echo "=== pulling /sys/fs/pstore/* (pstore console/panic) ==="
for f in $("$ADB" shell 'su -c "ls /sys/fs/pstore/ 2>/dev/null"' | tr -d '\r'); do
  "$ADB" exec-out "su -c \"cat /sys/fs/pstore/$f\"" > "$OUT/$f" 2>/dev/null || true
  echo "  -> $OUT/$f ($(wc -c < "$OUT/$f" 2>/dev/null || echo 0) bytes)"
done

# LK/preloader log of the CURRENT (Android) boot - shows how LK treats a DTB it accepts.
"$ADB" exec-out 'su -c "cat /proc/pl_lk"' > "$OUT/pl_lk.txt" 2>/dev/null || true
echo "  -> $OUT/pl_lk.txt ($(wc -c < "$OUT/pl_lk.txt" 2>/dev/null || echo 0) bytes)"

# Whose log is in pstore? A mainline boot identifies itself on the first line.
for f in "$OUT"/console-ramoops*; do
  [ -f "$f" ] && { echo "=== $f: $(grep -a -m1 'Linux version' "$f" | cut -c1-90) ==="; }
done

echo "=== last 25 lines of ram_console (quick look) ==="
tail -25 "$OUT/last_kmsg.txt" 2>/dev/null || true
echo
echo "Full logs saved under: $OUT/"
echo "Tip: grep for 'Kernel panic', 'Unable to handle', 'Call trace', 'ramoops', 'Booting Linux'."
