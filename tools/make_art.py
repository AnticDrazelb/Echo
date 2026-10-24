"""Generates the bundled sample scene (the app icon lives in make_icon.py)."""
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

OUT = sys.argv[1]
S = 1024


def lerp(a, b, t):
    return a + (b - a) * t


def scene():
    W, H = 1200, 1600
    rng = np.random.default_rng(7)
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    v, u = yy / H, xx / W
    img = np.zeros((H, W, 3), np.float32)

    horizon = 0.58
    # Sky: soft blue to warm haze at horizon.
    t = np.clip(v / horizon, 0, 1)[..., None]
    sky = (1 - t) * np.array([0.36, 0.55, 0.82]) + t * np.array([0.93, 0.82, 0.68])
    sun = np.exp(-(((u - 0.68) ** 2) + ((v - 0.40) * 1.1) ** 2) / 0.004)[..., None]
    halo = np.exp(-(((u - 0.68) ** 2) + ((v - 0.40)) ** 2) / 0.05)[..., None]
    sky = sky + sun * np.array([1.0, 0.95, 0.85]) * 0.9 + halo * np.array([0.35, 0.22, 0.10])
    # Clouds.
    cl = np.zeros((H, W), np.float32)
    for _ in range(14):
        cx, cy, sx, sy = rng.uniform(0, 1), rng.uniform(0.08, 0.42), rng.uniform(0.08, 0.25), rng.uniform(0.012, 0.03)
        cl += np.exp(-(((u - cx) / sx) ** 2 + ((v - cy) / sy) ** 2)) * rng.uniform(0.2, 0.5)
    sky = sky * (1 - np.clip(cl, 0, 0.7)[..., None] * 0.3) + np.clip(cl, 0, 1)[..., None] * np.array([0.95, 0.93, 0.92]) * 0.35
    img[:] = sky

    def ridge(base, amp, freqs, seed):
        r = np.random.default_rng(seed)
        x = np.linspace(0, 1, W)
        y = np.full(W, base)
        for f in freqs:
            y += amp / f * np.sin(2 * np.pi * (f * x + r.uniform(0, 1))) * r.uniform(0.5, 1)
        return y

    layers = [
        (0.47, 0.06, [1.3, 2.7, 5.1, 11], np.array([0.55, 0.60, 0.72]), 11),
        (0.52, 0.07, [1.1, 3.3, 7.0, 15], np.array([0.38, 0.45, 0.55]), 12),
        (0.57, 0.05, [2.0, 4.1, 9.0, 21], np.array([0.22, 0.30, 0.30]), 13),
    ]
    for base, amp, freqs, col, seed in layers:
        top = ridge(base, amp, freqs, seed)
        m = (v > top[None, :]).astype(np.float32)
        shade = col * (0.9 + 0.2 * (1 - (v - base) * 3)[..., None].clip(0, 1))
        img = img * (1 - m[..., None]) + shade * m[..., None]

    # Lake with reflection of the sky.
    lake_top, lake_bot = 0.60, 0.74
    lm = ((v > lake_top) & (v < lake_bot)).astype(np.float32)[..., None]
    mirror = np.clip(2 * lake_top - v, 0, 1)
    ref = img[(mirror * (H - 1)).astype(int), xx.astype(int)]
    ripple = 0.03 * np.sin(yy * 0.9 + np.sin(xx * 0.02) * 3)[..., None]
    lake = ref * 0.75 + np.array([0.05, 0.08, 0.10]) + ripple
    img = img * (1 - lm) + lake * lm

    # Foreground meadow.
    fg_top = lake_bot + 0.015 * np.sin(u * 9)
    fm = (v > fg_top).astype(np.float32)[..., None]
    grad = np.clip((v - lake_bot) / (1 - lake_bot), 0, 1)[..., None]
    meadow = (1 - grad) * np.array([0.52, 0.55, 0.25]) + grad * np.array([0.18, 0.22, 0.10])
    blades = rng.normal(0, 1, (H, W)).astype(np.float32)
    blades = np.asarray(Image.fromarray(((blades * 0.5 + 0.5).clip(0, 1) * 255).astype(np.uint8)).resize((W // 2, H // 8)).resize((W, H), Image.BICUBIC), np.float32) / 255
    meadow = meadow * (0.75 + 0.5 * blades[..., None])
    wild = rng.uniform(0, 1, (H, W)) > 0.9994
    flowers = np.asarray(Image.fromarray((wild * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(7)).filter(ImageFilter.GaussianBlur(1.2)), np.float32)[..., None] / 255
    meadow = meadow * (1 - flowers * fm) + flowers * np.array([0.95, 0.80, 0.35])
    img = img * (1 - fm) + meadow * fm

    # Subtle sensor noise + gentle vignette so it reads as a photo.
    img += rng.normal(0, 0.008, img.shape).astype(np.float32)
    vig = 1 - 0.18 * (((u - 0.5) ** 2 + (v - 0.5) ** 2) / 0.5)[..., None]
    img *= vig
    out = Image.fromarray((np.clip(img, 0, 1) ** (1 / 1.05) * 255).astype(np.uint8))
    out = out.filter(ImageFilter.GaussianBlur(0.6))
    out.save(f"{OUT}/SampleScene.jpg", quality=88)


scene()
