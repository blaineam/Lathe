#!/bin/bash
#
# Draws the app icon and writes an .icns.
#
# **A placeholder with a deliberate shape, not a design.** The mark is a lathe
# seen end-on: concentric rings turned down to a centre, which is what the
# library does to a file. It is drawn in code so there is no binary asset in the
# repository and no dependency on a design tool, and so it can be replaced by a
# real one without anything else changing.
set -euo pipefail
OUT="${1:-AppIcon.icns}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

draw() {
    local size="$1" path="$2"
    python3 - "$size" "$path" <<'PY'
import sys, math, zlib, struct

size, path = int(sys.argv[1]), sys.argv[2]
px = bytearray(size * size * 4)

def put(x, y, r, g, b, a=255):
    if 0 <= x < size and 0 <= y < size:
        i = (y * size + x) * 4
        # Source-over, so the rings blend rather than punching holes.
        ia = a / 255.0
        px[i]   = int(px[i]   * (1 - ia) + r * ia)
        px[i+1] = int(px[i+1] * (1 - ia) + g * ia)
        px[i+2] = int(px[i+2] * (1 - ia) + b * ia)
        px[i+3] = max(px[i+3], a)

centre = (size - 1) / 2.0
radius = size * 0.46
corner = size * 0.22

for y in range(size):
    for x in range(size):
        dx, dy = x - centre, y - centre
        # A squircle-ish rounded square for the ground, so it sits correctly
        # beside other macOS icons rather than as a bare circle.
        k = 4.0
        nx, ny = abs(dx) / (size * 0.46), abs(dy) / (size * 0.46)
        if (nx ** k + ny ** k) <= 1.0:
            t = (y / size)
            put(x, y, int(24 + 22 * t), int(26 + 26 * t), int(34 + 36 * t))

for y in range(size):
    for x in range(size):
        dx, dy = x - centre, y - centre
        d = math.hypot(dx, dy)
        if d > radius * 0.82:
            continue
        # Concentric turned rings, brightest toward the centre.
        ring = (d / (radius * 0.82)) * 5.0
        frac = abs(ring - round(ring))
        if frac < 0.17:
            glow = 1.0 - (d / (radius * 0.82)) * 0.55
            alpha = int(255 * (1 - frac / 0.17) * glow)
            put(x, y, 255, 184, 92, alpha)

# The centre the work is turned down to.
for y in range(size):
    for x in range(size):
        if math.hypot(x - centre, y - centre) <= max(1.0, size * 0.045):
            put(x, y, 255, 236, 205, 255)

raw = b"".join(b"\x00" + bytes(px[r*size*4:(r+1)*size*4]) for r in range(size))
def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))
png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw, 9))
       + chunk(b"IEND", b""))
open(path, "wb").write(png)
PY
}

for size in 16 32 64 128 256 512; do
    draw "$size" "$ICONSET/icon_${size}x${size}.png"
    draw "$((size * 2))" "$ICONSET/icon_${size}x${size}@2x.png"
done

iconutil -c icns "$ICONSET" -o "$OUT"
echo "    icon: $OUT"
