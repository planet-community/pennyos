# Power: measurements and findings

Readings are battery current from `cosmo_fg` (negative = discharging), averaged over
6-8 s, phone on a 500 mA USB port, Wi-Fi associated unless noted. 2026-10-07.

## Measured

| State | Battery current |
|---|---|
| Login prompt, backlight 2048/2048, charger throttled (see below) | -1271 mA |
| same, backlight 400 | -602 mA |
| same, backlight off | -317 mA |
| niri, backlight 600, charger throttled | -609 mA |
| niri, backlight ~307, before / after fixing the charger | -348 / +187 mA |
| one core online, backlight off, charger fixed | +188 mA |
| one core online, backlight 600, charger fixed | -63 mA |

## Findings

- **Backlight scale.** Android's slider at 255/255 programs the MT6370 to 767/2047
  (0xa4/0xa5 = 0x07/0x5f). Full chip scale costs about 950 mA. The device tree now
  sets `max-brightness = <767>`.
- **Charger input throttled.** Mainline leaves CHG_CTRL6 at the reset value 0xbf
  (minimum input voltage 13.4 V). On 5 V the input current collapses while status
  still reads "Charging". LK writes 0x0d (4.5 V), Android 0x0f (4.6 V).
  `penny-charge-setup` writes 4.6 V. Android also runs CV 4.4 V (we: 4.2 V),
  safety timer and charger watchdog on (we: off).
- **PSCI CPU power states are not usable as-is.**
  - CPU_SUSPEND with the vendor table's "standby" parameter (0x1) corrupts memory
    within milliseconds of cpuidle starting (see `attic/`).
  - CPU_OFF works, CPU_ON afterwards does not: the cores never come back
    ("failed to come online", later `psci: failed to boot CPU1 (-22)`), and only a
    reboot recovers them. Do not offline cores on this firmware.
  - Boot-time CPU_ON works, so the firmware needs something the vendor kernel does
    around hotplug/idle (MCDI, SPM/SSPM handshakes) that mainline does not.
- **Unused clocks and power domains** are now released (no `clk_ignore_unused` /
  `pd_ignore_unused`); display, USB, Wi-Fi and GPU still work. `disp` and `conn`
  are the only domains left on at idle.

- **Eight idle cores cost the same as one** (+184 vs +188 mA charging, backlight
  off), and stopping the Wi-Fi stack changes nothing measurable (+179 mA).
- **Modem is off**: SPM PWR_STATUS = 0x400fff4e (MD1 bit clear), MD1_PWR_CON = 0x112.
- **DPMS off saves ~60 mA** beyond the backlight (+184 -> +244 mA), but the picture
  comes back corrupted (horizontal lines) after power-on: the panel entry has no
  init sequence and the DSI restart does not resynchronise. Only a reboot fixes it.
  `penny-screen` therefore stays backlight-only until the panel driver can
  re-initialise the SSD2092.
- Sleep states offered: `freeze mem disk`, mem_sleep `s2idle [deep]`. "deep" is PSCI
  SYSTEM_SUSPEND and must be assumed broken like the other PSCI power calls; the
  default should be s2idle. Not yet tested.

- **Panel driver** (`panel-planet-ssd2092`): with the vendor reset/init/suspend
  sequences the display survives DPMS off/on, and the touch half is re-booted via
  a notifier. Display fully off: +253 mA vs +103 mA on at brightness 206.
- **s2idle, first attempts**: refused while a USB host is attached. mtu3's
  `ssusb_gadget_suspend()` returns -EBUSY when the gadget is connected, so
  `PM: Some devices failed to suspend`. The aborted attempt is harmless on the
  phone. (An earlier note here said the USB link stays dead afterwards; the cable
  had been unplugged for those tests. With the cable in, USB networking is back
  after a sleep.) `deep` untested
  and not to be used. `mem_sleep_default=` on the command line does not stick;
  tmpfiles sets s2idle at boot.

- **s2idle, what it takes** (2026-10-07):
  - mtu3 must be soft-disconnected first (see above).
  - `mtk_btif` (vendor port) returns -1 unless the combo chip's host link is idle
    (state DPIDLE). After a refused attempt it stays ON for longer than a 4 s retry
    gap, so retrying eight times in a row failed eight times. Powering Wi-Fi off
    (`printf 0 > /dev/wmtWifi`) before suspend made it succeed on the first try.
    `penny-sleep-hook` does both and undoes both on wake.
  - Measured with the new charge counter (`cosmo-battery/charge_counter`, checked
    against integrated current: 328 vs ~316 uAh over 30 s): 75 s asleep on a 500 mA
    port gained 5721 uAh = +275 mA average. Awake with the display off it was
    +253 mA. So s2idle currently saves only about 20 mA over screen-off: with no
    CPU idle state deeper than WFI and no SoC low-power mode, "asleep" is close to
    "idle". Real savings need the MediaTek idle/suspend firmware protocol.
  - Wake sources tried: RTC alarm only.

## Fuel gauge and thermal protection (2026-10-28)

- **Chromium powered the phone off.** Starting it D-Bus-activates UPower. The old
  `cosmo-battery` had no voltage or percentage, so UPower took it as 0 % and ran its
  critical action (power off) exactly 20 s later. Fixed by giving the battery a real
  percentage (below), not by masking UPower.
- **Coulomb counter checked against the current**, 1 s current samples over about 60 s:
  idle +24 mA averaged vs +27 mA from the counter; eight busy cores -172 vs -174 mA.
  Single current readings swing a lot; compare averages, not spot values.
- **Battery profile** from the stock device tree (`/battery`, 4 temperature tables of
  100 points: discharged charge, OCV, resistance). 25 C: 4.36 V at full; 618 mAh is
  above an OCV of 4.2 V, 4276 mAh is used by 3.4 V, so 3658 mAh between; 155 mOhm at
  half charge. Android charged to 4.4 V (`battery_cv`); we stop at 4.2 V.
- **SoC temperature** (auxadc_thermal, MT8183 data): 35 C idle, 50.7 C after 40 s of
  eight busy cores, back to 36 C 20 s later. Only `cpu-thermal` registers; the tzts
  zones have no trips.
- **Cooling without cpufreq or hotplug:** confining `user.slice` with
  `AllowedCPUs=` works and is reversible (set it back to `0-7`; an empty value does not
  reset `cpuset.cpus`). The GPU's devfreq `max_freq` (300-800 MHz) works as a cap.
  `CONFIG_CFS_BANDWIDTH` is off, so `cpu.max` is not available.

## Android reference (same phone, same port)

Screen at full brightness: battery current hovers around zero. cpuidle states
`rgidle` and `mcdi`; cpufreq 793 MHz - 1.99 GHz (little) / 2.1 GHz (big), governor
schedplus. MT6370 register dump: `collected/android-ref/` (not in git).
