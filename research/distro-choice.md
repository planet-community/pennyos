# Distribution Choice: pmOS vs Debian/Mobian

**Decision: Do the kernel/device-tree/driver work in the mainline kernel tree, using
postmarketOS (`pmbootstrap`) as the development harness. Bind the distribution
(Debian/Mobian) late — it's a cheap, reversible rootfs swap.**

## Why

A device port has layers, and only the outermost is distro-specific:

| Layer | Artifact | Distro-coupled? |
|---|---|---|
| Kernel + device tree + drivers | `.dts`→`.dtb`, defconfig, driver C | **No** — freestanding, no libc |
| Packaging/metadata | pmOS `deviceinfo` / Mobian TOML | Thin declarative wrapper |
| Boot/initramfs tooling | `mkinitfs`, `boot-deploy` | pmOS `boot-deploy` is deliberately distro-agnostic |
| Rootfs / userspace | Alpine(musl) vs Debian(glibc) | The easy, swappable part |

The expensive work (DT + drivers) is a kernel artifact that transfers **unchanged** to
Debian/Mobian. Mobian consumes the *same* mainline kernel + DTB and even reads pmOS
`deviceinfo` as its source of truth. So nothing done under pmOS is "Alpine-locked."

pmOS also gives the tightest driver-iteration loop for an immature device
(`pmbootstrap` build → initramfs → flash → serial console), whereas Mobian's porting
flow presupposes a device that *already* boots mainline.

## musl vs glibc

Irrelevant to kernel/DT/driver work (kernel links no libc). Only matters in the
userspace-blob endgame: glibc/Debian is smoother if we lean on Android-derived
proprietary userspace libraries. The mainline path tries to avoid such blobs, which
neutralizes the issue.

## Existing efforts

- **`affenull2345/linux` branch `mt6771`** — the real mainline Cosmo work. Early/stale
  (last activity ~July 2023). Has: MT6771 + Cosmo device tree, Cosmo DRM panel driver,
  GPIO keyboard-matrix driver, AW9523 I2C GPIO-expander pinctrl driver, FUSB301 USB-C
  port controller. "Minimal bring-up," not a daily driver.
- **`planet-community`** org — pmaports fork, nascent `linux-planet-mainline`, and the
  maintained downstream `android_kernel_planetcom_mt6771` (vendor 4.x).
- **Gemian** — Debian on Gemini/Cosmo, official "Linux for Cosmo" (Debian/KDE). Runs
  the **downstream `cosmo-linux-kernel-4.4`** — proves Debian userspace runs fine on
  this hardware, but it's a mainline dead-end.
- **No dedicated Mobian Cosmo port** and no sibling MT6771 mainline device to crib from
  (MediaTek mainline support lags Qualcomm badly).

## The tradeoff, explicitly

- We live in Alpine/musl userspace during development — fine for kernel work, slightly
  more friction if we need glibc/Android userspace blobs to test a peripheral.
- If the near-term goal were "usable Debian today," Gemian already delivers that on the
  4.4 kernel — but that's not mainline. **The distribution is a rootfs decision; the
  project is a kernel decision.**

## Key URLs
- pmaports / boot-deploy distro-agnostic design: https://docs.postmarketos.org/pmaports/main/index.html · https://gitlab.com/postmarketOS/pmaports/-/issues/214
- pmOS device categorization: https://docs.postmarketos.org/pmaports/main/device-categorization.html
- Mobian porting: https://wiki.debian.org/Mobian/Porting · https://blog.mobian.org/posts/2023/03/07/porting-to-new-devices/
- Mainline Cosmo kernel branch: https://github.com/affenull2345/linux/commits/mt6771
- planet-community org: https://github.com/planet-community
- Gemian: https://github.com/gemian · https://github.com/gemian/cosmo-linux-kernel-4.4
- Planet official Debian/KDE: https://support.planetcom.co.uk/index.php/Linux_for_Cosmo
- MediaTek mainline status: https://wiki.postmarketos.org/wiki/MediaTek
