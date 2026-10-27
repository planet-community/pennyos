# kernel/

Mainline kernel work for the Cosmo (arm64 / MT6771), on top of `affenull2345/linux`
branch `mt6771` (Linux 6.4; `mt6771.dtsi` `#include`s the mainline `mt8183.dtsi`).

## What is here

- `cosmocom.config`, `slim.config`, `debug.config`, `rootfs.config`: config fragments,
  merged in that order onto arm64 `defconfig` (`./tools/kbuild.sh config slim debug rootfs`).
  `slim` exists because LK unpacks the kernel into a fixed-size buffer; each file
  explains its choices.
- `patches/`: small changes to upstream drivers (watchdog, USB VBUS, regulators, display,
  keyboard, Wi-Fi extensions), applied in order by `./tools/kbuild.sh patch`.
  [../docs/hardware-support.md](../docs/hardware-support.md) says which component needs which.
- `drivers/`: drivers written for this project: main panel (`panel-planet-ssd2092.c`),
  touchscreen (`ssd20xx.c`), fuel-gauge current (`cosmo_fg.c`), sound card
  (`cosmo-sound.c`). `./tools/kbuild.sh drivers-sync` copies them into the tree and
  hooks them into Kbuild.
- `connectivity/`: MediaTek's vendor Wi-Fi/Bluetooth stack, ported to 6.4 as one patch
  on the vendor sources. Built out of tree by `tools/conn-setup.sh`; see its README.
- `linux-mt6771/` (git-ignored): your clone of the kernel branch. **Its working tree is
  corrupted on macOS** (case-insensitive file system; the kernel has file names that differ
  only in case, like `xt_CONNMARK.h`/`xt_connmark.h`). Only its `.git` is used. Do not
  build from it directly.

The device-tree additions are in [../devicetree/](../devicetree/).

## Build loop (in Docker; required on macOS)

Builds run in a Linux container with the source in a **case-sensitive Docker volume**
(`cosmo-kernel-src`), cloned from the host `.git`. `tools/build-all.sh` runs the whole
sequence; the steps on their own:

```bash
./tools/kbuild.sh image        # once: the arm64 toolchain image (cosmo-kbuild)
./tools/kbuild.sh src          # clone the kernel source into the volume
./tools/kbuild.sh patch        # apply patches/*.patch
./tools/kbuild.sh drivers-sync # add drivers/*.c
./tools/kbuild.sh dts-sync     # add devicetree/*.dtsi and include them in the board DTS
./tools/kbuild.sh config slim debug rootfs
./tools/kbuild.sh modules      # Image.gz + DTB -> boot/, modules -> the cosmo-rootfs volume
./tools/kbuild.sh dtb          # only the DTB (about a minute)
./tools/kbuild.sh make <targets>   # any make target (ARCH=arm64, cross compiler set)
./tools/kbuild.sh shell        # a shell in the build environment
```

`src` reuses a tree that is already in the volume (and pulls from the host clone);
`./tools/kbuild.sh clean-src` deletes the volume to start from a pristine clone.

Quirk baked into the script: this kernel's `%.dtb` rule prepends the dts-tree path, so the
single-DTB make target must be **relative** (`mediatek/mt6771-planet-cosmocom.dtb`).

## Next

- Rebase from 6.4 onto a current LTS kernel (keeping the `#include "mt8183.dtsi"` approach).
- The open hardware items are in [../docs/hardware-support.md](../docs/hardware-support.md).
