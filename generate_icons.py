#!/usr/bin/env python3
"""Generate NodeSeek app icons (navy rounded square, white N, blue bar)."""
import os
from PIL import Image, ImageDraw, ImageFont

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "NodeSeek", "Assets.xcassets", "AppIcon.appiconset")
NAVY = (15, 23, 42)
BLUE = (37, 99, 235)
WHITE = (255, 255, 255)

FONT_CANDIDATES = [
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
]

def find_font():
    for p in FONT_CANDIDATES:
        if os.path.exists(p):
            return p
    return None

def draw_icon(size):
    img = Image.new("RGB", (size, size), NAVY)
    d = ImageDraw.Draw(img)
    r = int(size * 0.225)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=NAVY)
    font_path = find_font()
    if font_path:
        try:
            font = ImageFont.truetype(font_path, int(size * 0.58))
            text = "N"
            bbox = d.textbbox((0, 0), text, font=font)
            tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
            d.text(((size - tw) / 2 - bbox[0], (size - th) / 2 - bbox[1] - size * 0.04), text, font=font, fill=WHITE)
        except Exception as e:
            print("font draw failed:", e)
    bar_h = max(2, int(size * 0.055))
    bar_w = int(size * 0.42)
    y0 = int(size * 0.78)
    d.rounded_rectangle([(size - bar_w) / 2, y0, (size + bar_w) / 2, y0 + bar_h], radius=bar_h // 2, fill=BLUE)
    return img

SIZES = [1024, 180, 120, 87, 80, 60, 58, 40, 29, 20]
os.makedirs(OUT, exist_ok=True)
for s in SIZES:
    img = draw_icon(s)
    name = "icon-1024.png" if s == 1024 else f"icon-{s}.png"
    img.save(os.path.join(OUT, name))
    print("wrote", name)
print("done")
