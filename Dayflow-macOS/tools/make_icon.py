#!/usr/bin/env python3
"""
Generate the Dayflow macOS app icon set.

Design language mirrors DesignSystem.swift:
  canvas  = (0.06, 0.07, 0.085)  # off-black
  surface = (0.10, 0.11, 0.13)
  accent  = (0.97, 0.55, 0.20)   # warm orange
  done    = (0.30, 0.78, 0.46)

Icon concept: a rounded-square canvas holding a completion ring (3/4 arc in
warm accent) with a bold "D" monogram at the center, referencing the app's
name and its core metaphor of daily progress.
"""

from __future__ import annotations

import math
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


HERE = Path(__file__).resolve().parent
OUT = HERE / "Dayflow.iconset"
ICNS = HERE.parent / "Dayflow.icns"

CANVAS = (15, 18, 22, 255)
SURFACE = (26, 28, 33, 255)
ACCENT = (247, 140, 51, 255)
ACCENT_SOFT = (247, 140, 51, 64)
DONE = (77, 199, 117, 255)
HAIRLINE = (255, 255, 255, 22)
WHITE = (255, 255, 255, 240)


def rounded_rect_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def draw_icon(px: int) -> Image.Image:
    # Render at 4x for anti-aliasing, then downsample.
    scale = 4
    size = px * scale
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Rounded-square background. macOS squircle radius ~= 22.37% of edge.
    radius = int(size * 0.2237)
    draw.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=CANVAS)

    # Inner bevel — a thin inset glow to separate from wallpaper.
    inset = int(size * 0.012)
    draw.rounded_rectangle(
        (inset, inset, size - 1 - inset, size - 1 - inset),
        radius=radius - inset,
        outline=HAIRLINE,
        width=max(1, int(size * 0.006)),
    )

    # Completion ring — centered, occupies middle 62%.
    ring_d = int(size * 0.62)
    ring_x = (size - ring_d) // 2
    ring_y = (size - ring_d) // 2
    ring_box = (ring_x, ring_y, ring_x + ring_d, ring_y + ring_d)
    ring_width = max(2, int(size * 0.068))

    # Progress arc — 75% starting from top. The open quadrant reads as
    # "flow" — a continuous stream that has room to keep going.
    draw.arc(
        ring_box,
        start=-90,
        end=-90 + 270,
        fill=ACCENT,
        width=ring_width,
    )

    # Small done-dot at the arc tip for a touch of life.
    end_angle_rad = math.radians(-90 + 270)
    cx = ring_x + ring_d / 2
    cy = ring_y + ring_d / 2
    r = ring_d / 2
    tx = cx + r * math.cos(end_angle_rad)
    ty = cy + r * math.sin(end_angle_rad)
    dot_r = int(size * 0.028)
    draw.ellipse(
        (tx - dot_r, ty - dot_r, tx + dot_r, ty + dot_r),
        fill=DONE,
    )

    # Center monogram "D" using SF Compact Rounded for a warm, soft feel.
    # We render upright, then shear the whole glyph layer ~9° to suggest
    # forward motion — the "flow" half of the name.
    mono_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    mdraw = ImageDraw.Draw(mono_layer)
    font_path = "/System/Library/Fonts/SFCompactRounded.ttf"
    font_size = int(ring_d * 0.64)
    try:
        font = ImageFont.truetype(font_path, font_size)
    except OSError:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", font_size)

    glyph = "D"
    bbox = mdraw.textbbox((0, 0), glyph, font=font, anchor="lt")
    gw = bbox[2] - bbox[0]
    gh = bbox[3] - bbox[1]
    gx = cx - gw / 2 - bbox[0]
    gy = cy - gh / 2 - bbox[1]
    mdraw.text((gx, gy), glyph, font=font, fill=WHITE)

    # Italic shear ~7° around the ring center so the glyph stays put.
    shear = math.tan(math.radians(7))
    mono_layer = mono_layer.transform(
        (size, size),
        Image.AFFINE,
        (1, shear, -shear * cy, 0, 1, 0),
        resample=Image.BICUBIC,
    )

    img = Image.alpha_composite(img, mono_layer)

    # Soft drop shadow behind everything to lift from dock.
    shadow_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sdraw = ImageDraw.Draw(shadow_layer)
    sdraw.rounded_rectangle(
        (0, int(size * 0.02), size - 1, size - 1),
        radius=radius,
        fill=(0, 0, 0, 90),
    )
    shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(radius=size * 0.02))
    composed = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    composed = Image.alpha_composite(composed, shadow_layer)
    composed = Image.alpha_composite(composed, img)

    # Clip to rounded square.
    mask = rounded_rect_mask(size, radius)
    final = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    final.paste(composed, (0, 0), mask)

    # Downsample with high-quality filter.
    final = final.resize((px, px), Image.LANCZOS)
    return final


def main() -> None:
    OUT.mkdir(exist_ok=True)
    # Sizes iconutil expects for icon.iconset.
    specs = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]
    for name, px in specs:
        path = OUT / name
        draw_icon(px).save(path, "PNG")
        print(f"  {name} ({px}x{px})")

    # Build .icns.
    subprocess.run(
        ["iconutil", "-c", "icns", str(OUT), "-o", str(ICNS)],
        check=True,
    )
    print(f"\nwrote {ICNS}")


if __name__ == "__main__":
    main()
