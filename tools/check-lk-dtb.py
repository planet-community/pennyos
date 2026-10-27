#!/usr/bin/env python3
"""Offline check: will the Cosmo's MediaTek LK accept this DTB?

Replays what LK does to the DTB appended to the kernel (see
research/lk-dtb-requirements.md) using the host's dtc tools:
  1. apply the vendor dtbo overlay (LK asserts if this fails)
  2. /chosen/bootargs present (assert), "mediatek,scp" node present (assert)
  3. no static /reserved-memory child overlaps an LK mblock reservation (while(1))
  4. /memory, /chosen, /reserved-memory present; merged size <= 512 KiB

Usage: check-lk-dtb.py <base.dtb> [overlay.dtbo] [vendor live.dts]
"""
import glob, os, re, struct, subprocess, sys, tempfile


repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
tmp = tempfile.mkdtemp()

def first_overlay(img):
    """Entry 0 of an Android DTBO table image (the dtbo partition), as a file."""
    with open(img, 'rb') as f:
        data = f.read()
    if data[:4] != b'\xd7\xb7\xab\x1e':
        return img  # already a plain overlay
    entries_offset = struct.unpack('>I', data[20:24])[0]
    size, offset = struct.unpack('>II', data[entries_offset:entries_offset + 8])
    out = tmp + '/overlay0.dtbo'
    with open(out, 'wb') as f:
        f.write(data[offset:offset + size])
    return out

def default_dtbo():
    # the phone's dtbo partition, backed up as in research/rooting.md
    for p in ('overlay0.dtbo', 'dtbo.img'):
        if os.path.exists(repo + '/collected/boot-backup/' + p):
            return repo + '/collected/boot-backup/' + p
    sys.exit('no vendor dtbo: back up the phone\'s dtbo partition to collected/boot-backup/dtbo.img (research/rooting.md)')

def default_live():
    # the newest live device tree captured by tools/android-recon.sh (run with root)
    found = sorted(glob.glob(repo + '/collected/device-dumps/*/*live.dts') +
                   glob.glob(repo + '/collected/device-dumps/*/*live.dtb'), key=os.path.getmtime)
    if not found:
        sys.exit('no vendor live device tree: run tools/android-recon.sh from rooted Android first')
    if found[-1].endswith('.dtb'):
        out = tmp + '/live.dts'
        subprocess.run(['dtc', '-I', 'dtb', '-O', 'dts', '-q', '-o', out, found[-1]], check=True)
        return out
    return found[-1]

dtb = sys.argv[1]
dtbo = first_overlay(sys.argv[2] if len(sys.argv) > 2 else default_dtbo())
live = sys.argv[3] if len(sys.argv) > 3 else default_live()
ok = True
def res(cond, msg):
    global ok
    print(('  ok   ' if cond else '  FAIL ') + msg)
    ok = ok and cond

merged = tmp + '/merged.dtb'
r = subprocess.run(['fdtoverlay', '-i', dtb, '-o', merged, dtbo], capture_output=True, text=True)
res(r.returncode == 0, 'vendor dtbo overlay applies' + ('' if r.returncode == 0 else ': ' + r.stderr.strip()))
if r.returncode != 0:
    sys.exit(1)
size = os.path.getsize(merged)
res(size <= 0x80000, 'merged size %d <= 524288 (DTB_MAX_SIZE)' % size)
dts = subprocess.run(['dtc', '-I', 'dtb', '-O', 'dts', '-q', merged], capture_output=True, text=True).stdout

def get(path, prop=None):
    a = ['fdtget', merged, path] + ([prop] if prop else ['-l'])
    r = subprocess.run(a, capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None

res(get('/chosen', 'bootargs') is not None, '/chosen/bootargs exists')
res(get('/memory') is not None or get('/memory@40000000') is not None, '/memory exists')
res('compatible = "mediatek,scp"' in dts, 'node with compatible "mediatek,scp" exists')
res(get('/reserved-memory') is not None, '/reserved-memory exists')
res(get('/odm/led@6', 'compatible') is not None, '/odm/led@6 (LK backlight config) present after overlay')
res(get('/gpio@10005000', 'gpio_init_default') is not None, '/gpio@10005000 gpio_init_default present after overlay')
if get('/reserved-memory/zmc-default') is not None:
    print('  note /reserved-memory/zmc-default present: LK will add a ~4 GiB zone-movable-cma-memory node (fine for the vendor kernel, wastes RAM on mainline)')

# LK's own reservations, as appended to the vendor kernel's live tree (mblock-N-*)
mblocks = []
for m in re.finditer(r'(mblock-\d+-[\w-]+) \{\s*reg = <0x([0-9a-f]+) 0x([0-9a-f]+) 0x([0-9a-f]+) 0x([0-9a-f]+)>', open(live).read()):
    s = (int(m.group(2), 16) << 32) | int(m.group(3), 16); z = (int(m.group(4), 16) << 32) | int(m.group(5), 16)
    mblocks.append((m.group(1), s, s + z))
res(len(mblocks) > 5, 'loaded %d LK mblock reservations from vendor live tree' % len(mblocks))
for child in (get('/reserved-memory') or '').split():
    reg = get('/reserved-memory/' + child, 'reg')
    if not reg:
        continue
    v = [int(x) for x in reg.split()]
    s = (v[0] << 32) | v[1]; e = s + ((v[2] << 32) | v[3])
    hit = [n for n, ms, me in mblocks if s < me and ms < e]
    res(not hit, '/reserved-memory/%s [%#x-%#x) clear of LK mblocks%s' % (child, s, e, '' if not hit else ' -> overlaps ' + ','.join(hit)))
print('RESULT:', 'LK should accept this DTB' if ok else 'LK WILL REJECT this DTB (assert / hang -> reboot loop)')
sys.exit(0 if ok else 1)
