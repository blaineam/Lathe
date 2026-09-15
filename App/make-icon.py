#!/usr/bin/env python3
"""Generates App/Icon/Lathe.icon — a layered Icon Composer document.

The mark is a facing cut: the work seen end-on, a tool driven into its
face at an angle, and the chip curling away from the cut. It is the
operation the machine is named for, drawn as the three things actually
involved.

Seven earlier attempts are recorded here so nobody draws them again, and
because the reasons are more useful than the drawings were:

  1. Concentric rings — what a spinning thing looks like head-on, and
     hypnotic in a Dock.
  2. A download arrow — the most generic mark available; said nothing the
     app's name did not.
  3. A turned spindle in silhouette — about lathes, but rendered as a
     chess pawn.
  4. The chip curl alone — a single open spiral is the Debian swirl.
  5. The chip on a pale upright cylinder — a capsule with a string coming
     off it, which nobody can un-see as something else.
  6. A twisted ribbon — the lobes read as leaves.
  7. A stepped shaft, and a letterform L — both fine, neither loved.

The lesson from 3 and 5 is the one worth keeping: at icon size a shape is
whatever it most resembles, not whatever it depicts. Check the
resemblance before the meaning. The lesson from this one is the opposite
and just as important — the tool block reads as pasted-on to the person
who drew it and as a tool to everyone else, so a second opinion beats a
confident first one.

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

# The work, seen end-on, at the exact centre of the canvas.
#
# Everything else hangs off it: the tool comes in to its face, the chip
# leaves its rim. Composing the other way round — fitting the whole
# figure's bounding box to the square — put the disc down and left, and an
# icon whose subject is off-centre reads as a mistake however deliberate
# the arrangement was.
CENTRE = (CANVAS * 0.5, CANVAS * 0.5)
RADIUS = CANVAS * 0.255

# Where the tool is presenting, measured from the positive x axis. Up and
# to the right, which is the direction the chip then unwinds away from.
TOOL_ANGLE = -52.0
# How far into the work the cut goes, as a fraction of the radius.
DEPTH = 0.26

CHIP_START = -18.0     # degrees; where the chip leaves the rim
CHIP_TURNS = 0.52      # how far round it travels before it runs out
CHIP_WIDTH = 0.050     # of the canvas, at its thickest
CHIP_TAPER = 1.7       # how sharply it thins toward the tip


def chip_path(samples=220):
    """The chip, peeling off the rim and unwinding outward.

    Thin where it leaves the metal, thickest just after, tapering to a
    point. A chip drawn at full width from its first sample has a blunt
    flag on the leading end and reads as a loading spinner rather than as
    material coming off a cut.
    """
    cx, cy = CENTRE
    outer, inner = [], []
    start = math.radians(CHIP_START)
    for index in range(samples + 1):
        t = index / samples
        angle = start + t * CHIP_TURNS * 2 * math.pi
        # Unwinds away from the rim rather than spiralling into itself.
        radius = RADIUS + t * RADIUS * 0.62
        ramp = min(1.0, t / 0.16)
        width = CHIP_WIDTH * CANVAS * ramp * (1.0 - t) ** CHIP_TAPER
        x, y = cx + radius * math.cos(angle), cy + radius * math.sin(angle)
        nx, ny = math.cos(angle), math.sin(angle)
        outer.append((x + nx * width, y + ny * width))
        inner.append((x - nx * width, y - ny * width))
    points = outer + list(reversed(inner))
    head = "M %.1f %.1f" % points[0]
    return head + " " + " ".join("L %.1f %.1f" % p for p in points[1:]) + " Z"


def tool_path():
    """The tool, as the flat it has cut plus the body behind it.

    A chord rather than a wedge: a facing cut leaves a flat, and a wedge
    driven into a circle is a pie slice, which is what the first version
    of this looked like.
    """
    cx, cy = CENTRE
    a = math.radians(TOOL_ANGLE)
    depth = RADIUS * DEPTH
    hx, hy = math.cos(a), math.sin(a)            # into the work
    tx, ty = -hy, hx                             # across the cutting edge

    # The cutting edge sits at the chord; the body extends back out of the
    # work along the same axis.
    px, py = cx + (RADIUS - depth) * hx, cy + (RADIUS - depth) * hy
    half = math.sqrt(max(0.0, RADIUS * RADIUS - (RADIUS - depth) ** 2))
    back = depth * 2.0

    # Narrower at the tip than at the back, which is the shape of every
    # tool that has to clear its own cut.
    relief = 0.82
    return (
        f"M {px + tx * half:.1f} {py + ty * half:.1f} "
        f"L {px - tx * half:.1f} {py - ty * half:.1f} "
        f"L {px - tx * half / relief + hx * back:.1f} "
        f"{py - ty * half / relief + hy * back:.1f} "
        f"L {px + tx * half / relief + hx * back:.1f} "
        f"{py + ty * half / relief + hy * back:.1f} Z"
    )


def cutting_edge():
    """A bright line along the tool's tip.

    Without it the tool is a silhouette, and a dark shape overlapping a
    pale one reads as a hole in the pale one rather than as an object in
    front of it.
    """
    cx, cy = CENTRE
    a = math.radians(TOOL_ANGLE)
    depth = RADIUS * DEPTH
    hx, hy = math.cos(a), math.sin(a)
    tx, ty = -hy, hx
    px, py = cx + (RADIUS - depth) * hx, cy + (RADIUS - depth) * hy
    half = math.sqrt(max(0.0, RADIUS * RADIUS - (RADIUS - depth) ** 2))
    width = CANVAS * 0.011
    return (
        f"M {px + tx * half:.1f} {py + ty * half:.1f} "
        f"L {px - tx * half:.1f} {py - ty * half:.1f} "
        f"L {px - tx * half + hx * width:.1f} {py - ty * half + hy * width:.1f} "
        f"L {px + tx * half + hx * width:.1f} {py + ty * half + hy * width:.1f} Z"
    )


DEFS = (
    '  <defs>\n'
    '    <linearGradient id="chip" x1="0.15" y1="0" x2="0.85" y2="1">\n'
    '      <stop offset="0" stop-color="#FFCE7C"/>\n'
    '      <stop offset="0.5" stop-color="#FFA23C"/>\n'
    '      <stop offset="1" stop-color="#EF7A12"/>\n'
    '    </linearGradient>\n'
    '    <linearGradient id="work" x1="0.1" y1="0" x2="0.9" y2="1">\n'
    '      <stop offset="0" stop-color="#F2F5FC"/>\n'
    '      <stop offset="1" stop-color="#94A5C2"/>\n'
    '    </linearGradient>\n'
    '    <linearGradient id="tool" x1="0" y1="0" x2="1" y2="1">\n'
    '      <stop offset="0" stop-color="#232838"/>\n'
    '      <stop offset="1" stop-color="#11131D"/>\n'
    '    </linearGradient>\n'
    '  </defs>\n'
)


def svg(body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
            f'viewBox="0 0 1024 1024">\n{DEFS}{body}\n</svg>\n')


def main(root):
    assets = root / "Lathe.icon" / "Assets"
    assets.mkdir(parents=True, exist_ok=True)

    cx, cy = CENTRE
    # The work and the tool in one layer, because the tool is *in* the cut
    # and a separate group would give it its own shadow and lift it off.
    (assets / "work.svg").write_text(svg(
        f'  <circle cx="{cx:.1f}" cy="{cy:.1f}" r="{RADIUS:.1f}" fill="url(#work)"/>\n'
        f'  <path d="{tool_path()}" fill="url(#tool)"/>\n'
        f'  <path d="{cutting_edge()}" fill="#BFC9DE" fill-opacity="0.75"/>'))

    # The chip is its own group so the system gives it its own depth: it is
    # the one thing here that is genuinely in front of everything else.
    (assets / "chip.svg").write_text(svg(
        f'  <path d="{chip_path()}" fill="url(#chip)"/>'))

    document = {
        "fill": {
            "automatic-gradient": "extended-srgb:0.086,0.098,0.169,1.000"
        },
        "groups": [
            {
                "layers": [{"image-name": "work.svg", "name": "Work"}],
                "shadow": {"kind": "neutral", "opacity": 0.5},
                "translucency": {"enabled": False, "value": 0.5},
            },
            {
                "layers": [{"image-name": "chip.svg", "name": "Chip"}],
                "shadow": {"kind": "neutral", "opacity": 0.65},
                "specular": True,
                "translucency": {"enabled": False, "value": 0.5},
            },
        ],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
    }
    (root / "Lathe.icon" / "icon.json").write_text(
        json.dumps(document, indent=2) + "\n")
    print(f"    icon: {root / 'Lathe.icon'}")


if __name__ == "__main__":
    main(pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "App/Icon"))
