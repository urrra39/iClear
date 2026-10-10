#!/usr/bin/env python3
"""Draws docs/social-preview.png (1280x640), the image GitHub shows when the repository
is linked. Plain text and shapes only. Needs Pillow and macOS system fonts.
Usage: python3 scripts/social-preview.py [output.png]"""
import sys
from PIL import Image, ImageDraw, ImageFont

W, H = 1280, 640
BG, FG, DIM, ACCENT, PANEL = "#111418", "#F2F4F7", "#9AA4B2", "#5CC8A8", "#1C2128"
SANS, MONO = "/System/Library/Fonts/HelveticaNeue.ttc", "/System/Library/Fonts/Menlo.ttc"


def font(path, size, index=0):
    return ImageFont.truetype(path, size, index=index)


img = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(img)
d.rectangle([0, 0, 12, H], fill=ACCENT)

d.text((80, 70), "iClear", font=font(SANS, 96, 1), fill=FG)
d.text((80, 190), "Pauses idle background apps when a Mac runs low on memory,", font=font(SANS, 34), fill=FG)
d.text((80, 234), "and resumes each one when you switch back to it.", font=font(SANS, 34), fill=FG)
d.text((80, 300), "Journaled pauses  ·  Observe mode first  ·  never deletes files", font=font(SANS, 26), fill=DIM)

d.rounded_rectangle([80, 370, W - 80, 540], radius=14, fill=PANEL)
mono = font(MONO, 24)
lines = [
    ("$ iclear why", ACCENT),
    ("Mac Health: 100/100 (good). Forecast: stable.", FG),
    ("Your Mac is healthy; iClear is idle.", FG),
]
for i, (t, c) in enumerate(lines):
    d.text((110, 395 + i * 40), t, font=mono, fill=c)

d.text((80, 572), "macOS 13+  ·  Swift  ·  MIT  ·  github.com/urrra39/iClear", font=font(SANS, 24), fill=DIM)

img.save(sys.argv[1] if len(sys.argv) > 1 else "docs/social-preview.png")
