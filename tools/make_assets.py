"""Builds the plugin's images from the Tracy-Luau logo artwork.

    python tools/make_assets.py LOGO_DARK_TEXT.webp LOGO_LIGHT_TEXT.webp

The inputs are the bracket-style logo in its dark-text and light-text versions
(transparent backgrounds). Writes to assets/:
  logo-dark.png    dark text, for Studio's light theme
  logo-light.png   light text, for Studio's dark theme
  icon.png         the blue "<_n_>" mark, square, for the toolbar button
"""
import os
import sys

from PIL import Image

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets")
LOGO_WIDTH = 720
ICON_SIZE = 128


def trimmed(im):
    return im.crop(im.getchannel("A").point(lambda a: 255 if a > 16 else 0).getbbox())


def is_blue(r, g, b, a):
    return a > 64 and b > 150 and b > r + 60 and b > g + 20


def blue_only(im):
    out = Image.new("RGBA", im.size, (0, 0, 0, 0))
    src, dst = im.load(), out.load()
    for y in range(im.height):
        for x in range(im.width):
            if is_blue(*src[x, y]):
                dst[x, y] = src[x, y]
    return out


def columns_with_ink(im):
    alpha = im.getchannel("A").load()
    return [any(alpha[x, y] > 64 for y in range(im.height)) for x in range(im.width)]


def runs(flags):
    spans, start = [], None
    for i, on in enumerate(flags + [False]):
        if on and start is None:
            start = i
        elif not on and start is not None:
            spans.append((start, i))
            start = None
    return spans


def icon_from(logo):
    # The blue parts, left to right: "<", the step pulse, ">". Put them side by side.
    blue = trimmed(blue_only(logo))
    spans = [s for s in runs(columns_with_ink(blue)) if s[1] - s[0] > 8]
    left, right = spans[0], spans[-1]
    pulse = max(spans[1:-1], key=lambda s: s[1] - s[0])
    parts = [trimmed(blue.crop((a, 0, b, blue.height))) for a, b in (left, pulse, right)]
    height = max(p.height for p in parts)
    gap = parts[0].width // 5
    width = sum(p.width for p in parts) + gap * 2
    mark = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    x = 0
    for p in parts:
        mark.paste(p, (x, (height - p.height) // 2), p)
        x += p.width + gap
    side = int(max(width, height) * 1.12)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(mark, ((side - width) // 2, (side - height) // 2), mark)
    return square.resize((ICON_SIZE, ICON_SIZE), Image.LANCZOS)


def main():
    dark_text, light_text = (Image.open(p).convert("RGBA") for p in sys.argv[1:3])
    os.makedirs(OUT, exist_ok=True)
    for name, im in (("logo-dark.png", dark_text), ("logo-light.png", light_text)):
        logo = trimmed(im)
        logo = logo.resize((LOGO_WIDTH, round(logo.height * LOGO_WIDTH / logo.width)), Image.LANCZOS)
        logo.save(os.path.join(OUT, name))
        print(name, logo.size)
    icon = icon_from(dark_text)
    icon.save(os.path.join(OUT, "icon.png"))
    print("icon.png", icon.size)


if __name__ == "__main__":
    main()
