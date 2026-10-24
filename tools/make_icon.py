"""App icon: off-white lowercase e whose tail tip dissolves into a sine-wave
gradient from Echo Blue (#007AFF) to Echo Violet (#AF52DE).
Usage: python3 make_icon.py <out.png>"""
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

S = 1024
N = S * 2
BLUE = np.array([0x00, 0x7A, 0xFF]) / 255
VIOLET = np.array([0xAF, 0x52, 0xDE]) / 255
OFF = np.array([0xF2, 0xF2, 0xF7]) / 255

font = ImageFont.truetype("/usr/share/fonts/opentype/inter/InterDisplay-SemiBold.otf", int(N * 0.66))
mask = Image.new("L", (N, N), 0)
d = ImageDraw.Draw(mask)
bb = d.textbbox((0, 0), "e", font=font)
w, h = bb[2] - bb[0], bb[3] - bb[1]
ox, oy = N * 0.40 - w / 2 - bb[0], N * 0.52 - h / 2 - bb[1]
d.text((ox, oy), "e", font=font, fill=255)
m = np.asarray(mask, np.float32) / 255

# Tail terminal: the lowest run of ink in a column just inside the glyph's
# right edge (the crossbar end is the run above it).
cols = np.nonzero(m.max(axis=0) > 0.5)[0]
probe = cols.max() - int(N * 0.008)
col = m[:, probe] > 0.5
runs, start = [], None
for y, v in enumerate(col):
    if v and start is None:
        start = y
    if not v and start is not None:
        runs.append((start, y)); start = None
tail_top, tail_bot = runs[-1]
tip_x = cols.max()
tip_y = (tail_top + tail_bot) / 2

# Fade the very tip of the tail so the letter "dissolves" into the wave.
yy, xx = np.mgrid[0:N, 0:N].astype(np.float32)
band = np.clip((yy - (tail_top - N * 0.004)) / (N * 0.008), 0, 1) * np.clip(((tail_bot + N * 0.01) - yy) / (N * 0.008), 0, 1)
fade = np.clip((xx - (tip_x - N * 0.07)) / (N * 0.07), 0, 1) ** 1.3 * band
m_letter = m * (1 - fade * 0.9)

out = np.zeros((N, N, 3), np.float32)
ribbon = np.zeros((N, N, 3), np.float32)
img = Image.new("RGB", (N, N))
dr = ImageDraw.Draw(img)
x0, x1 = tip_x - N * 0.03, N * 0.97
strands = 24
for k in range(strands):
    f = k / (strands - 1)
    pts = []
    for x in np.linspace(x0, x1, 260):
        t = (x - x0) / (x1 - x0)
        spread = t ** 1.2
        amp = N * 0.075 * (0.35 + spread) * (0.5 + f)
        y = tip_y - amp * np.sin(t * np.pi * 1.7) - t * N * 0.10 + (f - 0.5) * N * 0.10 * spread
        pts.append((x, y))
    for i in range(len(pts) - 1):
        t = i / (len(pts) - 1)
        c = BLUE * (1 - t) + VIOLET * t
        if t < 0.08:
            c = OFF * (1 - t / 0.08) + BLUE * (t / 0.08)
        alpha = min(1, t * 10 + 0.4) * (1 - 0.45 * t) * (1 - abs(f - 0.5) * 1.1)
        col = tuple(int(v * 255 * max(alpha, 0)) for v in c)
        dr.line([pts[i], pts[i + 1]], fill=col, width=5)
r = np.asarray(img, np.float32) / 255
g = np.asarray(img.filter(ImageFilter.GaussianBlur(30)), np.float32) / 255
out += r + g * 1.4
halo = np.asarray(mask.filter(ImageFilter.GaussianBlur(50)), np.float32)[..., None] / 255
out += halo * BLUE * 0.18
ml = m_letter[..., None]
out = out * (1 - ml) + OFF * ml
Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8)).resize((S, S), Image.LANCZOS).save(sys.argv[1])
