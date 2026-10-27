#!/bin/sh
# PENNYOS debug initramfs (busybox). Goal: get a live shell over USB with no
# serial hardware, since mainline boots blind (no early display by design).
#
# The legacy g_serial gadget (USB_G_SERIAL=y, builtin) auto-binds to the MTU3 UDC
# and creates /dev/ttyGS0, enumerating on the host as a CDC-ACM /dev/cu.usbmodem*.
# We mount the basics, print status to the kernel log, and respawn an interactive
# shell on /dev/ttyGS0 (and on /dev/console as a fallback for the UART path).
BB=/bin/busybox

$BB mount -t proc     proc     /proc    2>/dev/null
$BB mount -t sysfs    sysfs    /sys     2>/dev/null
$BB mount -t devtmpfs devtmpfs /dev     2>/dev/null
$BB mkdir -p /dev/pts
$BB mount -t devpts   devpts   /dev/pts 2>/dev/null
$BB mount -t debugfs  debugfs  /sys/kernel/debug 2>/dev/null

banner() {
  echo "$1" > /dev/kmsg 2>/dev/null
  echo "$1" > /dev/console 2>/dev/null
}
banner ""
banner "======================================================"
banner "  PENNYOS debug initramfs: userspace reached (busybox)"
banner "  Shell will be offered on /dev/ttyGS0 (USB CDC-ACM)."
banner "  Host: screen /dev/cu.usbmodem* 115200"
banner "======================================================"

# Everything we print to /dev/kmsg lands in the pstore console zone, which rooted
# Android can read back after a WARM reset (tools/read-lastboot.sh). So dump the
# facts we would otherwise need a shell for.
kdump() {  # kdump <label> <cmd...>
  label="$1"; shift
  "$@" 2>&1 | while IFS= read -r l; do echo "pennyos[$label]: $l" > /dev/kmsg; done
}
kdump cmdline  $BB cat /proc/cmdline
kdump dtargs   $BB cat /proc/device-tree/chosen/bootargs
kdump mem      $BB head -3 /proc/meminfo
kdump fb       $BB ls /sys/class/graphics
kdump udc      $BB ls /sys/class/udc
kdump mmc      $BB ls /sys/class/mmc_host /sys/block
kdump deferred $BB cat /sys/kernel/debug/devices_deferred

# Persistent log that survives a COLD reset: write dmesg into our own boot slot
# (DEBIAN_KDE, 32 MiB; the image uses the first ~10 MiB) at 24 MiB + N MiB, one
# 1 MiB record per checkpoint. Read back from Android with tools/read-slotlog.sh.
# Only ever writes to the partition whose GPT name is exactly DEBIAN_KDE.
SLOTDEV=
find_slot() {
  for u in /sys/class/block/mmcblk*p*/uevent; do
    [ -f "$u" ] || continue
    if $BB grep -q '^PARTNAME=DEBIAN_KDE$' "$u"; then
      SLOTDEV=/dev/$($BB basename "$($BB dirname "$u")"); return 0
    fi
  done
  return 1
}
SAVED=0
save_log() {  # save_log <checkpoint 0..7>
  [ -n "$SLOTDEV" ] || find_slot || return 1
  # via a file, not a pipe: dd would take one short read() from a pipe and pad the rest
  { echo "PENNYOS-LOG checkpoint $1 uptime $($BB cut -d' ' -f1 /proc/uptime)"; $BB dmesg; } > /log.txt
  $BB dd if=/log.txt of="$SLOTDEV" bs=1048576 seek=$((24 + $1)) count=1 conv=sync 2>/dev/null || return 1
  $BB sync
  SAVED=1
  banner "pennyos: log checkpoint $1 saved to $SLOTDEV @ $((24 + $1)) MiB"
}
i=0
while ! find_slot && [ "$i" -lt 50 ]; do $BB sleep 0.2; i=$((i+1)); done
[ -n "$SLOTDEV" ] && banner "pennyos: log slot is $SLOTDEV" || banner "pennyos: WARNING no DEBIAN_KDE partition visible (eMMC not up?)"
save_log 0

# Wait up to ~10s for the USB gadget tty to be created by g_serial.
i=0
while [ ! -e /dev/ttyGS0 ] && [ "$i" -lt 100 ]; do $BB sleep 0.1; i=$((i+1)); done
if [ -e /dev/ttyGS0 ]; then
  banner "pennyos: /dev/ttyGS0 present after ${i} x100ms -> spawning shell"
else
  banner "pennyos: WARNING /dev/ttyGS0 NEVER appeared (MTU3/gadget did not come up)"
fi
save_log 1

# Report whether a USB host configures the gadget. Which USB-C port carries USB2
# data is chosen by GPIO79 (vendor "usb_lr_sw"); the board DTS drives it low, which
# its author labels the LEFT port - so plug the cable in there.
udc_state() { $BB cat /sys/class/udc/*/state 2>/dev/null; }
n=0
while [ "$(udc_state)" != "configured" ] && [ "$n" -lt 10 ]; do $BB sleep 1; n=$((n+1)); done
banner "pennyos: udc state after ${n}s: '$(udc_state)'"

# Hardware watchdog. LK hands over with it disarmed; our kernel patch arms it at
# probe and the kernel feeds it until someone opens /dev/watchdog. Open it and feed
# it ourselves, so that simply *stopping* gives a reset no software path can block.
FEEDER=
if [ -c /dev/watchdog ]; then
  exec 9>/dev/watchdog
  ( while :; do echo -n . >&9; $BB sleep 5; done ) &
  FEEDER=$!
  banner "pennyos: feeding /dev/watchdog (pid $FEEDER)"
else
  banner "pennyos: WARNING no /dev/watchdog (mtk_wdt did not probe)"
fi

# Dead-man switch. If no USB host has configured the gadget after $DEADMAN
# seconds we are deaf and mute. Save the log to eMMC and stay up; if that fails, reset: first by starving the watchdog, then
# `reboot -f` as a fallback. Both are warm resets, the only kind that preserves the
# pstore log (holding ESC/power is cold and wipes it).
# Pass pennyos.stay on the cmdline to disable.
DEADMAN=30
if ! $BB grep -q pennyos.stay /proc/cmdline; then
  (
    $BB sleep "$DEADMAN"
    if [ "$(udc_state)" != "configured" ]; then
      banner "pennyos: no USB host after ${DEADMAN}s (udc state: '$(udc_state)')"
      kdump deferred $BB cat /sys/kernel/debug/devices_deferred
      kdump udc      $BB ls /sys/class/udc
      if save_log 2; then
        banner "pennyos: LOG SAVED - safe to power off now (hold ESC)."
        banner "pennyos: then boot Rooted Android and run tools/read-slotlog.sh"
        exit 0
      fi
      banner "pennyos: could not save the log to eMMC; falling back to a warm reset"
      banner "pennyos: then boot Android and run tools/read-lastboot.sh"
      $BB sync
      if [ -n "$FEEDER" ]; then
        banner "pennyos: starving the watchdog -> hardware reset within ~31s"
        kill "$FEEDER"
        $BB sleep 45
        banner "pennyos: STILL ALIVE 45s after starving the watchdog (it did not bite)"
      fi
      banner "pennyos: reboot -f"
      $BB reboot -f
      $BB sleep 10
      banner "pennyos: STILL ALIVE after reboot -f; trying sysrq-b"
      echo b > /proc/sysrq-trigger
    else
      banner "pennyos: USB host connected; dead-man switch disarmed"
    fi
  ) &
fi

# A shell on the console too (works if a real UART console is attached).
$BB setsid $BB sh -c "exec $BB sh </dev/console >/dev/console 2>&1" &

# Respawn an interactive shell on the USB gadget serial forever.
while true; do
  if [ -e /dev/ttyGS0 ]; then
    $BB setsid $BB sh -c "exec $BB sh </dev/ttyGS0 >/dev/ttyGS0 2>&1"
  fi
  $BB sleep 1
done
