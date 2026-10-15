#!/usr/bin/env bash
#
# Assembles the README demo GIF from ShotRunner frames.
#
# Frame source of truth: `HotspotGuard --shot-dir <dir>` (debug builds only,
# see ShotRunner.swift) writes menu-00.png … menu-NN.png using live probe
# ticks, so frames reflect connectivity at render time — render online for
# the healthy state. This script pads frames to a uniform canvas, rounds
# the corners, draws an animated cursor visiting the UI hotspots, and
# encodes a palette-optimised looping GIF.
#
# Usage:
#   ./scripts/make-demo-gif.sh [/tmp/shots] [docs/demo-menu.gif]

set -euo pipefail

SHOTS="${1:-/tmp/shots}"
OUT="${2:-docs/demo-menu.gif}"

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "make-demo-gif.sh: ffmpeg is not installed (brew install ffmpeg)" >&2
    exit 1
fi

if ! python3 -c "import PIL.Image, PIL.ImageDraw" 2>/dev/null; then
    echo "make-demo-gif.sh: python3 Pillow is not installed (pip install Pillow)" >&2
    exit 1
fi

shopt -s nullglob
frames=("$SHOTS"/menu-*.png)
count="${#frames[@]}"
if [[ "$count" -lt 12 ]]; then
    echo "make-demo-gif.sh: need 12+ menu frames in $SHOTS, found $count." >&2
    echo "Run: HotspotGuard --shot-dir $SHOTS (debug build)" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Cursor waypoints in frame pixels (760-wide frames): the + button, the
# network row, the interval slider, the History link, Stop — then home.
# The cursor glides across the OUTPUT frames while backgrounds crossfade
# between rendered frames, so motion stays smooth at 12fps.
FPS=12
BLENDS=4
python3 - "$SHOTS" "$WORK" "$FPS" "$BLENDS" <<'PY'
import glob
import sys
from PIL import Image, ImageDraw
shots_dir, work, fps, blends = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
files = sorted(glob.glob(f"{shots_dir}/menu-*.png"))
ims = [Image.open(f).convert("RGBA") for f in files]
width = max(i.width for i in ims)
height = max(i.height for i in ims)
bg = ims[-1].getpixel((5, 5))[:3]

waypoints = [
    (250, 195),  # demo network row
    (695, 148),  # + button
    (320, 285),  # check-every slider
    (620, 505),  # History link
    (540, 600),  # Stop button
    (200, 60),  # header, on the way home
]


def cursor_at(out_frame: int, out_total: int) -> tuple[int, int]:
    span = (out_total - 1) / (len(waypoints) - 1)
    position = min(out_frame / span, len(waypoints) - 1)
    leg = min(int(position), len(waypoints) - 2)
    blend = position - leg
    (x0, y0), (x1, y1) = waypoints[leg], waypoints[leg + 1]
    return round(x0 + (x1 - x0) * blend), round(y0 + (y1 - y0) * blend)


def draw_cursor(canvas: Image.Image, tip: tuple[int, int]) -> None:
    x, y = tip
    # Classic arrow, tip at (x, y); white fill, black outline.
    arrow = [(0, 0), (0, 30), (8, 23), (12, 30), (16, 27), (12, 20), (19, 20)]
    pts = [(x + dx, y + dy) for dx, dy in arrow]
    overlay = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    draw.polygon(pts, fill=(255, 255, 255, 255))
    outline = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(outline).polygon(pts, outline=(0, 0, 0, 255), width=3)
    canvas.alpha_composite(outline, (0, 0))
    canvas.alpha_composite(overlay, (0, 0))


corner = Image.new("L", (width, height), 0)
ImageDraw.Draw(corner).rounded_rectangle([0, 0, width - 1, height - 1], radius=26, fill=255)
padded = []
for im in ims:
    canvas = Image.new("RGBA", (width, height), bg + (255,))
    canvas.alpha_composite(im, (0, 0))
    padded.append(canvas)
out = 0
for gap in range(len(padded) - 1):
    for step in range(blends):
        alpha = step / blends
        frame = Image.blend(padded[gap], padded[gap + 1], alpha)
        draw_cursor(frame, cursor_at(out, (len(padded) - 1) * blends + 1))
        frame.putalpha(corner)
        frame.save(f"{work}/frame-{out:02d}.png")
        out += 1
frame = padded[-1].copy()
draw_cursor(frame, cursor_at(out, out + 1))
frame.putalpha(corner)
frame.save(f"{work}/frame-{out:02d}.png")
print(f"composed {out + 1} frames at {width}x{height}")
PY

ffmpeg -y -v error -start_number 0 -framerate "$FPS" -i "$WORK/frame-%02d.png" \
    -vf "split[s0][s1];[s0]palettegen=max_colors=256[p];[s1][p]paletteuse=dither=bayer:bayer_scale=4" \
    "$OUT"
echo "Wrote $OUT ($(du -h "$OUT" | cut -f1))"
