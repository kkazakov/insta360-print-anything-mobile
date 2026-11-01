#!/usr/bin/env python3
"""Regenerate the Android launcher icons from `app_icon.svg`.

Requires Pillow and CairoSVG:
    python3 -m pip install --user pillow cairosvg
Run from anywhere:
    python3 tool/icon/generate_icons.py
"""

from __future__ import annotations

import io
import re
from pathlib import Path

import cairosvg
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SVG = (HERE / "app_icon.svg").read_text()
RES = ROOT / "android" / "app" / "src" / "main" / "res"

#: 48 dp is the legacy launcher size; the adaptive foreground layer is 108 dp.
DENSITIES = {
    "mdpi": 1.0,
    "hdpi": 1.5,
    "xhdpi": 2.0,
    "xxhdpi": 3.0,
    "xxxhdpi": 4.0,
}

#: Adaptive-icon glyph must fit the 66 dp safe circle (61% of the 108 dp layer).
SAFE_RATIO = 66.0 / 108.0


def render(svg: str, size: int) -> Image.Image:
    png = cairosvg.svg2png(
        bytestring=svg.encode(),
        output_width=size,
        output_height=size,
    )
    return Image.open(io.BytesIO(png)).convert("RGBA")


def glyph_layer(canvas: int = 432) -> Image.Image:
    """The mark alone, scaled to fit the adaptive-icon safe circle."""
    glyph_svg = SVG.replace(
        '<rect width="1024" height="1024" fill="url(#bg)"/>', ""
    )
    glyph_svg = re.sub(r'<ellipse cx="500" cy="812"[^/]*/>', "", glyph_svg)
    mark = render(glyph_svg, 1024)
    crop = mark.crop(mark.getbbox())

    safe = canvas * SAFE_RATIO
    diagonal = (crop.width**2 + crop.height**2) ** 0.5
    scale = safe / diagonal
    size = (max(1, round(crop.width * scale)), max(1, round(crop.height * scale)))
    mark = crop.resize(size, Image.LANCZOS)

    layer = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    layer.paste(mark, ((canvas - mark.width) // 2, (canvas - mark.height) // 2))
    return layer


def round_icon(image: Image.Image) -> Image.Image:
    size = image.width
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, size, size), fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(image, (0, 0), mask)
    return out


def main() -> None:
    full = render(SVG, 1024)
    foreground = glyph_layer(432)

    for name, factor in DENSITIES.items():
        legacy_px = round(48 * factor)
        icon = full.resize((legacy_px, legacy_px), Image.LANCZOS)
        folder = RES / f"mipmap-{name}"
        folder.mkdir(parents=True, exist_ok=True)
        icon.save(folder / "ic_launcher.png", optimize=True)
        round_icon(icon).save(folder / "ic_launcher_round.png", optimize=True)

        fg_px = round(108 * factor)
        foreground.resize((fg_px, fg_px), Image.LANCZOS).save(
            folder / "ic_launcher_foreground.png", optimize=True
        )

    adaptive = RES / "mipmap-anydpi-v26"
    adaptive.mkdir(parents=True, exist_ok=True)
    for name in ("ic_launcher", "ic_launcher_round"):
        (adaptive / f"{name}.xml").write_text(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '    <background android:drawable="@drawable/ic_launcher_background" />\n'
            '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
            '</adaptive-icon>\n'
        )

    drawable = RES / "drawable" / "ic_launcher_background.xml"
    drawable.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<shape xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    android:shape="rectangle">\n'
        '    <gradient\n'
        '        android:angle="315"\n'
        '        android:startColor="#FFD95E"\n'
        '        android:centerColor="#FFC42E"\n'
        '        android:endColor="#F2A400"\n'
        '        android:type="linear" />\n'
        '</shape>\n'
    )

    # Store/readme preview (also handy for the repository logo later).
    full.resize((512, 512), Image.LANCZOS).save(HERE / "app_icon-512.png", optimize=True)
    print(f"wrote launcher icons under {RES}")


if __name__ == "__main__":
    main()
