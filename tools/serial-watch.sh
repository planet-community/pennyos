#!/bin/sh
# Live watcher for the Cosmo serial capture log. Clears the log, then shows a
# growing byte counter and prints any new bytes as they arrive (non-printables
# shown via `cat -v` so garbage won't corrupt the terminal).
#
# Run this ONCE PER CONFIG: start it, cold-boot the Cosmo, watch for ~40s.
#   - counter stays 0  -> nothing arriving (dead pin/cable/trigger)
#   - counter grows + readable text -> WIN
#   - counter grows + garbage       -> right pin, wrong baud/level
# Ctrl-C to stop; re-run for the next config (it re-clears the log).
#
# The background capture process (tools/serial-capture.py) must be running and
# holding the FTDI port; this script only tails the file it writes.
LOG="${1:-serial.log}"   # where tools/serial-capture.py writes by default
: > "$LOG"
echo "=== watching (cleared): $LOG ==="
echo "=== cold-boot the Cosmo now. Ctrl-C to stop. ==="
last=0
while true; do
  n=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  if [ "$n" -gt "$last" ]; then
    printf '\n[%s] %d bytes ---\n' "$(date +%T)" "$n"
    tail -c "$((n - last))" "$LOG" | cat -v
    last=$n
  else
    printf '\r[%s] %d bytes' "$(date +%T)" "$n"
  fi
  sleep 1
done
