#!/usr/bin/env python3
"""Draws Assets.xcassets/AppIcon.appiconset/icon-1024.png — the forge at 60pt on a home screen.

Soot ground, the fire rising from the bottom edge, and one white-hot italic F glowing ember:
the metal just out of the fire. Nothing more survives that size.
Regenerate: python3 ios-forja/gen-icon.py"""
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageChops

HERE = os.path.dirname(os.path.abspath(__file__))
S = 1024
SOOT, IRON = (0x17, 0x12, 0x0f), (0x24, 0x1d, 0x18)
EMBER, HOT = (0xff, 0x5b, 0x1f), (0xff, 0xd7, 0xa3)


def ground():
    img = Image.new('RGB', (S, S), SOOT)
    d = ImageDraw.Draw(img)
    for y in range(S):
        t = (y / S) ** 1.6
        d.line([(0, y), (S, y)], fill=tuple(int(SOOT[i] + (IRON[i] - SOOT[i]) * t) for i in range(3)))
    return img


def fire():
    """The forge below the frame: a wide ember bloom rising from the bottom edge."""
    g = Image.new('RGB', (S, S), (0, 0, 0))
    ImageDraw.Draw(g).ellipse([-S * 0.25, S * 0.72, S * 1.25, S * 1.55], fill=(150, 48, 12))
    return g.filter(ImageFilter.GaussianBlur(150))


def letter():
    font = ImageFont.truetype(os.path.join(HERE, 'Fonts', 'InstrumentSerif-Italic.ttf'), 860)
    m = Image.new('L', (S, S), 0)
    d = ImageDraw.Draw(m)
    box = d.textbbox((0, 0), 'F', font=font)
    w, h = box[2] - box[0], box[3] - box[1]
    d.text(((S - w) / 2 - box[0] + 18, (S - h) / 2 - box[1] - 12), 'F', font=font, fill=255)
    return m


def main():
    img = ImageChops.add(ground(), fire())
    mask = letter()
    # the glow: the letter's own shape, blurred wide in ember, then tighter and hotter
    for radius, colour, strength in ((70, EMBER, 0.9), (26, (255, 120, 50), 0.8)):
        halo = Image.new('RGB', (S, S), colour)
        glow = mask.filter(ImageFilter.GaussianBlur(radius)).point(lambda v: int(v * strength))
        img = Image.composite(halo, img, glow)
    img = Image.composite(Image.new('RGB', (S, S), HOT), img, mask)
    out = os.path.join(HERE, 'Assets.xcassets', 'AppIcon.appiconset', 'icon-1024.png')
    img.save(out)
    print('icon →', out)


if __name__ == '__main__':
    main()
