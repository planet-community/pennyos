# PennyOS

**Modern mainline Linux** for the **Planet Computers Cosmo Communicator**
(MediaTek Helio P70 / MT6771, `planet,cosmocom`, board `k71v1_64_bsp`).

The name is after Penny from *Inspector Gadget*, who did the real work on a little
computer that folded shut like a book. Written **PennyOS** in prose and `pennyos` in
file names and paths; the commands on the phone start with `penny-` (`penny-setup`,
`penny-settings`). "Cosmo" always means the hardware. The project was called
`cosmonext` before 2026-10-13.

This repo is a working base for kernel/device-tree/driver bring-up plus reverse
engineering of unsupported hardware. It is **research + tooling**, not (yet) a distro.

---

## Status: it boots, and it is usable

Mainline **Linux 6.4** + **Debian 13** + the **niri** desktop run on a real Cosmo from the
internal eMMC, alongside stock Android (multiboot slot, nothing on the Android side is
touched). Display, GPU, touch, keyboard, Wi-Fi, charging, screen-off, sleep on lid close
and USB networking work; the microphone records; the modem, speakers, cameras and
Bluetooth do not.

**[What works and what doesn't, and by what means](docs/hardware-support.md)** has
the full table: for each component, whether it works and whether that is through a
mainline driver, a driver written here, a vendor port or a binary blob.

**Hardware variants.** Planet shipped at least two main panels. This repo currently
describes the **Solomon SSD2092** one (panel + touch). Units with the Novatek NT36672
panel will boot, but need their own panel entry and touch driver. LK prints which one
you have (`we will use lcm: ...`); `tools/read-lastboot.sh` saves that log from Android.

---

## Before you start

This writes to your phone's internal storage. It is designed never to touch Android,
its data, the stock boot partitions or NVRAM (where the IMEI lives), and every flash is
verified byte for byte, but it comes with **no warranty**: back up first
([research/rooting.md](research/rooting.md)) and read the scripts you run.

**The phone**

- A Cosmo Communicator with the **SSD2092 panel** (see above). The Fn layer of the
  keyboard is only mapped for the **Japanese** layout so far; other layouts type, but Fn
  combinations will be wrong.
- Stock firmware **V23** with **Rooted Android** installed in a multiboot slot, and
  `adb` + Magisk `su` working (Magisk > Superuser access: "Apps and ADB"). How:
  [research/rooting.md](research/rooting.md).
- Planet's multiboot partition layout, i.e. a `linux` partition and a `DEBIAN_KDE` boot
  slot (`adb shell ls /dev/block/by-name` lists both). PennyOS replaces the Gemian
  install there: **installing erases the `linux` partition**.
- About 2.5 GB free on the phone's internal storage (the root filesystem image is
  copied there before it is written).

**The computer that builds it.** Written and tested on macOS (Apple silicon). A Linux
host should work, but has not been tried.

- Docker (Docker Desktop on macOS), with ~15 GB free for its volumes; `adb`, `git`,
  `curl`, `python3`, and the device-tree tools `dtc`, `fdtoverlay` and `fdtget`
  (`brew install dtc`, `brew install --cask android-platform-tools`).
- An SSH key at `~/.ssh/id_ed25519.pub`. The image authorizes that key for the default
  user; password login over SSH is off, so without it you only have the phone's own
  screen and keyboard.

**The image you build is for your phone only**: it contains your unit's Wi-Fi
calibration data and MAC address, and proprietary radio firmware copied from your own
vendor partition. None of that is in this repository.

---

## Build and install

```bash
# 0. once per phone, booted into ROOTED ANDROID and connected over adb
git clone --depth 1 -b mt6771 https://github.com/affenull2345/linux.git kernel/linux-mt6771
#    back up NVRAM and the boot partitions (incl. dtbo) into collected/ as in
#    research/rooting.md "Immediately after root"; the build checks the DTB against them
./tools/android-recon.sh       # the vendor device tree, which the same check needs
./tools/collect-radio-blobs.sh # Wi-Fi firmware and this phone's calibration

# 1. build everything (30-60 min the first time)
./tools/build-all.sh        # -> boot/boot-mainline.img, out/debian-rootfs.img

# 2. install (phone in ROOTED ANDROID). The first one ERASES the `linux` partition
#    (asks you to type yes); the second writes the DEBIAN_KDE boot slot.
./tools/install-rootfs.sh
./tools/flash-slot.sh

# 3. reboot, pick the Debian/Linux entry. Log in as cosmo / cosmo, then run
#    penny-setup (or Settings > First-time setup): user name, password, language,
#    keyboard layout, time zone, host name.
#    Wi-Fi: tap the Wi-Fi icon in the top bar, pick your network, enter the passphrase.
ssh cosmo@172.16.42.1                       # over the USB cable (left port); key-only
penny-wifi-connect                          # on the phone: Wi-Fi from a terminal (lists, then
                                            #   penny-wifi-connect "Your Network")
```

What `build-all.sh` runs, if you want the pieces: `tools/kbuild.sh` (kernel: `image`,
`src`, `patch`, `drivers-sync`, `dts-sync`, `config slim debug rootfs`, `modules`),
`tools/conn-setup.sh` (radio stack), `tools/rootfs/build-niri.sh` and
`tools/rootfs/build-whisper.sh` (desktop and voice typing, each pinned to a tag and
commit), `tools/splash/build.sh` (start-up animation), `tools/mkboot.sh rootfs` (boot
image, after checking the DTB against the bootloader's rules) and `tools/mkrootfs.sh`
(Debian image). Each step reuses its Docker volume, so a second run is much faster.
The kernel and radio trees were rebuilt from a pristine clone with these scripts and
compared against the development trees (identical config, DTB and sources) on 2026-10-06.

**Updating a phone that is already installed.** Scripts, theme and desktop settings
can be pushed over SSH without reinstalling: `tools/install-theme.sh` (and
`tools/install-niri.sh` for a new niri build). A new kernel needs matching modules,
which live in the root filesystem, and no script copies them to an installed phone yet:
the supported path is `install-rootfs.sh` plus `flash-slot.sh`. That erases the `linux`
partition, home directories included, so copy off anything you want to keep first.

**Recovery.** Android and the other boot slots are never written, so a bad image is
fixed by booting Rooted Android from the multiboot menu and flashing again. Hold Esc
for 8 s to force the phone off (sometimes twice to reach the menu). If the kernel never
comes up, `tools/mkboot.sh debug` builds an image with a debug shell instead of the
desktop, and [boot/README.md](boot/README.md) lists the ways to read logs from a
failed boot.

---

## Repo layout

```
research/       What we learned, one file per topic (index: research/README.md)
docs/           What works (hardware-support.md), hardware inventory, reference links
devicetree/     Our device-tree additions (*.dtsi) on top of the upstream board file
kernel/         Config fragments, patches, our drivers, the connectivity port
tools/          Build, flash and on-device scripts (build-all.sh is the entry point)
  rootfs/       Debian image build; files/ is everything installed on the phone
  wmt/          Radio daemons (penny-wmtd, penny-btd) and Wi-Fi tools
  splash/       Start-up animation
collected/      Per-phone dumps, backups and blobs (git-ignored, never committed)
```

---

## Upstream references
- Mainline kernel branch: https://github.com/affenull2345/linux/tree/mt6771
- pmOS wiki (Cosmo): https://wiki.postmarketos.org/wiki/Planet_Computers_Cosmo_Communicator_(planet-cosmocom)
- Vendor 4.x kernel (chip/GPIO source of truth): https://github.com/planet-community/android_kernel_planetcom_mt6771
- CoDi open firmware + protocol: https://github.com/Cosmo-CoDiOS · https://github.com/Treeki/OpenCodi
- Keyboard RE + driver: https://github.com/planet-community/planet-psion-kpd-driver
- MT8183 mainline dtsi (driver source of truth): https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/mediatek/mt8183.dtsi
- Gemian (Debian on downstream kernel): https://github.com/gemian

---

## License

GPL-2.0 ([LICENSE](LICENSE)), the license of the kernel this builds on. The device-tree
files are GPL-2.0 or MIT, as is usual for device trees. Two files carry their own: `tools/kbuild/mkbootimg.py` and `tools/kbuild/unpack_bootimg.py` are from
the Android Open Source Project under Apache-2.0. `kernel/connectivity/pennyos-conn.patch`
modifies MediaTek's GPL-2.0 vendor sources.

No proprietary firmware is included: `tools/collect-radio-blobs.sh` copies it from your
own phone. Planet Computers and MediaTek are not involved with this project.
