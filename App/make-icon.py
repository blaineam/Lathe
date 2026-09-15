#!/usr/bin/env python3
"""Generates App/Icon/Lathe.icon — a layered Icon Composer document.

The mark is a ribbon with a twist in it: a band sweeping through an S,
pinching to nothing where it turns edge-on, and showing its darker
underside past each turn. It is the shape material takes coming off a
tool, and the twist is what carries the idea — the same band, turned, is
a different thing.

Five earlier attempts are recorded here so nobody draws them again:

  1. Concentric rings. What a spinning thing looks like head-on, and
     hypnotic in a Dock.
  2. A download arrow. The most generic mark available; said nothing the
     app's name did not.
  3. A turned spindle in silhouette. About lathes, but rendered as a
     chess pawn.
  4. The chip curl on its own. A single open spiral is the Debian swirl.
  5. The chip curl hanging off a pale upright cylinder. Fixed the swirl
     problem and introduced a much worse one: a pale rounded capsule with
     a string coming off it reads as a tampon, and nobody who sees that
     can stop seeing it.

The lesson from 3 and 5 is the one worth keeping: at icon size a shape
is whatever it most resembles, not whatever it depicts. Check the
resemblance before the meaning.

Emitted as SVG inside a .icon bundle rather than a flattened .icns
because that is what macOS 26 wants: the system owns the squircle, the
glass and the specular pass, and derives the dark and tinted appearances
from this artwork. Drawing our own rounded background would fight all of
it. It is also entirely text, so a public repository carries no binary
asset, and the result opens in Icon Composer for anyone who wants to keep
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

SWEEP = 0.86 * CANVAS      # how far the ribbon travels top to bottom
AMPLITUDE = 0.135 * CANVAS  # how far it leans out of the vertical
# Narrow on purpose. A twisted band seen straight on always makes lens
# shapes, and a lens much wider than a third of its length stops reading
# as ribbon and starts reading as leaf. Roughly 1:2.5 is where it turns.
WIDTH = 0.122 * CANVAS      # the band's width seen flat on
TILT = -14.0                # degrees off vertical, so it does not sit at attention

# The twist, in half-turns. Every time this passes an odd multiple of a
# quarter turn the band is edge-on: zero width, and the face you were
# looking at becomes the other one.
#
# Phase 0.5 with a whole number of half-turns puts a pinch at t=0 and at
# t=1 as well as in between, so the band tapers to a point at both ends
# instead of being cut off at full width. That matters more than it
# sounds: an end cut across the width renders as a hard triangle, and
# three hard triangles is a logo for something else entirely.
TWIST = 3.0
TWIST_PHASE = 0.5


def spine(t):
    """The path the band travels, as a point."""
    return (AMPLITUDE * math.sin(math.pi * (t * 2.0 - 0.5)),
            (t - 0.5) * SWEEP)


def twist_angle(t):
    return math.pi * (TWIST_PHASE + t * TWIST)


def band(samples=400):
    """The band, cut into pieces at every point where it turns edge-on.

    Returned as a list of (points, facing) where facing is +1 for the
    side lit by the gradient and -1 for the underside. The pieces are
    disjoint — the band does not overlap itself — so they can be filled
    independently and in any order without occlusion to reason about.
    """
    pieces = []
    current, facing = [], None

    for i in range(samples + 1):
        t = i / samples
        x, y = spine(t)
        after, before = spine(min(t + 1e-3, 1.0)), spine(max(t - 1e-3, 0.0))
        dx, dy = after[0] - before[0], after[1] - before[1]
        length = math.hypot(dx, dy) or 1.0
        nx, ny = -dy / length, dx / length

        # Foreshortening: a band rotated by φ about its own axis presents
        # cos φ of its width. The sign of that cosine is which face is
        # toward the viewer, and a sign change is the edge-on moment.
        projected = math.cos(twist_angle(t))
        side = 1 if projected >= 0 else -1
        half = 0.5 * WIDTH * abs(projected)

        if facing is None:
            facing = side
        if side != facing:
            # Close the piece exactly at the pinch, where the width is
            # zero, so consecutive pieces meet at a point instead of
            # leaving a notch or overlapping by a sample.
            current.append(((x, y), (x, y)))
            pieces.append((current, facing))
            current, facing = [((x, y), (x, y))], side

        current.append(((x + nx * half, y + ny * half),
                        (x - nx * half, y - ny * half)))

    if current:
        pieces.append((current, facing))
    return pieces


def outline(piece):
    """One side of the band and back along the other."""
    return [a for a, _ in piece] + [b for _, b in reversed(piece)]


def rotate(groups, degrees):
    a = math.radians(degrees)
    cos, sin = math.cos(a), math.sin(a)
    return [[(x * cos - y * sin, x * sin + y * cos) for x, y in g]
            for g in groups]


def fit(groups, box=0.86):
    """Centre the whole composition and scale it to fill `box` of the canvas.

    Computed rather than hand-placed: the band's extent depends on the
    twist and the sweep together, and a figure sitting off-centre in the
    squircle is the kind of thing nobody can un-see.
    """
    xs = [x for g in groups for x, _ in g]
    ys = [y for g in groups for _, y in g]
    scale = box * CANVAS / max(max(xs) - min(xs), max(ys) - min(ys))
    cx, cy = (max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2
    return [[((x - cx) * scale + CANVAS / 2, (y - cy) * scale + CANVAS / 2)
             for x, y in g] for g in groups]


def path(points):
    head = f"M {points[0][0]:.2f} {points[0][1]:.2f}"
    rest = " ".join(f"L {x:.2f} {y:.2f}" for x, y in points[1:])
    return f"{head} {rest} Z"


def main(root):
    assets = root / "Lathe.icon" / "Assets"
    assets.mkdir(parents=True, exist_ok=True)

    pieces = band()
    shapes = fit(rotate([outline(p) for p, _ in pieces], TILT))
    facings = [f for _, f in pieces]

    # One hue. The face is bright and the underside is the same colour in
    # shadow, because that is what a twist looks like — not two colours,
    # one colour and one light source.
    defs = (
        '  <defs>\n'
        '    <linearGradient id="face" x1="0.1" y1="0" x2="0.9" y2="1">\n'
        '      <stop offset="0" stop-color="#FFD089"/>\n'
        '      <stop offset="0.55" stop-color="#FFA83E"/>\n'
        '      <stop offset="1" stop-color="#F2801B"/>\n'
        '    </linearGradient>\n'
        '    <linearGradient id="back" x1="0.1" y1="0" x2="0.9" y2="1">\n'
        '      <stop offset="0" stop-color="#C87418"/>\n'
        '      <stop offset="1" stop-color="#9C5410"/>\n'
        '    </linearGradient>\n'
        '  </defs>\n'
    )
    body = "\n".join(
        f'  <path d="{path(shape)}" fill="url(#{"face" if facing > 0 else "back"})"/>'
        for shape, facing in zip(shapes, facings))
    (assets / "ribbon.svg").write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
        f'viewBox="0 0 1024 1024">\n{defs}{body}\n</svg>\n')

    document = {
        "fill": {
            "automatic-gradient": "extended-srgb:0.094,0.106,0.180,1.000"
        },
        "groups": [
            {
                # One group, not one per piece: the pieces are parts of a
                # single band, and separate groups would give each its own
                # shadow and pull the band apart at the twists.
                "layers": [{"image-name": "ribbon.svg", "name": "Ribbon"}],
                "shadow": {"kind": "neutral", "opacity": 0.6},
                "specular": True,
                "translucency": {"enabled": False, "value": 0.5},
            }
        ],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
    }
    (root / "Lathe.icon" / "icon.json").write_text(
        json.dumps(document, indent=2) + "\n")
    print(f"    icon: {root / 'Lathe.icon'}")


if __name__ == "__main__":
    main(pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "App/Icon"))
