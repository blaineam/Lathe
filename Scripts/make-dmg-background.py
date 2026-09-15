#!/usr/bin/env python3
"""Draws the disk image's background.

    Scripts/make-dmg-background.py <output.png>

Generated rather than stored, for the same reason the app icon is: a public
repository should not carry a binary it can produce in a second, and a
generated image can be adjusted without a round trip through a design tool.

The geometry is tied to `build-dmg.sh`. That script opens a 660x400 window and
puts the app at (145, 185) and the Applications alias at (515, 185); the arrow
below is drawn between those two points, and the caption sits under them. If
either moves, both files move together.
"""
import math
import pathlib
import struct
import sys
import zlib

# Points; the window build-dmg.sh asks Finder for.
W, H = 660, 400
SCALE = 2                      # drawn at 2x so it is not soft on a Retina display
APP_AT = (145, 185)
APPS_AT = (515, 185)

PX_W, PX_H = W * SCALE, H * SCALE
pixels = [[(0, 0, 0, 255)] * PX_W for _ in range(PX_H)]


def put(x, y, colour, alpha=1.0):
    if not (0 <= x < PX_W and 0 <= y < PX_H) or alpha <= 0:
        return
    r0, g0, b0, _ = pixels[y][x]
    r, g, b = colour
    pixels[y][x] = (int(r0 + (r - r0) * alpha),
                    int(g0 + (g - g0) * alpha),
                    int(b0 + (b - b0) * alpha), 255)


# The ground: the same deep indigo the icon sits on, lifting slightly toward
# the bottom so the window has a horizon rather than being a flat field.
for y in range(PX_H):
    t = y / PX_H
    row = (int(14 + 10 * t), int(16 + 12 * t), int(26 + 18 * t))
    for x in range(PX_W):
        pixels[y][x] = row + (255,)

# A wide, very soft glow behind where the app icon lands, so the eye starts
# there rather than in the middle of the window.
gx, gy = APP_AT[0] * SCALE, APP_AT[1] * SCALE
radius = 150 * SCALE
for y in range(max(0, gy - radius), min(PX_H, gy + radius)):
    for x in range(max(0, gx - radius), min(PX_W, gx + radius)):
        d = math.hypot(x - gx, y - gy) / radius
        if d < 1:
            put(x, y, (255, 162, 60), 0.055 * (1 - d) ** 2)


def dot(cx, cy, r, colour, alpha):
    for y in range(int(cy - r) - 1, int(cy + r) + 2):
        for x in range(int(cx - r) - 1, int(cx + r) + 2):
            d = r - math.hypot(x - cx, y - cy)
            if d >= 0:
                put(x, y, colour, alpha * min(1.0, d))


# The arrow: a dotted run from the app to the Applications alias, fading in
# and out so it reads as a hint rather than an instruction. Drawn below the
# icons, which sit at y=185 and are 100 points tall.
y_line = (APP_AT[1] + 78) * SCALE
x0, x1 = (APP_AT[0] + 62) * SCALE, (APPS_AT[0] - 62) * SCALE
count = 13
for i in range(count):
    t = (i + 0.5) / count
    x = x0 + (x1 - x0) * t
    # Brightest in the middle; the ends are where the icons already are.
    fade = math.sin(math.pi * t) ** 0.7
    dot(x, y_line, 2.6 * SCALE, (255, 186, 105), 0.5 * fade)

# The head, a simple triangle so nothing here needs a font.
#
# Apex on the *right*, toward Applications. The first version tapered the
# other way and pointed back at the app — which tells somebody to drag
# Applications onto Lathe, the exact opposite of the instruction.
hx = x1 + 6 * SCALE
length = int(11 * SCALE)
for i in range(length):
    reach = length - i
    for j in range(-reach, reach + 1):
        put(hx + i, y_line + j, (255, 186, 105),
            0.55 * (1 - i / length) ** 0.5)

raw = b"".join(
    b"\x00" + bytes(v for px in row for v in px)
    for row in pixels)


def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "dmg-background.png")
out.parent.mkdir(parents=True, exist_ok=True)
out.write_bytes(
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", PX_W, PX_H, 8, 6, 0, 0, 0))
    # A physical-pixel chunk so Finder renders it at 1x window size on a
    # Retina display rather than doubling it.
    + chunk(b"pHYs", struct.pack(">IIB", 2835 * SCALE, 2835 * SCALE, 1))
    + chunk(b"IDAT", zlib.compress(raw, 9))
    + chunk(b"IEND", b""))
print(f"    background: {out} ({PX_W}x{PX_H})")
