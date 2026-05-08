"""Generate the DMG installer background.

Output:
    Resources/installer/dmg_background.png      (540 x 380)
    Resources/installer/dmg_background@2x.png   (1080 x 760)

Layout: dark vertical gradient + subtle radial vignette + a single arrow in the
center pointing from the app icon spot to the Applications drop-link spot.
The icon images themselves are NOT in the background — Finder draws those at
the positions configured in Scripts/release.sh, so painting placeholders here
would just double up with the real icons.

Run from repo root:
    Scripts/brandkit/.venv/bin/python Scripts/brandkit/make_dmg_background.py
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw

# 2x dimensions; downscaled to 1x with LANCZOS at the end.
W, H = 1080, 760

# Icon centers on the 1x window (must match the --icon / --app-drop-link
# coordinates passed to create-dmg in Scripts/release.sh).
ICON_CENTER_1X = (135, 170)
DROP_CENTER_1X = (385, 170)


def render_gradient(img: Image.Image) -> None:
    px = img.load()
    cx, cy = W / 2, H / 2
    max_dist = math.hypot(cx, cy)
    top = (18, 22, 38)
    bot = (4, 5, 12)
    for y in range(H):
        t = y / (H - 1)
        r = int(top[0] * (1 - t) + bot[0] * t)
        g = int(top[1] * (1 - t) + bot[1] * t)
        b = int(top[2] * (1 - t) + bot[2] * t)
        for x in range(W):
            d = math.hypot(x - cx, y - cy) / max_dist
            v = 1.0 - 0.35 * (d ** 1.5)
            px[x, y] = (max(0, int(r * v)),
                        max(0, int(g * v)),
                        max(0, int(b * v)))


def render_arrow(img: Image.Image) -> None:
    draw = ImageDraw.Draw(img)
    # Arrow horizontally centered between the two icon centers, at icon-center y.
    midx_1x = (ICON_CENTER_1X[0] + DROP_CENTER_1X[0]) / 2
    arrow_y = ICON_CENTER_1X[1] * 2  # scale to @2x
    arrow_color = (180, 190, 210)
    shaft_w = 4
    shaft_len = 110
    shaft_start = int(midx_1x * 2 - shaft_len / 2)
    shaft_end = shaft_start + shaft_len
    head = 18
    draw.rectangle((shaft_start, arrow_y - shaft_w // 2,
                    shaft_end - 22, arrow_y + shaft_w // 2 + 1),
                   fill=arrow_color)
    draw.polygon([
        (shaft_end, arrow_y),
        (shaft_end - 22, arrow_y - head),
        (shaft_end - 22, arrow_y + head),
    ], fill=arrow_color)


def main() -> None:
    repo_root = Path(__file__).resolve().parents[2]
    out_dir = repo_root / "Resources" / "installer"
    out_dir.mkdir(parents=True, exist_ok=True)

    img = Image.new("RGB", (W, H), (0, 0, 0))
    render_gradient(img)
    render_arrow(img)

    img.save(out_dir / "dmg_background@2x.png")
    img.resize((W // 2, H // 2), Image.LANCZOS).save(out_dir / "dmg_background.png")
    print(f"wrote {out_dir/'dmg_background.png'} and @2x")


if __name__ == "__main__":
    main()
