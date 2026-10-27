# boot/

Build output for the boot image (git-ignored except this file): `Image.gz`, the DTB,
and `boot-mainline.img`, which `tools/flash-slot.sh` writes to the phone.

## Format

The Planet multiboot LK boots its alternate slots as a **plain Android boot image v1
with the DTB appended to the kernel and no AVB footer** (learned from the working
`root-boot.img`; the alternate slots are not verified in the unlocked/orange state).

| Param | Value |
|---|---|
| header version | 1 |
| page size | 2048 |
| kernel load | 0x40080000 (base 0x40078000 + 0x8000) |
| ramdisk load | 0x55000000 (LK asserts on anything else, and on a ramdisk over 16 MiB) |
| tags load | 0x54000000 |
| DTB delivery | **appended to the gzip kernel** (`Image.gz` + `.dtb`) |
| os version / patch | 9.0.0 / 2020-04 |

LK also force-applies the phone's `dtbo` overlay to the appended DTB and asserts or hangs
if the result breaks any of its rules. `tools/mkboot.sh` runs `tools/check-lk-dtb.py`
first and refuses to package a DTB LK would reject. The rules, and how they were found:
[../research/lk-dtb-requirements.md](../research/lk-dtb-requirements.md).

LK builds the kernel command line from the *stock* boot partition's DTB plus the string
in the image header, so everything PennyOS needs is in `CMDLINE` in `tools/mkboot.sh`
(with the reasons).

## Build

`tools/build-all.sh` does all of this. By hand, after the kernel steps in
[../kernel/README.md](../kernel/README.md):

```bash
./tools/kbuild.sh modules      # Image.gz + DTB -> boot/, modules -> the rootfs volume
./tools/mkboot.sh rootfs       # -> boot/boot-mainline.img: boots Debian from `linux`
./tools/mkboot.sh debug        # -> the same with a busybox shell and no distro
```

The initramfs is a busybox shell script: `tools/initramfs/rootfs-init.sh` mounts the
`linux` partition and starts systemd on it; `debug-init.sh` stops in a shell on the USB
serial console and saves its log inside the boot slot. The static arm64 busybox is
fetched from Debian 12 the first time.

## Flash

```bash
./tools/flash-slot.sh          # phone in ROOTED ANDROID, over adb
```

It writes **`DEBIAN_KDE` (mmcblk0p41)**, the Gemian slot, which is a normal entry in the
multiboot menu, and verifies it byte for byte. It never writes `boot` (p30, stock
Android), `ROOTED_ANDROID` (p42) or `boot_para` (p1, the multiboot configuration). Slots
are 32 MiB; the image is about 11 MiB. A bad image is fixed by booting Rooted Android
and flashing again.

## Seeing what happened

- **USB serial console.** Both images bring up a serial port on the USB cable (left
  port): `/dev/cu.usbmodem*` on a Mac, 115200 baud. The debug image offers a root shell
  there; the installed system a login. `tools/cosmo-sh.py` runs commands through it.
  It appears only once the kernel has reached USB, so it says nothing about LK.
- **Previous boot's kernel log** (`tools/read-lastboot.sh`): after a crash, warm-reboot
  into Rooted Android and read the log that survived in RAM (pstore / ram_console). It
  also has LK's log, including which panel the phone has.
- **Debug image logs** (`tools/read-slotlog.sh`): the debug initramfs writes its log
  into the boot slot itself, which survives a cold power-off.
- **Hardware UART**: never captured. The test campaign is in
  [../research/serial-test-matrix.md](../research/serial-test-matrix.md) and
  [../research/first-boot-log.md](../research/first-boot-log.md).
