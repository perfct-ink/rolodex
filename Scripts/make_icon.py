#!/usr/bin/env python3
"""Draws the Rolodex app icon and writes every size in the AppIcon set.

    python3 Scripts/make_icon.py

Needs Pillow. Everything is drawn at 2x and scaled down for smooth edges.
"""
import math
import pathlib

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZE = 1024
SS = 2  # supersampling factor
OUT = pathlib.Path(__file__).resolve().parent.parent / "Rolodex/Assets.xcassets/AppIcon.appiconset"

BG_TOP, BG_BOTTOM = (166, 124, 78), (122, 88, 54)
CREAM = [(250, 244, 230), (241, 232, 211)]
EDGE = (196, 180, 150)
DARK = (58, 38, 25)
DARKER = (44, 28, 18)
TABS = [(196, 104, 88), (110, 150, 130), (104, 128, 172), (214, 170, 84)]
INK = (170, 150, 120)


def s(value):
    return int(round(value * SS))


def gradient(size, top, bottom):
    image = Image.new("RGB", (size, size))
    pixels = image.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * size)
            pixels[x, y] = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    return image


def card_layer(width, length, tab_color, tab_len, tab_width, fill, outline):
    """One card pointing up, its inner end at the bottom centre of the layer."""
    pad = s(4)
    total = length + tab_len
    layer = Image.new("RGBA", (width + 2 * pad, total + 2 * pad), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    top = pad + tab_len
    draw.rounded_rectangle((pad, top, pad + width, pad + total), radius=s(9), fill=fill, outline=outline, width=s(2))
    if tab_color:
        left = pad + (width - tab_width) // 2
        draw.rounded_rectangle((left, pad, left + tab_width, pad + tab_len + s(34)), radius=s(8), fill=tab_color)
    return layer


def paste_rotated(canvas, layer, pivot, angle_deg, inner_offset):
    """Rotate `layer` about `pivot`, its bottom centre starting `inner_offset` above it."""
    w, h = layer.size
    d = 2 * (h + inner_offset) + 8
    big = Image.new("RGBA", (d, d), (0, 0, 0, 0))
    big.alpha_composite(layer, (d // 2 - w // 2, d // 2 - inner_offset - h))
    big = big.rotate(-angle_deg, resample=Image.BICUBIC, center=(d // 2, d // 2))
    canvas.paste(big, (pivot[0] - d // 2, pivot[1] - d // 2), big)


def draw_icon():
    n = SIZE * SS
    canvas = gradient(n, BG_TOP, BG_BOTTOM).convert("RGBA")

    # The contact card, drawn at its natural size then scaled up to fill the icon.
    card_w, card_len, tab_h = s(250), s(330), s(40)
    pad = s(4)
    card = Image.new("RGBA", (card_w + 2 * pad, card_len + tab_h + 2 * pad), (0, 0, 0, 0))
    td = ImageDraw.Draw(card)
    left, top = pad, pad + tab_h
    td.rounded_rectangle((left, top, left + card_w, top + card_len), radius=s(20), fill=CREAM[0], outline=EDGE, width=s(3))
    td.rounded_rectangle((left + s(26), pad, left + s(26) + s(96), top + s(24)), radius=s(12), fill=TABS[2])
    ax, ay = left + card_w // 2, top + s(116)
    td.ellipse((ax - s(54), ay - s(54), ax + s(54), ay + s(54)), fill=(226, 214, 190))
    # The silhouette is clipped to the avatar circle.
    person = Image.new("L", card.size, 0)
    pd = ImageDraw.Draw(person)
    pd.ellipse((ax - s(17), ay - s(28), ax + s(17), ay + s(6)), fill=255)
    pd.ellipse((ax - s(36), ay + s(2), ax + s(36), ay + s(74)), fill=255)
    clip = Image.new("L", card.size, 0)
    ImageDraw.Draw(clip).ellipse((ax - s(54), ay - s(54), ax + s(54), ay + s(54)), fill=255)
    card.paste(INK, mask=ImageChops.multiply(person, clip))
    for y, x1 in [(200, 210), (236, 170)]:
        td.rounded_rectangle((left + s(20), top + s(y), left + s(x1) + s(20), top + s(y) + s(14)), radius=s(7), fill=(222, 208, 180))

    scale = 2.0
    card = card.resize((int(card.width * scale), int(card.height * scale)), Image.LANCZOS)
    pos = ((n - card.width) // 2, (n - card.height) // 2)

    # Soft shadow, then the card.
    alpha = Image.new("L", (n, n), 0)
    alpha.paste(card.getchannel("A"), pos)
    shadow = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 90), mask=alpha.filter(ImageFilter.GaussianBlur(s(14))))
    canvas.alpha_composite(shadow, (0, s(10)))
    canvas.alpha_composite(card, pos)

    # Rounded-square outline, like the icon it replaces.
    mask = Image.new("L", (n, n), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, n - 1, n - 1), radius=s(225), fill=255)
    canvas.putalpha(mask)
    return canvas.resize((SIZE, SIZE), Image.LANCZOS)


def main():
    master = draw_icon()
    sizes = {
        "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
    }
    for name, px in sizes.items():
        master.resize((px, px), Image.LANCZOS).save(OUT / name)
    print(f"Wrote {len(sizes)} icons to {OUT}")


if __name__ == "__main__":
    main()
