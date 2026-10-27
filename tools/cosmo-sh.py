"""Run shell commands on the Cosmo's USB serial gadget shell and print the output.
usage: sercmd.py <tty> <timeout_s> <cmd> [cmd...]"""
import os, sys, termios, time, select
dev, tmo, cmds = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
a = termios.tcgetattr(fd)
a[0] = 0; a[1] = 0; a[3] = 0; a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
a[4] = a[5] = termios.B115200
termios.tcsetattr(fd, termios.TCSANOW, a)
def rd(t, until=None):
    buf = b''; end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try: buf += os.read(fd, 65536)
            except BlockingIOError: pass
            if until and until in buf: break
    return buf
os.write(fd, b'\n'); rd(1.0)
for i, c in enumerate(cmds):
    mark = ('__END%d__' % i).encode()
    os.write(fd, c.encode() + b'; echo __EN""D%d__\n' % i)
    out = rd(tmo, mark).decode('utf-8', 'replace').replace('\r', '')
    lines = [l for l in out.split('\n') if '__EN' not in l]
    print('$ ' + c); print('\n'.join(lines).strip()); print()
os.close(fd)
