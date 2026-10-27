#!/usr/bin/env python3
"""Generate the default PennyOS wallpaper (2160x1080, Tokyo Night palette).

An original, procedurally drawn image - a planet limb with a thin atmosphere over a
sparse starfield - so it can ship in the repo without licensing questions. Kept dark
and low-contrast behind windows; the brightest area sits in the lower right, away from
the bar. Deterministic (fixed seed). Needs Pillow + numpy.

Usage: make-wallpaper.py out.png
"""
import sys
import numpy as np
from PIL import Image, ImageFilter

W, H = 2160, 1080
rng = np.random.default_rng(7)

def rgb(h):
    return np.array([int(h[i:i + 2], 16) for i in (1, 3, 5)], dtype=np.float32)

BG_TOP, BG_BOT = rgb('#16161e'), rgb('#1a1b26')
BLUE, CYAN, MAGENTA, ORANGE = rgb('#7aa2f7'), rgb('#7dcfff'), rgb('#bb9af7'), rgb('#ff9e64')

yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
img = BG_TOP + (BG_BOT - BG_TOP) * (yy / H)[..., None]

# faint nebula: two wide, soft colour clouds
for (cx, cy, r, col, a) in ((W * 0.22, H * 0.30, 620, MAGENTA, 0.10), (W * 0.62, H * 0.12, 520, BLUE, 0.08)):
    d = np.sqrt((xx - cx) ** 2 + ((yy - cy) * 1.5) ** 2) / r
    img += (col - img) * (np.clip(1 - d, 0, 1) ** 2 * a)[..., None]

# stars: sparse, mostly dim, a few brighter ones with a tint
stars = np.zeros((H, W, 3), dtype=np.float32)
n = 900
sx, sy = rng.integers(0, W, n), rng.integers(0, H, n)
b = rng.random(n) ** 4
tint = np.where(rng.random(n)[:, None] < 0.15, CYAN, np.array([220, 225, 245], dtype=np.float32))
stars[sy, sx] = tint * (0.25 + 0.75 * b)[:, None]
glow = np.asarray(Image.fromarray(stars.clip(0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.6)), dtype=np.float32)
img = np.clip(img + stars * 0.9 + glow * 1.6, 0, 255)

# planet: a large disc rising from the lower right, lit from the upper left
pcx, pcy, pr = W * 0.80, H * 1.62, H * 1.02
d = np.sqrt((xx - pcx) ** 2 + (yy - pcy) ** 2)
inside = np.clip((pr - d) / 2.0, 0, 1)                       # anti-aliased disc mask
depth = np.clip((pr - d) / pr, 0, 1)                         # 0 at the limb
lx = (xx - pcx) / pr * -0.55 + (yy - pcy) / pr * -0.83       # light direction
lit = np.clip(lx, 0, 1)
surface = rgb('#11121a') + (rgb('#24283b') - rgb('#11121a')) * (lit ** 1.5)[..., None]
bands = (np.sin(d / 23.0) * 0.5 + 0.5) * 0.035 * lit         # barely visible banding
surface += (BLUE - surface) * bands[..., None]
img = img * (1 - inside[..., None]) + surface * inside[..., None]

# atmosphere: thin bright rim on the lit side, soft glow outside the limb
rim = np.exp(-((d - pr) / 3.0) ** 2) * np.clip(lit * 1.6, 0, 1)
img += (CYAN - img) * np.clip(rim * 0.85, 0, 1)[..., None]
halo = np.exp(-np.clip(d - pr, 0, None) / 55.0) * (d >= pr) * np.clip(lit * 1.3, 0, 1)
img += (BLUE - img) * np.clip(halo * 0.35, 0, 1)[..., None]
inner = np.exp(-np.clip(pr - d, 0, None) / 38.0) * (d < pr) * np.clip(lit * 1.2, 0, 1)
img += (BLUE - img) * np.clip(inner * 0.22, 0, 1)[..., None]

# a small warm moon, for one accent of contrast
mcx, mcy, mr = W * 0.335, H * 0.36, 17
dm = np.sqrt((xx - mcx) ** 2 + (yy - mcy) ** 2)
mm = np.clip((mr - dm) / 1.5, 0, 1)
mlit = np.clip(((xx - mcx) * -0.6 + (yy - mcy) * -0.8) / mr * 0.5 + 0.55, 0.12, 1)
img = img * (1 - mm[..., None]) + (ORANGE * mlit[..., None] * 0.9) * mm[..., None]

# light dithering so the gradients do not band on the panel
img += rng.normal(0, 0.9, img.shape)
Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).save(sys.argv[1], optimize=True)
