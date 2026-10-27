#!/bin/sh
# Read back the logs the debug initramfs saved inside our own boot slot (DEBIAN_KDE,
# 1 MiB records at 24 MiB + N). Unlike pstore these survive a cold power-off.
# Usage: tools/read-slotlog.sh [outdir]      (from rooted Android, over adb)
set -e
OUT="${1:-collected/slotlog-latest}"
ADB="${ADB:-adb}"
mkdir -p "$OUT"
for n in 0 1 2 3; do
  "$ADB" exec-out "su -c 'dd if=/dev/block/by-name/DEBIAN_KDE bs=1048576 skip=$((24 + n)) count=1 2>/dev/null'" | tr -d '\000' > "$OUT/checkpoint$n.txt"
  if head -c 11 "$OUT/checkpoint$n.txt" | grep -q PENNYOS-LOG; then
    echo "checkpoint $n: $(wc -l < "$OUT/checkpoint$n.txt" | tr -d ' ') lines - $(head -1 "$OUT/checkpoint$n.txt")"
  else
    echo "checkpoint $n: (empty)"; : > "$OUT/checkpoint$n.txt"
  fi
done
echo "saved under $OUT/"
