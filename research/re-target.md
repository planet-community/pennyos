# Reverse-Engineering Target: pick the CoDi cover display

**Recommendation: the CoDi cover display is our first RE/bring-up target.** It is the
only distinctive Cosmo peripheral that reaches a demonstrable mainline result with
**zero new kernel drivers** — just a UART + a userspace daemon. High visibility, high
tractability, genuine "we can do it" proof.

Ranked:
1. **CoDi cover display — DO FIRST.** Userspace-only, standard UART, protocol already
   RE'd and cross-validated, working reference implementations to port.
2. **Keyboard + backlight — strong second.** I2C GPIO-expander matrix (documented) +
   existing out-of-tree driver; needs a kernel module. Backlight is near-free (leds-class).
3. **Fingerprint — avoid.** Goodix SPI match-on-chip behind a proprietary blob; no
   upstream libfprint support. Large, uncertain effort.

> Note on framing: the CoDi and keyboard were *already* reverse-engineered by the
> community, so our "win" is really integration/porting onto a **mainline** stack where
> neither exists today — plus on-device validation. That's what makes it low-risk.

## CoDi — how it works

- Secondary AMOLED + touch cover display driven by its **own STM32L4R9AIIx MCU**. Main
  SoC ↔ STM32 over a plain **UART**.
- SoC side: **`/dev/ttyS1`**. STM32 side: **LPUART1**. **115200 8N1** for commands,
  **230400** for the XMODEM firmware-upload channel.
  - Gemian ref app: `serial.Serial('/dev/ttyS1', baudrate=115200)` (codi-app/SerialPortManager.py)
  - Firmware: `lpuart1Handle.Init.BaudRate = 115200`, 8B/none/1 (OpenCodi/Src/uart_comms.c)
  - Android exposes it: `init.project.rc` → `chmod 0777 /dev/ttyS1`

### Protocol (fully documented, `X!X!`)
- Magic header `0x58215821` = ASCII **`X!X!`**
- 16-byte header: u32 packet size (BE), u32 command id, u32 sequence, then payload.
- Commands namespaced by direction: **`MTK_*`** = SoC→CoDi, **`ST32_*`** = CoDi→SoC.
  Covers protocol version, datetime, cover/lock/torch/battery status, telephony/call
  control, camera-to-CoDi frames, media/alert display, LEDs, orientation, notifications.
- Cross-validated across 3 codebases: OpenCodi (STM32 parser), codi-app (Python reader),
  `codi_protocols` (Rust crates).

### Mainline porting plan (no kernel driver)
1. Get mainline MT6771 to enumerate UART1 as `/dev/ttySx` (generic MTK 8250 serial DT
   node — the only kernel-side task).
2. **Verify which physical UART maps to the STM32** and that it isn't stolen by the
   kernel console / Bluetooth on the mainline DT. (Real gotcha.)
3. Run a userspace daemon speaking `X!X!` — port existing `codid` (Rust; already targets
   pmOS/Sailfish/UBports/Droidian) or the simpler Python `codi-app`.

Caveat to set expectations: rendering goes *through* the STM32 command set (send media/
alert/status frames), not a Linux framebuffer — an appliance-style display. For a PoC
(clock, notifications, call UI, LEDs) that's exactly what the protocol is for.

## Keyboard + backlight (second)
- QWERTY matrix scanned by **AWINIC AW9523B** I2C GPIO expander @ **0x5B on i2c bus 4**
  (`4-005b`): 8 rows P0, 7 cols P1. SHDN=GPIO175, INT=GPIO12. Full register map + keycode
  matrix documented in `planet-psion-kpd-driver`. Out-of-tree driver exists (active 2026).
- **Backlight**: second Awinic **AW9524 @ 0x5B on i2c bus 3**, Android LED class
  `/sys/class/leds/kbd_backlight` (max_brightness=5). Maps to `leds-class` once I2C is up.

## Fingerprint (avoid)
Goodix `/dev/goodix_fp`, HAL `fingerprint.mt6771.so` (proprietary), SPI match-on-chip.
libfprint doesn't support it. Not a PoC.

## Sources
- CoDiOS org: https://github.com/Cosmo-CoDiOS · protocol: https://github.com/Cosmo-CoDiOS/codi_protocols
- CoDi daemon (Rust): https://github.com/Cosmo-CoDiOS/codid · ref app (Python): https://github.com/Cosmo-CoDiOS/codi-app
- Clean-room STM32 fw: https://github.com/Treeki/OpenCodi
- FOTA teardown: https://wuffs.org/blog/pulling-apart-the-cosmos-systemfota-updater
- Keyboard RE + driver: https://github.com/planet-community/planet-psion-kpd-driver
- Android device tree: https://github.com/planet-community/android_device_planetcom_cosmocom
