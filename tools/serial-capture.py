#!/usr/bin/env python3
"""Serial capture for the Cosmo bring-up (macOS).

macOS resets a cu.* port to 9600 when the last handle closes, so `stty -f` +
`cat` does NOT hold a custom baud. This opens the port, applies an arbitrary
baud via the Darwin IOSSIOSPEED ioctl, and streams bytes to a log with
per-line wall-clock timestamps so we can see LK->kernel timing.

Usage:
  tools/serial-capture.py [/dev/cu.usbserial-XXXX] [baud] [logfile]
Defaults: /dev/cu.usbserial-0001  921600  ./serial.log
Stop with Ctrl-C (or kill the backgrounded process).
"""
import os, sys, termios, fcntl, struct, time, select, errno

dev  = sys.argv[1] if len(sys.argv) > 1 else "/dev/cu.usbserial-0001"
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 921600
log  = sys.argv[3] if len(sys.argv) > 3 else "serial.log"

# Darwin: _IOW('T', 2, speed_t). speed_t is 4 bytes here; 0x80045402 is the
# value pyserial uses on macOS for arbitrary baud.
IOSSIOSPEED = 0x80045402


def open_port():
    fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    # Raw 8N1, no flow control, no echo.
    attrs = termios.tcgetattr(fd)
    iflag, oflag, cflag, lflag, ispeed, ospeed, cc = attrs
    iflag = 0
    oflag = 0
    cflag = (cflag | termios.CLOCAL | termios.CREAD | termios.CS8) & ~(
        termios.PARENB | termios.CSTOPB | termios.CSIZE) | termios.CS8
    lflag = 0
    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, [iflag, oflag, cflag, lflag, ispeed, ospeed, cc])
    fcntl.ioctl(fd, IOSSIOSPEED, struct.pack("I", baud))  # arbitrary baud
    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, flags & ~os.O_NONBLOCK)
    return fd


# Auto-reconnect loop: if the adapter briefly drops (e.g. a VBUS brownout),
# reopen the port when it reappears instead of dying and losing the session.
out = open(log, "ab", buffering=0)
line = bytearray()
sys.stderr.write(f"[capture] {dev} @ {baud} 8N1 -> {log} (auto-reconnect)\n")
sys.stderr.flush()
try:
    while True:
        try:
            fd = open_port()
        except OSError:
            time.sleep(0.5)  # device not present yet; wait and retry
            continue
        try:
            while True:
                r, _, _ = select.select([fd], [], [], 1.0)
                if fd in r:
                    try:
                        data = os.read(fd, 4096)
                    except OSError as e:
                        if e.errno in (errno.ENXIO, errno.EIO, errno.EBADF):
                            break  # device vanished -> reopen
                        raise
                    if not data:
                        continue
                    for b in data:
                        if b == 0x0A:  # newline: stamp the completed line
                            ts = time.strftime("%H:%M:%S")
                            out.write(f"[{ts}] ".encode() + bytes(line) + b"\n")
                            line = bytearray()
                        elif b != 0x0D:
                            line.append(b)
        finally:
            try:
                os.close(fd)
            except OSError:
                pass
except KeyboardInterrupt:
    pass
finally:
    out.close()
