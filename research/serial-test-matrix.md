# Cosmo SBU UART — Test Matrix

Goal: catch the MT6771 boot-log UART. Confirmed target (Titan Pocket, same SoC):
**TX = SBU1 (A8), 1.8V, 921600 8N1, receive-only.** We now suspect earlier zeros were a
**USB-C cable without SBU wiring** — so all tests below use a **full-featured / Thunderbolt
cable** (carries SBU). Adapter = DSD SH-U09C5 (FTDI), switch on **1.8V**.

## How to run each config
1. In a terminal, start the watcher (clears the log + live view):
   ```
   sh tools/serial-watch.sh
   ```
2. Set the wiring for the row (only the **bold** thing changes between adjacent rows).
3. **Cold-boot**: Cosmo fully OFF → power ON → select `DEBIAN_KDE`. Watch ~40s.
4. Mark the result, Ctrl-C the watcher, move to the next row (re-run the watcher).

**Reading the result:**
- **0 bytes the whole time** → dead. Mark ❌.
- **Byte count grows, readable text** → 🎉 STOP (we are in).
- **Byte count grows, garbage** (`M-x`, random symbols via `cat -v`) → right pin, wrong
  baud/level. Mark ⚠️, restart `tools/serial-capture.py` at 115200 and retry.

Constant across all rows unless noted: **Thunderbolt cable**, adapter **GND↔GND**, switch
**1.8V**, RXD is the only signal wire. "CC resistors" = `CC1→5k→GND` **and** `CC2→5k→GND`
(each 5k = two 10k in parallel). "VBUS" = adapter **5V pin → breakout VBUS**.

> Bonus check on any CC-resistor row: after boot, meter the breakout **VBUS pad** (black on
> GND). If it reads **~5V**, the phone sourced VBUS = it *detected the accessory* (mux likely
> live). Note it in the row.

## Matrix

### Block A — Left port, normal orientation, minimal (Titan-Pocket recipe)
CC resistors: **OUT**. VBUS: **OUT**.
- [x] A1 — RXD → **SBU1**  → result: FAIL
- [x] A2 — RXD → **SBU2**  → result: FAIL

### Block B — Left port, normal orientation, + CC resistors
Add CC resistors (both CC→5k→GND). VBUS: OUT.
- [x] B1 — RXD → **SBU1**  → result: FAIL   (VBUS pad reads: _0_ V between VBUS & GND on the breakout)
- [x] B2 — RXD → **SBU2**  → result: FAIL

### Block C — Left port, FLIPPED orientation, + CC resistors
**Flip the Thunderbolt cable's plug 180°** (either end). CC resistors: IN. VBUS: OUT.
- [x] C1 — RXD → **SBU1**  → result: FAIL
- [x] C2 — RXD → **SBU2**  → result: FAIL

### Block D — Left port, normal orientation, + CC resistors + VBUS
Un-flip. CC resistors: IN. **Add VBUS** (adapter 5V → breakout VBUS).
- [x] D1 — RXD → **SBU1**  → result: FAIL (watch FTDI LED for brownout: NO BROWNOUT OBSERVED)
- [x] D2 — RXD → **SBU2**  → result: FAIL

### Block E — RIGHT port, normal orientation, + CC resistors
**Move cable to the RIGHT USB-C port.** CC resistors: IN. VBUS: OUT.
- [x] E1 — RXD → **SBU1**  → result: FAIL
- [x] E2 — RXD → **SBU2**  → result: FAIL

### Block F — Fallback: data pins (in case UART is on D+/D- after all)
Left port, normal orientation, CC resistors: IN. VBUS: OUT.
- [x] F1 — RXD → **D+**  → result: FAIL
- [x] F2 — RXD → **D-**  → result: FAIL

---

## Notes / observations
(Write anything odd here — brownouts, partial bytes, VBUS-pad readings, etc.)

-
