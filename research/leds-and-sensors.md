# LEDs and sensors

What is where, and how it was found. Checked on one phone, 2026-10-28, with
`penny-diag` (the Diagnostics app) and by writing to the chips directly.

## LEDs

Two chips drive the small LEDs:

- **AW9523B GPIO expander** `aw9523_led` (i2c3, 0x5b), 15 pins, LEDs active low
  (output registers 0x02 and 0x03). The board DTS names pins 0-5, 7-9 and 11-13 as
  `gpio-leds`; `devicetree/pennyos-leds.dtsi` adds pin 10 and holds 6 and 14 off.
- **MT6370** (the charger/backlight PMIC): `leds-mt6370-rgb` and `leds-mt6370-flash`.

Mapped by switching one LED on at a time and asking where it lit:

| sysfs name | Chip, pin | Where | What you see |
|---|---|---|---|
| `red:capslock`, `green:numlock`, `blue:scrolllock` | AW9523 0-2 | Caps Lock key | white or light green; the colours are not distinct |
| `red:status`, `green:status`, `blue:status` | AW9523 3-5 | above the outer display | red is dim, blue strong, green shows nothing |
| (none) | AW9523 6 | — | nothing visible; held off |
| `red:indicator`, `green:indicator`, `blue:indicator` | AW9523 7-9 | right of the fingerprint sensor | blue / greenish; red shows nothing |
| `blue:indicator-2` | AW9523 10 | right of the fingerprint sensor | blue. Android lights this spot red while charging, so a red LED is there that none of these pins reaches |
| `red:indicator_1`, `green:indicator_1`, `blue:indicator_1` | AW9523 11-13 | left of the fingerprint sensor | green / blue |
| (none) | AW9523 14 | — | nothing visible; held off |
| `rgb:indicator` | MT6370 RGB (multicolor, levels 0-6) | below the fingerprint sensor | blue / green |
| `white:indicator` | MT6370 4th channel (levels 0-3) | below the fingerprint sensor | red, despite the name |
| `white:flash-1`, `white:flash-2` | MT6370 flash (levels 0-23 / 0-15) | camera flash | both channels drive the same LED; torch mode only |

Names come from the board DTS and are not always the colour you see; the table is
what the eye says. `penny-diag` shows the "Where" column next to each switch.

### Why pins 6, 10 and 14 were lit at boot

The board DTS gives all 15 pins an `output-high` pin configuration (`led_pins`, used
by the gpio-leds node). The 6.4 aw9523 driver inverts it: in `aw9523_pconf_set()`,
`PIN_CONFIG_OUTPUT` falls through into the `PIN_CONFIG_OUTPUT_ENABLE` case, which
negates the argument, so "high" writes 0. Every pin was driven low, every LED on.
gpio-leds then switched its own LEDs off again; the three pins without a driver
stayed on. `pennyos-leds.dtsi` deletes the `output-high` and gives every pin an
owner.

## Sensors

I2C buses scanned from Linux, compared with the vendor device tree:

| Sensor | Bus, address | State |
|---|---|---|
| Light and proximity, Sensortek STK3311-X | i2c1 0x48, PDT_ID 0x12 | **Works.** Mainline `stk3310` driver, `devicetree/pennyos-sensors.dtsi`. Covered: 0 lux, proximity about 1300-1800; uncovered: proximity about 520-720, room light 1-40 lux. |
| Magnetometer, Voltafield AF6133E | i2c1 0x0c, register 0 reads 0x68 | Answers; there is no mainline driver. |
| Barometer | 0x77 in the vendor tree | Nothing answers. |
| Accelerometer and gyroscope (BMI160 in the vendor config) | spi1, CS0 | See below. Nothing answers at the I2C addresses either. |
| Lid (Hall sensor) | GPIO | Works, see `pennyos-lid-keys.dtsi`. |

### The IMU

The vendor tree puts the motion sensor on SPI1 (`11010000`). Its pads (GPIO161-164)
are already in SPI1_A mode from the bootloader; the mainline SPI driver also needs
`mediatek,pad-select = <0>`. Through spidev, in SPI modes 0 and 3 at 100 kHz and
1 MHz, the chip ID register reads 0 and every other read is all zeros: nothing
drives MISO. Android does not talk to it from Linux at all: the vendor config uses
the SCP sensor hub (`MTK_ACCELHUB`, `MTK_GYROHUB`), so the sensor is probably wired
to (or powered by) the SCP coprocessor. Parked; `bmi160_spi` is not built and the
Diagnostics app says "not supported yet".

## Tools

- `penny-diag` (Diagnostics in the app grid): a switch per LED, level sliders, R/G/B
  for the multicolor LED, "Step through" to find each one; live values for light,
  proximity, lid, temperatures, battery and charger. `penny-diag leds` opens on the
  LED tab.
- LED `brightness` and `multi_intensity` files are writable by the `video` group
  (`tools/rootfs/files/90-pennyos-backlight.rules`).
