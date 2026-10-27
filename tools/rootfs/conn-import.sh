#!/bin/bash
# Runs inside cosmo-kbuild (see tools/conn-setup.sh): create /c/conn from the vendor
# kernel at $VENDOR_COMMIT plus our patch, unless it already exists.
set -euo pipefail
if [ -d /c/conn/.git ]; then
  if (cd /c/conn && git rev-parse -q --verify HEAD >/dev/null 2>&1); then
    echo "==> /c/conn already set up ($(cd /c/conn && git log --oneline | wc -l) commits)"
    exit 0
  fi
  echo "==> /c/conn is half-initialised from an earlier failed run; starting over"
  find /c/conn -mindepth 1 -delete
fi
echo "==> fetching vendor connectivity sources @ ${VENDOR_COMMIT:0:12}"
if [ ! -d /v/k/.git ]; then
  git clone -q --filter=blob:none --sparse --no-checkout "$VENDOR_REPO" /v/k
fi
cd /v/k
git sparse-checkout set drivers/misc/mediatek/connectivity drivers/misc/mediatek/btif \
  drivers/misc/mediatek/include drivers/misc/mediatek/base/power/include drivers/misc/mediatek/emi >/dev/null
git checkout -q "$VENDOR_COMMIT"
V=/v/k/drivers/misc/mediatek
mkdir -p /c/conn && cd /c/conn
git init -q && git config user.email pennyos@localhost && git config user.name pennyos
mkdir -p connectivity vendor-include/base/power vendor-include/emi
cp -a $V/connectivity/common $V/connectivity/bt $V/connectivity/wlan $V/connectivity/Makefile $V/connectivity/Kconfig connectivity/
cp -a $V/btif btif
cp -a $V/include vendor-include/include
cp -a $V/base/power/include vendor-include/base/power/
cp -a $V/emi/. vendor-include/emi/
# only the generation this phone uses
for d in connectivity/wlan/core/gen2 connectivity/wlan/core/gen4 connectivity/wlan/core/gen4m \
         connectivity/wlan/core/gen4-mt7668 connectivity/bt/mt76xx; do
  if [ -d "$d" ]; then find "$d" -delete; fi
done
echo "$VENDOR_COMMIT" > VENDOR_COMMIT
git add -A && git commit -q -m "Import vendor connectivity sources (@ ${VENDOR_COMMIT:0:12})"
echo "==> applying pennyos-conn.patch"
git apply --whitespace=nowarn /work/kernel/connectivity/pennyos-conn.patch
git add -A && git commit -q -m "pennyos: port to mainline 6.4 (kernel/connectivity/pennyos-conn.patch)"
git log --oneline | head -3
