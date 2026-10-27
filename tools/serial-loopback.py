#!/usr/bin/env python3
"""Loopback self-test for the CP2102 capture path (macOS).

Jumper the adapter's TX0 -> RX1, then run this. It writes a marker at the
target baud and checks it reads back. Proves the port + IOSSIOSPEED baud +
read path all work, independent of the Cosmo. If this PASSES but a real boot
shows nothing, the fault is on the device side (wrong port/pin/activation),
not our capture.

Usage: tools/serial-loopback.py [/dev/cu.usbserial-XXXX] [baud]
"""
import os, sys, termios, fcntl, struct, time, select

dev  = sys.argv[1] if len(sys.argv) > 1 else "/dev/cu.usbserial-0001"
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 921600
IOSSIOSPEED = 0x80045402

fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
try:
    iflag, oflag, cflag, lflag, ispeed, ospeed, cc = termios.tcgetattr(fd)
    iflag = 0; oflag = 0; lflag = 0
    cflag = (cflag | termios.CLOCAL | termios.CREAD | termios.CS8) & ~(
        termios.PARENB | termios.CSTOPB | termios.CSIZE) | termios.CS8
    cc[termios.VMIN] = 0; cc[termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, [iflag, oflag, cflag, lflag, ispeed, ospeed, cc])
    fcntl.ioctl(fd, IOSSIOSPEED, struct.pack("I", baud))
    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, flags & ~os.O_NONBLOCK)

    # flush anything stale
    time.sleep(0.2)
    r, _, _ = select.select([fd], [], [], 0.1)
    if fd in r:
        os.read(fd, 4096)

    marker = b"COSMO_LOOPBACK_0123456789\n"
    got = bytearray()
    for attempt in range(3):
        os.write(fd, marker)
        deadline = time.time() + 0.6
        while time.time() < deadline:
            r, _, _ = select.select([fd], [], [], 0.2)
            if fd in r:
                got += os.read(fd, 4096)
                if marker.strip() in bytes(got):
                    print(f"PASS @ {baud} baud: wrote and read back the marker.")
                    print(f"  received: {bytes(got)!r}")
                    sys.exit(0)
        time.sleep(0.1)
    print(f"FAIL @ {baud} baud: marker not echoed. received={bytes(got)!r}")
    print("  -> Either TX0<->RX1 jumper is not connected, or the port/baud path is broken.")
    sys.exit(1)
finally:
    os.close(fd)
