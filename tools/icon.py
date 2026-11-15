#!/usr/bin/env python3
"""Generates Setlist's launcher icon from one set of shapes: the Android adaptive icon layers, docs/icon.svg and docs/icon.png.

Run from the repository root: `python3 tools/icon.py [preview-dir]`. With a preview directory it also writes launcher-shaped previews at 432, 144 and 48 px and a themed-icon preview.
"""
import os
import sys

from PIL import Image, ImageDraw

BACKGROUND = "#2F5D57"
LIGHT = "#F4F1EA"
AMBER = "#F2B33D"
DARK = "#1E3F3B"

# All coordinates are on Android's 108 x 108 adaptive icon canvas. Launchers crop to a shape inside the central 66 x 66; the glyph keeps to a 48-unit width so it does not crowd any mask.
BAR = [(30, 52.5, 15, 3, 1.5), (63, 52.5, 15, 3, 1.5)]
PLATES = [(37, 40, 5.5, 28, 2.2), (65.5, 40, 5.5, 28, 2.2), (32.5, 45, 4, 18, 1.6), (71.5, 45, 4, 18, 1.6)]
DISC = (54, 54, 7.5)
CHECK = [(50.6, 54.3), (53.1, 56.8), (57.6, 51.9)]
CHECK_WIDTH = 2.3
RING_WIDTH = 1.8


def rect_path(x, y, w, h, r):
    return f"M{x + r},{y}h{w - 2 * r}a{r},{r} 0 0 1 {r},{r}v{h - 2 * r}a{r},{r} 0 0 1 -{r},{r}h-{w - 2 * r}a{r},{r} 0 0 1 -{r},-{r}v-{h - 2 * r}a{r},{r} 0 0 1 {r},-{r}z"


def circle_path(cx, cy, r):
    return f"M{cx - r},{cy}a{r},{r} 0 1 0 {2 * r},0a{r},{r} 0 1 0 -{2 * r},0z"


def check_path():
    (x0, y0), *rest = CHECK
    return f"M{x0},{y0}" + "".join(f"L{x},{y}" for x, y in rest)


def argb(color):
    return "#FF" + color[1:]


def vector(paths):
    body = "\n".join(f"    <path {attrs} />" for attrs in paths)
    return f'<vector xmlns:android="http://schemas.android.com/apk/res/android"\n    android:width="108dp"\n    android:height="108dp"\n    android:viewportWidth="108"\n    android:viewportHeight="108">\n{body}\n</vector>\n'


def fill(d, color):
    return f'android:fillColor="{argb(color)}" android:pathData="{d}"'


def stroke(d, color, width):
    return f'android:strokeColor="{argb(color)}" android:strokeWidth="{width}" android:strokeLineCap="round" android:strokeLineJoin="round" android:pathData="{d}"'


def foreground_xml():
    shapes = [fill(rect_path(*b), LIGHT) for b in BAR] + [fill(rect_path(*p), LIGHT) for p in PLATES]
    return vector(shapes + [fill(circle_path(*DISC), AMBER), stroke(check_path(), DARK, CHECK_WIDTH)])


def monochrome_xml():
    # Themed icons tint one colour, so the disc becomes a ring around the check instead of a filled badge.
    cx, cy, r = DISC
    shapes = [fill(rect_path(*b), "#000000") for b in BAR] + [fill(rect_path(*p), "#000000") for p in PLATES]
    return vector(shapes + [stroke(circle_path(cx, cy, r - RING_WIDTH / 2), "#000000", RING_WIDTH), stroke(check_path(), "#000000", CHECK_WIDTH)])


def svg():
    cx, cy, r = DISC
    rects = "".join(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rr}" fill="{LIGHT}"/>' for x, y, w, h, rr in BAR + PLATES)
    points = " ".join(f"{x},{y}" for x, y in CHECK)
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="21 21 66 66">'
        f'<rect x="21" y="21" width="66" height="66" rx="15" fill="{BACKGROUND}"/>{rects}'
        f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{AMBER}"/>'
        f'<polyline points="{points}" fill="none" stroke="{DARK}" stroke-width="{CHECK_WIDTH}" stroke-linecap="round" stroke-linejoin="round"/></svg>\n'
    )


def render(size, monochrome=False, scale=8):
    """Draws the full 108-unit canvas at size px, supersampled for smooth edges."""
    s = size * scale / 108
    big = Image.new("RGBA", (size * scale, size * scale), "#E3E7E6" if monochrome else BACKGROUND)
    draw = ImageDraw.Draw(big)
    ink = "#29433F" if monochrome else LIGHT
    for x, y, w, h, r in BAR + PLATES:
        draw.rounded_rectangle([x * s, y * s, (x + w) * s, (y + h) * s], radius=r * s, fill=ink)
    cx, cy, r = DISC
    if monochrome:
        draw.ellipse([(cx - r) * s, (cy - r) * s, (cx + r) * s, (cy + r) * s], outline=ink, width=round(RING_WIDTH * s))
        check_color = ink
    else:
        draw.ellipse([(cx - r) * s, (cy - r) * s, (cx + r) * s, (cy + r) * s], fill=AMBER)
        check_color = DARK
    points = [(x * s, y * s) for x, y in CHECK]
    width = CHECK_WIDTH * s
    draw.line(points, fill=check_color, width=round(width), joint="curve")
    for x, y in (points[0], points[-1]):
        draw.ellipse([x - width / 2, y - width / 2, x + width / 2, y + width / 2], fill=check_color)
    return big.resize((size, size), Image.LANCZOS)


def masked(image, crop=66 / 108, radius_ratio=0.5):
    """Crops to the launcher's visible 66-unit square and rounds it, as a circle (0.5) or a rounded square (smaller ratio)."""
    size = image.width
    inset = round(size * (1 - crop) / 2)
    visible = image.crop((inset, inset, size - inset, size - inset))
    mask = Image.new("L", visible.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, visible.width - 1, visible.height - 1], radius=visible.width * radius_ratio, fill=255)
    visible.putalpha(mask)
    return visible


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def main():
    res = "android/app/src/main/res"
    write(f"{res}/drawable/ic_launcher_foreground.xml", foreground_xml())
    write(f"{res}/drawable/ic_launcher_monochrome.xml", monochrome_xml())
    write(f"{res}/values/ic_launcher_background.xml", f'<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <color name="ic_launcher_background">{BACKGROUND}</color>\n</resources>\n')
    write(
        f"{res}/mipmap-anydpi-v26/ic_launcher.xml",
        '<?xml version="1.0" encoding="utf-8"?>\n<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n    <background android:drawable="@color/ic_launcher_background" />\n    <foreground android:drawable="@drawable/ic_launcher_foreground" />\n    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />\n</adaptive-icon>\n',
    )
    write("docs/icon.svg", svg())
    masked(render(512 * 108 // 66 + 1), radius_ratio=0.23).resize((512, 512), Image.LANCZOS).save("docs/icon.png")
    if len(sys.argv) > 1:
        out = sys.argv[1]
        os.makedirs(out, exist_ok=True)
        for px in (432, 144, 48):
            masked(render(round(px * 108 / 66))).resize((px, px), Image.LANCZOS).save(f"{out}/circle-{px}.png")
            masked(render(round(px * 108 / 66)), radius_ratio=0.3).resize((px, px), Image.LANCZOS).save(f"{out}/squircle-{px}.png")
        masked(render(round(144 * 108 / 66), monochrome=True)).resize((144, 144), Image.LANCZOS).save(f"{out}/themed-144.png")


if __name__ == "__main__":
    main()
