# research/

Notes written while porting, one topic per file. Each is dated; older ones describe
what was believed at the time, and later files supersede them. What works now is in
[../docs/hardware-support.md](../docs/hardware-support.md).

**Where the port stands and how it got there**
- [first-boot-log.md](first-boot-log.md): chronological bring-up log, newest first. Start here.
- [lk-dtb-requirements.md](lk-dtb-requirements.md): what the stock bootloader demands of a
  kernel image, reverse-engineered from its binary. Why early images boot-looped.
- [mainline-status.md](mainline-status.md): the state of upstream before this project.

**Per subsystem**
- [wifi-scoping.md](wifi-scoping.md): the vendor Wi-Fi/Bluetooth stack and its port.
- [bluetooth.md](bluetooth.md): Bluetooth, where it stops.
- [power.md](power.md): current measurements, sleep, CPU idle and frequency.
- [leds-and-sensors.md](leds-and-sensors.md): where each LED is, which sensors answer, the IMU on SPI.
- [dt-gap-analysis.md](dt-gap-analysis.md): upstream device tree against the vendor's.

**The phone and its Android side**
- [rooting.md](rooting.md): rooting V23 without risking the IMEI, and the backups to take.
- [device-recon-findings.md](device-recon-findings.md): hardware facts read from Android.
- [kernel-and-boot.md](kernel-and-boot.md): the MT6771/MT8183 kernel strategy and boot chain.

**Decisions and dead ends**
- [distro-choice.md](distro-choice.md): why the distribution is bound late (Debian today).
- [re-target.md](re-target.md): ranking of the reverse-engineering targets.
- [serial-test-matrix.md](serial-test-matrix.md): the hardware UART hunt (never captured).
- [attic/](attic/): things that were tried and did not work.
