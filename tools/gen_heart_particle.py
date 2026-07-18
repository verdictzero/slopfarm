#!/usr/bin/env python3
"""Bake sprites/heart_particle.png — a soft white heart on transparent, tinted per-use by the
particle material's colour ramp. Run from the project root:  python3 tools/gen_heart_particle.py"""
import numpy as np
from PIL import Image, ImageFilter

N = 64
ys, xs = np.mgrid[0:N, 0:N]
x = (xs - N / 2) / (N * 0.42)
y = (N * 0.56 - ys) / (N * 0.42)
f = (x * x + y * y - 1.0) ** 3 - x * x * (y ** 3)
mask = Image.fromarray(((f <= 0.0).astype(np.uint8) * 255), "L").filter(ImageFilter.GaussianBlur(1.2))
heart = Image.new("RGBA", (N, N), (255, 255, 255, 255))
heart.putalpha(mask)
heart.save("sprites/heart_particle.png")
print("wrote sprites/heart_particle.png", heart.size)
