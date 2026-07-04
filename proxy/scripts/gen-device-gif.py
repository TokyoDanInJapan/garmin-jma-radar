#!/usr/bin/env python3
"""Render the JMA radar frames as they appear on a Garmin Edge screen, and
assemble an animated GIF. Mirrors radar-widget/source/RadarView.mc onUpdate():
black screen, 288px radar bitmap centred, frame index (top-left), data-age
(top-right), disclaimer + JMA/GSI attribution (bottom). Edge 1040 = 282x470."""
import json, os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SAMP = os.path.join(ROOT, "samples")

SCREEN_W, SCREEN_H = 282, 470          # Edge 1040 colour display
FRAME_MS = 500                          # matches RadarView FRAME_MS
DISCLAIMER = "Informational only; may be stale"

lat_font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 13)
small    = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 12)
cjk      = ImageFont.truetype("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", 12)

frames = json.load(open(os.path.join(SAMP, "frames.json")))
labels = frames["labels"]
n = len(labels)

def center(draw, y, text, font, fill=(255, 255, 255)):
    w = draw.textlength(text, font=font)
    draw.text(((SCREEN_W - w) / 2, y), text, font=font, fill=fill)

def render_screen(i):
    scr = Image.new("RGB", (SCREEN_W, SCREEN_H), (0, 0, 0))
    radar = Image.open(os.path.join(SAMP, f"frame_{i:02d}.png")).convert("RGB")
    bx = (SCREEN_W - radar.width) // 2          # 288 slightly overflows 282 -> clipped, like the device
    by = (SCREEN_H - radar.height) // 2
    scr.paste(radar, (bx, by))
    d = ImageDraw.Draw(scr)
    # top-left frame index, top-right data age
    d.text((4, 2), f"{i + 1}/{n}", font=lat_font, fill=(255, 255, 255))
    age = f"as of {labels[i]}"
    d.text((SCREEN_W - 4 - d.textlength(age, font=lat_font), 2), age, font=lat_font, fill=(255, 255, 255))
    # bottom: disclaimer + two attribution lines (compliance)
    center(d, SCREEN_H - 44, DISCLAIMER, small, (210, 210, 210))
    center(d, SCREEN_H - 29, "出典:気象庁 (processed)", cjk)
    center(d, SCREEN_H - 15, "地図:国土地理院", cjk)
    return scr

def with_bezel(scr):
    """Wrap the screen in a simple Edge-like body so the GIF reads as a device."""
    mx, top, bottom = 20, 38, 60
    body = Image.new("RGB", (SCREEN_W + 2 * mx, SCREEN_H + top + bottom), (28, 28, 30))
    d = ImageDraw.Draw(body)
    d.rounded_rectangle([0, 0, body.width - 1, body.height - 1], radius=26, fill=(28, 28, 30))
    body.paste(scr, (mx, top))
    d.rectangle([mx - 1, top - 1, mx + SCREEN_W, top + SCREEN_H], outline=(60, 60, 64))
    wm = "GARMIN  EDGE"
    d.text(((body.width - d.textlength(wm, font=small)) / 2, top + SCREEN_H + 22), wm,
           font=small, fill=(150, 150, 154))
    return body

screens = []
for i in range(n):
    scr = render_screen(i)
    dev = with_bezel(scr)
    dev.save(os.path.join(SAMP, f"device_{i:02d}.png"))
    screens.append(dev)

screens[0].save(os.path.join(SAMP, "garmin_display.gif"), save_all=True,
                append_images=screens[1:], duration=FRAME_MS, loop=0, optimize=True)
print(f"wrote {n} device_*.png stills + garmin_display.gif ({n} frames @ {FRAME_MS}ms)")
