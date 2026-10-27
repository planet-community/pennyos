# Bluetooth: state and findings (2026-10-07)

## What exists

- Kernel: `CONFIG_BT=m` with BR/EDR, LE, RFCOMM, BNEP, HIDP, `hci_vhci`, UHID
  (`kernel/rootfs.config`). Adding these only added modules; they load on a kernel
  built before the change.
- `tools/wmt/penny-btd.c`: opens the vendor driver's `/dev/stpbt` (which makes WMT
  switch the Bluetooth function on), replays Android's vendor set-up, creates a
  virtual controller through `/dev/vhci`, and copies H4 packets both ways.
- Result on the phone: BlueZ has `hci0` (manufacturer 70 = MediaTek, HCI version 8,
  BR/EDR + LE), with the phone's own address from NVRAM. Every HCI command
  succeeds. Wi-Fi keeps working alongside.

## What does not work

Nothing is received: an LE scan gets no advertising reports and an inquiry no
results, with Wi-Fi on (5 GHz) or switched off. Whether it transmits is untested.

## Android's set-up sequence

From the disassembly of `libbluetooth_mtk.so` (chip id 0x6771 takes the "consys"
script; verified against the binary, not just public source). Commands are sent one
at a time, each waiting up to 2 s for its Command Complete:

| Opcode | Meaning | Parameters (offsets into the 110-byte NVRAM record `BT_Addr`) |
|---|---|---|
| 0xFC1A | set BD address | bytes 5..0 (reversed) |
| 0xFC79 | radio | bytes 12..17 |
| 0xFC93 | TX power offset | bytes 27..29 |
| 0xFC7A | sleep | bytes 18..24 |
| 0x0C03 | HCI reset | none |

On this phone everything but the address equals the library's built-in defaults
(radio `07 80 00 06 07 07`, sleep `03 40 1f 40 1f 00 04`, TX offset `ff ff ff`).
The library does nothing else on `/dev/stpbt`: no ioctl, no patch step.
`penny-btd` sends all five and they all succeed, so this was not the missing piece.

## Where to look next

- WMT-level set-up done by Android's `wmt_launcher`/`wmt_loader` that `penny-wmtd`
  does not reproduce: RF calibration data, `WMT_SOC.cfg` (coexistence, antenna
  mode), the co-clock/crystal settings. Wi-Fi power-on logs
  `RF Stat WF_Sx LPAON_LPCR Fail!`, which may be the same root cause showing on the
  2.4 GHz side.
- Whether 2.4 GHz Wi-Fi reception is healthy (the working connection is 5 GHz).
- Antenna-select pins: the vendor device tree may mux GPIOs to the consys for a
  shared 2.4 GHz front end.
- TX check: make the phone discoverable and look for it from another device.

## Loose ends

- Switching Wi-Fi off (`printf 0 > /dev/wmtWifi`) while associated triggers a
  cfg80211 warning in `_cfg80211_unregister_wdev` from the vendor driver.
- Not started at boot; `BT_Addr` has to be copied to
  `/opt/pennyos/conn/nvram/` (the collect script gathers it, the rootfs build
  does not install it yet).
