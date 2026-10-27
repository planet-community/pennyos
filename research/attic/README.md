# Things that were tried and did not work

- `pennyos-cpuidle.dtsi.broken` — PSCI idle state "standby" (suspend param 0x1,
  taken from the vendor device tree) for all eight cores. Two boots out of two died
  about 0.69 s in, right where cpuidle starts, with corrupted kernel memory
  (NULL dereference inside the workqueue code, stack-protector panic, several CPUs
  that could not be stopped). The vendor kernel does not reach this state through
  plain PSCI: its MCDI driver coordinates with firmware first. A working idle state
  needs that protocol understood, not just the parameter.
