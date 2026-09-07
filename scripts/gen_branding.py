#!/usr/bin/env python3
"""Generate LightOffice branding assets (splash, window icons, about logo).

Deterministic: re-running produces byte-identical output, so the checksums in
artifacts/checksums.txt stay stable across rebuilds.
"""
import os, sys
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "overlay", "branding")

LATIN = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
LATIN_R = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
CJK = "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc"

# Palette shared with theme_lightwps.json
BLUE = (30, 111, 186)
BLUE_DK = (23, 85, 143)
RED = (214, 58, 47)
GREEN = (31, 138, 84)
INK = (61, 68, 77)
GREY = (110, 118, 128)


def font(path, size):
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return ImageFont.load_default()


def vgradient(size, top, bottom):
    w, h = size
    img = Image.new("RGB", (1, h))
    px = img.load()
    for y in range(h):
        t = y / max(h - 1, 1)
        px[0, y] = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    return img.resize(size, Image.BILINEAR)


def doc_mark(draw, x, y, s, colour):
    """A stylised document sheet with a folded corner."""
    fold = s * 0.34
    draw.polygon(
        [(x, y), (x + s - fold, y), (x + s, y + fold), (x + s, y + s * 1.28), (x, y + s * 1.28)],
        fill=colour,
    )
    draw.polygon([(x + s - fold, y), (x + s, y + fold), (x + s - fold, y + fold)],
                 fill=tuple(min(255, c + 55) for c in colour))
    for i in range(3):
        ly = y + s * (0.52 + i * 0.22)
        draw.rounded_rectangle([x + s * 0.18, ly, x + s * 0.82, ly + s * 0.09],
                               radius=s * 0.045, fill=(255, 255, 255))


def make_splash(w=600, h=300):
    img = vgradient((w, h), (250, 251, 253), (231, 237, 245))
    d = ImageDraw.Draw(img)

    # accent bar carrying the three app colours
    for i, c in enumerate((BLUE, GREEN, RED)):
        d.rectangle([w * i / 3, h - 6, w * (i + 1) / 3, h], fill=c)

    doc_mark(d, 56, 96, 74, BLUE)

    d.text((166, 104), "LightOffice", font=font(LATIN, 52), fill=BLUE_DK)
    d.text((170, 166), "轻量版办公套件", font=font(CJK, 25), fill=INK)
    d.text((170, 205), "Powered by ONLYOFFICE · 内网协作版",
           font=font(CJK, 14), fill=GREY)
    d.line([(166, 158), (166 + 300, 158)], fill=(206, 214, 224), width=1)
    return img


def make_about(w=420, h=140):
    img = Image.new("RGB", (w, h), (255, 255, 255))
    d = ImageDraw.Draw(img)
    doc_mark(d, 24, 34, 46, BLUE)
    d.text((94, 40), "LightOffice", font=font(LATIN, 34), fill=BLUE_DK)
    d.text((97, 84), "轻量版办公套件", font=font(CJK, 17), fill=GREY)
    return img


def make_icon(px):
    img = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    r = px * 0.22
    d.rounded_rectangle([0, 0, px - 1, px - 1], radius=r, fill=BLUE)
    s = px * 0.44
    x = (px - s) / 2
    y = (px - s * 1.28) / 2
    fold = s * 0.34
    d.polygon([(x, y), (x + s - fold, y), (x + s, y + fold),
               (x + s, y + s * 1.28), (x, y + s * 1.28)], fill=(255, 255, 255))
    d.polygon([(x + s - fold, y), (x + s, y + fold), (x + s - fold, y + fold)],
              fill=(214, 226, 240))
    if px >= 32:
        for i in range(3):
            ly = y + s * (0.52 + i * 0.22)
            d.rounded_rectangle([x + s * 0.18, ly, x + s * 0.82, ly + s * 0.09],
                                radius=max(1, s * 0.045), fill=BLUE)
    return img


def main():
    os.makedirs(OUT, exist_ok=True)
    make_splash().save(os.path.join(OUT, "splash.png"), optimize=True)
    make_about().save(os.path.join(OUT, "about_logo.png"), optimize=True)

    sizes = [16, 24, 32, 48, 64, 128, 256]
    icons = [make_icon(s) for s in sizes]
    for s, im in zip(sizes, icons):
        im.save(os.path.join(OUT, f"lightoffice_{s}.png"), optimize=True)
    # Windows .ico carrying every size
    icons[-1].save(os.path.join(OUT, "lightoffice.ico"),
                   sizes=[(s, s) for s in sizes])
    print("branding assets written to", OUT)
    for f in sorted(os.listdir(OUT)):
        print("  ", f, os.path.getsize(os.path.join(OUT, f)), "bytes")


if __name__ == "__main__":
    main()
