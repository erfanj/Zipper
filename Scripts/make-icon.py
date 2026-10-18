#!/usr/bin/env python3
"""Draws Zipper's app icon and writes the Xcode asset catalog icon set and an .icns file.

    python3 Scripts/make-icon.py

Outputs Sources/ZipperMac/Resources/Assets.xcassets/AppIcon.appiconset/*.png (with Contents.json)
and Packaging/AppIcon.icns (used by Scripts/build-app.sh). Needs Pillow (pip install pillow).
The drawing follows the macOS icon grid: an 824 pt rounded square centred on a 1024 pt canvas.
"""
import json
import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 2048  # drawn at 2x, then downsampled for smooth edges
K = S / 1024


def px(v):
    return int(round(v * K))


def vertical_gradient(size, top, bottom):
    w, h = size
    g = Image.new("RGBA", size)
    d = ImageDraw.Draw(g)
    for y in range(h):
        t = y / max(1, h - 1)
        d.line([(0, y), (w, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(4)))
    return g


def draw_icon():
    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    box = (px(100), px(100), px(924), px(924))
    radius = px(185)

    # Soft drop shadow under the tile.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((box[0], box[1] + px(12), box[2], box[3] + px(12)), radius, fill=(0, 0, 0, 110))
    icon.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(px(18))))

    # Tile: deep blue to violet.
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius, fill=255)
    tile = vertical_gradient((S, S), (64, 112, 255, 255), (118, 52, 230, 255))
    icon.paste(tile, (0, 0), mask)

    # Gentle highlight that fades out towards the middle of the tile.
    hl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    hd = ImageDraw.Draw(hl)
    top, fade_end = box[1], px(600)
    for y in range(top, fade_end):
        t = (y - top) / (fade_end - top)
        hd.line([(0, y), (S, y)], fill=(255, 255, 255, int(48 * (1 - t) ** 2)))
    icon.alpha_composite(Image.composite(hl, Image.new("RGBA", (S, S), (0, 0, 0, 0)), mask))

    art = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(art)
    cx = 512
    white = (255, 255, 255, 255)
    tooth_w, tooth_h, step = 74, 26, 44

    def tooth(x0, y, w=tooth_w):
        d.rounded_rectangle((px(x0), px(y - tooth_h / 2), px(x0 + w), px(y + tooth_h / 2)), px(10), fill=white)

    # Closed part of the zipper: teeth interlock along the centre line.
    y = 196
    i = 0
    while y <= 560:
        if i % 2 == 0:
            tooth(cx - tooth_w + 8, y)
        else:
            tooth(cx - 8, y)
        y += step / 2
        i += 1

    # Open part below the slider: the two rows spread apart.
    y = 640
    i = 0
    while y <= 840:
        spread = (y - 600) * 0.42
        if i % 2 == 0:
            tooth(cx - tooth_w - spread + 6, y)
        else:
            tooth(cx + spread - 6, y)
        y += step / 2
        i += 1

    # Slider body.
    d.rounded_rectangle((px(cx - 70), px(548), px(cx + 70), px(650)), px(26), fill=white)
    # Pull tab with a hole, hanging from the slider.
    d.rounded_rectangle((px(cx - 40), px(610), px(cx + 40), px(800)), px(34), fill=(240, 240, 255, 255))
    d.rounded_rectangle((px(cx - 15), px(712), px(cx + 15), px(772)), px(15), fill=(108, 70, 236, 255))
    # Shading where the tab meets the slider.
    d.rounded_rectangle((px(cx - 52), px(600), px(cx + 52), px(616)), px(8), fill=(200, 205, 255, 255))

    art_shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    art_shadow.paste((20, 10, 80, 90), (0, 0), art.split()[3])
    icon.alpha_composite(art_shadow.filter(ImageFilter.GaussianBlur(px(6))), (0, px(6)))
    icon.alpha_composite(art)
    return icon.resize((1024, 1024), Image.LANCZOS)


def main():
    icon = draw_icon()
    iconset = os.path.join(ROOT, "Sources/ZipperMac/Resources/Assets.xcassets/AppIcon.appiconset")
    os.makedirs(iconset, exist_ok=True)
    images = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
            icon.resize((pixels, pixels), Image.LANCZOS).save(os.path.join(iconset, name))
            images.append({"idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}", "filename": name})
    with open(os.path.join(iconset, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
    catalog = os.path.dirname(iconset)
    with open(os.path.join(catalog, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
    accent = os.path.join(catalog, "AccentColor.colorset")
    os.makedirs(accent, exist_ok=True)
    with open(os.path.join(accent, "Contents.json"), "w") as f:
        json.dump({"colors": [{"idiom": "universal", "color": {"color-space": "srgb", "components":
                   {"red": "0.400", "green": "0.380", "blue": "0.960", "alpha": "1.000"}}}],
                   "info": {"author": "xcode", "version": 1}}, f, indent=2)
    os.makedirs(os.path.join(ROOT, "Packaging"), exist_ok=True)
    icon.save(os.path.join(ROOT, "Packaging/AppIcon.icns"),
              sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
    print("Wrote", iconset, "and Packaging/AppIcon.icns")


if __name__ == "__main__":
    main()
