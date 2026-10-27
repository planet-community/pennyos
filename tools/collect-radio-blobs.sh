#!/bin/sh
# Collect the proprietary radio firmware and THIS phone's Wi-Fi calibration (NVRAM)
# into collected/vendor-conn/ (git-ignored). Needed once per phone before
# tools/mkrootfs.sh can produce an image with working Wi-Fi.
#
# Run with the Cosmo booted into ROOTED ANDROID and connected over adb.
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO/collected/vendor-conn"
ADB="${ADB:-adb}"
mkdir -p "$OUT/firmware" "$OUT/nvram"
"$ADB" get-state >/dev/null
for f in ROMv4_be_patch_1_0_hdr.bin ROMv4_be_patch_1_1_hdr.bin WIFI_RAM_CODE_6759 WMT_SOC.cfg; do
  "$ADB" exec-out "su -c 'cat /vendor/firmware/$f'" > "$OUT/firmware/$f"
done
# Wi-Fi calibration + MAC address; the path moved between Android releases
for p in /vendor/nvdata/APCFG/APRDEB /mnt/vendor/nvdata/APCFG/APRDEB /data/nvram/APCFG/APRDEB; do
  if "$ADB" shell "su -c 'test -f $p/WIFI'" 2>/dev/null; then
    "$ADB" exec-out "su -c 'cat $p/WIFI'" > "$OUT/nvram/WIFI"
    "$ADB" exec-out "su -c 'cat $p/BT_Addr'" > "$OUT/nvram/BT_Addr" 2>/dev/null || true
    break
  fi
done
ls -la "$OUT/firmware" "$OUT/nvram"
[ -s "$OUT/firmware/WIFI_RAM_CODE_6759" ] || { echo "firmware not found - is this the rooted slot?"; exit 1; }
[ -s "$OUT/nvram/WIFI" ] || echo "WARNING: no NVRAM WIFI file found; Wi-Fi will work uncalibrated with a random MAC"
