"""Procedurally build app_icon_master.png — no AI required.

Discord-pattern icon: a solid dark squircle face fills the canvas, with a
2x2 cell grid of bright tiles sitting near the squircle edge. One tile
renders in the macOS system blue accent — the brand's "one focused pane
out of four" semantic, kept legible all the way down to 16x16.

This replaces the gpt-image-2 master that produced an inner glass bezel
around the cells. With no bezel, the cell grid sits at the squircle's
content edge, so the Dock-rendered footprint matches peer apps (Discord,
KakaoTalk, Slack) instead of looking inset and small.

Run:
  python3 Scripts/brandkit/build_app_icon.py
  python3 Scripts/brandkit/postprocess.py
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
OUT = HERE / "output" / "app_icon_master.png"

CANVAS = 1024
SS = 4              # render at SS× then Lanczos down — clean AA without filters
WORK = CANVAS * SS

# Brand palette (mirrors Brand spec in gen.py)
WINDOW = (29, 29, 31)        # #1d1d1f — squircle top
DESKTOP = (10, 10, 12)       # #0a0a0c — squircle bottom
ACCENT = (10, 132, 255)      # #0a84ff — focused-pane tile
TILE_DIM = (110, 110, 115)   # neutral grey — unfocused panes, bright enough at 16x16

# Apple Big Sur+ continuous-curvature squircle ≈ 22.37% radius approximation.
SQUIRCLE_RADIUS_FRAC = 0.2237

# Squircle scale on the 1024 canvas. 92% gives Discord-like Dock weight while
# leaving a 4% transparent margin so anti-aliased edges never kiss the bbox
# (the alpha.7 "bright frame" Dock-magnification artifact).
SQUIRCLE_SCALE = 0.92

# Cell layout inside the squircle.
CELL_PAD_FRAC = 0.11      # squircle-edge → cell-grid padding
CELL_GUTTER_FRAC = 0.06   # gap between cells, as fraction of grid side
CELL_RADIUS_FRAC = 0.20   # per-cell rounded-rect radius


def lerp(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))  # type: ignore[return-value]


def vertical_gradient(size: int, top: tuple[int, int, int], bot: tuple[int, int, int]) -> Image.Image:
    """One-pixel-wide column gradient stretched horizontally — O(size) instead of O(size²)."""
    col = Image.new("RGB", (1, size))
    px = col.load()
    for y in range(size):
        px[0, y] = lerp(top, bot, y / (size - 1))
    return col.resize((size, size), Image.NEAREST)


def rounded_mask(size: int, radius: int) -> Image.Image:
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return m


def build() -> Image.Image:
    canvas = Image.new("RGBA", (WORK, WORK), (0, 0, 0, 0))

    sq_size = int(WORK * SQUIRCLE_SCALE)
    sq_off = (WORK - sq_size) // 2
    sq_radius = int(sq_size * SQUIRCLE_RADIUS_FRAC)

    face = vertical_gradient(sq_size, WINDOW, DESKTOP).convert("RGBA")
    face.putalpha(rounded_mask(sq_size, sq_radius))
    canvas.alpha_composite(face, (sq_off, sq_off))

    cell_pad = int(sq_size * CELL_PAD_FRAC)
    grid_side = sq_size - cell_pad * 2
    gutter = int(grid_side * CELL_GUTTER_FRAC)
    cell_size = (grid_side - gutter) // 2
    cell_radius = int(cell_size * CELL_RADIUS_FRAC)

    tiles = [
        (0, 0, TILE_DIM),
        (1, 0, TILE_DIM),
        (0, 1, TILE_DIM),
        (1, 1, ACCENT),
    ]
    for col, row, color in tiles:
        x = sq_off + cell_pad + col * (cell_size + gutter)
        y = sq_off + cell_pad + row * (cell_size + gutter)
        tile = Image.new("RGBA", (cell_size, cell_size), (0, 0, 0, 0))
        ImageDraw.Draw(tile).rounded_rectangle(
            (0, 0, cell_size - 1, cell_size - 1),
            radius=cell_radius,
            fill=color + (255,),
        )
        canvas.alpha_composite(tile, (x, y))

    return canvas.resize((CANVAS, CANVAS), Image.LANCZOS)


def main() -> int:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    build().save(OUT, format="PNG")
    print(f"wrote {OUT.name} ({CANVAS}x{CANVAS}, squircle {SQUIRCLE_SCALE:.0%})")
    print("next: python3 Scripts/brandkit/postprocess.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
