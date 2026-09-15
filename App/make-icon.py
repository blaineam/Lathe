#!/usr/bin/env python3
"""Generates App/Icon/Lathe.icon — a layered Icon Composer document.

The mark is a chip peeling off the work: a pale cylinder standing on the
left, and the ribbon of material curling away from its face, thick where
the tool severed it and thinning as it curls. It is what a lathe actually
does, and it says what the project does — something goes in, and what
comes off is smaller.

Four earlier attempts are recorded here so nobody draws them again.
Concentric rings, which is what a spinning thing looks like head-on and
reads as hypnotic in a Dock. A download arrow, the most generic mark
available, which said nothing the app's name did not. The silhouette of a
turned spindle, which was at least about lathes but rendered as a chess
pawn. And the chip on its own, which is a single open spiral and therefore
the Debian swirl — the cylinder is what makes it a different picture as
well as a truer one.

Emitted as SVG inside a .icon bundle rather than a flattened .icns because
that is what macOS 26 wants: the system owns the squircle, the glass and
the specular pass, and derives light, dark and tinted appearances from
this artwork. Drawing our own rounded background would fight all of it.
It is also entirely text, so a public repository carries no binary asset,
and the result opens in Icon Composer for anyone who wants to keep
working on it.

Verified by compiling it: `xcrun actool <bundle> --compile …` accepts the
document and emits an Assets.car, which is the only real test that this
hand-written schema is right.
"""
import json
import math
import pathlib
import sys

CANVAS = 1024.0

# A logarithmic spiral, because a chip curls at a constant rate — the
# radius falls by the same factor per turn rather than by a fixed amount,
# which is what makes the curl look like material rather than like a drawn
# volute.
TURNS = 0.93
DECAY = 0.210          # how fast the radius falls per radian
WIDTH = 0.260          # ribbon width at the widest, as a fraction of canvas
TAPER = 1.40           # how sharply the ribbon thins as it curls in

# Where the wide end points. Chosen so the chip leaves the work travelling
# horizontally: the spiral's tangent at t=0 is (-k·cos φ - sin φ,
# -k·sin φ + cos φ), so φ = atan(1/k) + π zeroes the vertical component and
# leaves it pointing along +x. Derived rather than eyeballed, because
# "where does this curve start off to" is exactly the kind of thing that
# drifts every time another parameter is touched.
PHASE = math.atan(1.0 / DECAY) + math.pi


def centreline(t):
    """Point and half-width at t along the chip, 0 at the severed end."""
    theta = t * TURNS * 2 * math.pi
    r = math.exp(-DECAY * theta)
    w = 0.5 * WIDTH * CANVAS * (r ** TAPER)
    a = theta + PHASE
    return r * CANVAS * math.cos(a), r * CANVAS * math.sin(a), w


def ribbon(samples=360):
    """Both edges of the chip, as one closed path.

    The edges are the centreline offset along its own normal, so the
    ribbon keeps an even thickness through the curl instead of pinching on
    the inside of the bend the way a naive radial offset does.
    """
    pts = [centreline(i / samples) for i in range(samples + 1)]
    outer, inner = [], []
    for i, (x, y, w) in enumerate(pts):
        after = pts[min(i + 1, samples)]
        before = pts[max(i - 1, 0)]
        dx, dy = after[0] - before[0], after[1] - before[1]
        length = math.hypot(dx, dy) or 1.0
        nx, ny = -dy / length, dx / length
        outer.append((x + nx * w, y + ny * w))
        inner.append((x - nx * w, y - ny * w))
    return outer + list(reversed(inner))


def rotate(groups, degrees):
    """Turn the whole composition off the vertical.

    Upright, a bar with a curl hanging off its side reads as a lowercase
    b — which is what the composition did before this existed. Tilting it
    breaks the letterform and, incidentally, is the angle a tool actually
    presents to the work.
    """
    a = math.radians(degrees)
    cos, sin = math.cos(a), math.sin(a)
    return [[(x * cos - y * sin, x * sin + y * cos) for x, y in g]
            for g in groups]


def bounds(*groups):
    xs = [x for g in groups for x, _ in g]
    ys = [y for g in groups for _, y in g]
    return min(xs), min(ys), max(xs), max(ys)


def fit(groups, box=0.84):
    """Centre the whole composition and scale it to fill `box` of the canvas.

    Applied to the cylinder and the chip together, after they have been
    positioned relative to each other, so their arrangement survives and
    only the framing changes. Computed rather than hand-placed: a figure
    sitting off-centre in the squircle is the kind of thing nobody can
    un-see.
    """
    x0, y0, x1, y1 = bounds(*groups)
    scale = box * CANVAS / max(x1 - x0, y1 - y0)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    return [[((x - cx) * scale + CANVAS / 2, (y - cy) * scale + CANVAS / 2)
             for x, y in g] for g in groups]


def path(points, close=True):
    head = f"M {points[0][0]:.2f} {points[0][1]:.2f}"
    rest = " ".join(f"L {x:.2f} {y:.2f}" for x, y in points[1:])
    return f"{head} {rest}{' Z' if close else ''}"


def capsule(x0, y0, x1, y1, samples=48):
    """A vertical bar with semicircular ends, as a point list.

    Walked as one continuous loop — left edge up, over the top cap, right
    edge down, under the bottom cap — because a point list assembled out of
    two independently-ordered arcs crosses itself in the middle and fills
    as a bowtie.

    A point list rather than a `<rect rx>` so it goes through the same
    fitting transform as the chip: one code path for placing both, and no
    chance of the two drifting apart.
    """
    r = (x1 - x0) / 2
    cx = (x0 + x1) / 2
    top, bottom = y0 + r, y1 - r
    pts = [(x0, bottom), (x0, top)]
    for i in range(samples + 1):                      # over the top
        a = math.pi + math.pi * i / samples
        pts.append((cx + r * math.cos(a), top + r * math.sin(a)))
    pts.append((x1, bottom))
    for i in range(samples + 1):                      # under the bottom
        a = math.pi * i / samples
        pts.append((cx + r * math.cos(a), bottom + r * math.sin(a)))
    return pts


def main(root):
    assets = root / "Lathe.icon" / "Assets"
    assets.mkdir(parents=True, exist_ok=True)

    chip = ribbon()
    start = centreline(0.0)

    # Scale the chip to a fixed size first, then hang it off the cylinder's
    # face. Doing it in this order means the contact point stays put when
    # the spiral parameters are tuned.
    x0, y0, x1, y1 = bounds(chip)
    scale = 0.70 * CANVAS / max(x1 - x0, y1 - y0)
    chip = [(x * scale, y * scale) for x, y in chip]
    anchor = (start[0] * scale, start[1] * scale)

    work_width = 0.215 * CANVAS
    work = capsule(0.0, 0.0, work_width, 0.78 * CANVAS)

    # Sink the chip's severed end slightly into the cylinder's face, so the
    # two read as one object with material leaving it rather than as a bar
    # and a swirl that happen to touch.
    dx = work_width - 0.018 * CANVAS - anchor[0]
    dy = 0.30 * CANVAS - anchor[1]
    chip = [(x + dx, y + dy) for x, y in chip]

    work, chip = fit(rotate([work, chip], -24.0))

    # The work is cool and the chip is warm: the same separation a real
    # cut has, and the thing that keeps two overlapping shapes legible at
    # the sizes where the shadow between them is a pixel.
    defs = (
        '  <defs>\n'
        '    <linearGradient id="chip" x1="0.05" y1="0.9" x2="0.9" y2="0.05">\n'
        '      <stop offset="0" stop-color="#FF8A26"/>\n'
        '      <stop offset="0.5" stop-color="#FFBE63"/>\n'
        '      <stop offset="1" stop-color="#FFEDD2"/>\n'
        '    </linearGradient>\n'
        '    <linearGradient id="work" x1="0" y1="0" x2="1" y2="0.25">\n'
        '      <stop offset="0" stop-color="#E8EDF8"/>\n'
        '      <stop offset="1" stop-color="#9AA7C4"/>\n'
        '    </linearGradient>\n'
        '  </defs>\n'
    )
    (assets / "work.svg").write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
        f'viewBox="0 0 1024 1024">\n{defs}'
        f'  <path d="{path(work)}" fill="url(#work)"/>\n</svg>\n')
    (assets / "chip.svg").write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
        f'viewBox="0 0 1024 1024">\n{defs}'
        f'  <path d="{path(chip)}" fill="url(#chip)"/>\n</svg>\n')

    # Two groups, not two layers in one group: separate groups get separate
    # shadows, which is what lifts the chip off the work and makes the
    # overlap read as depth rather than as a join.
    document = {
        "fill": {
            "automatic-gradient": "extended-srgb:0.098,0.110,0.184,1.000"
        },
        "groups": [
            {
                "layers": [{"image-name": "work.svg", "name": "Work"}],
                "shadow": {"kind": "neutral", "opacity": 0.45},
                # Opaque, unlike the chip. Translucency here let the curl
                # show through the cylinder it is supposed to be coming
                # out of, which turned the overlap into a smudge instead
                # of into depth.
                "translucency": {"enabled": False, "value": 0.5},
            },
            {
                "layers": [{"image-name": "chip.svg", "name": "Chip"}],
                "shadow": {"kind": "neutral", "opacity": 0.7},
                "specular": True,
                "translucency": {"enabled": True, "value": 0.5},
            },
        ],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
    }
    (root / "Lathe.icon" / "icon.json").write_text(
        json.dumps(document, indent=2) + "\n")
    print(f"    icon: {root / 'Lathe.icon'}")


if __name__ == "__main__":
    main(pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "App/Icon"))
