#!/usr/bin/env python3
"""Draw the app icon (a blank key with a pixel I-beam) as three 1024px PNGs
into AppIcon.appiconset: light, dark and tinted. Rectangles only, on whole
pixels, so no SVG renderer is needed.

    python3 tools/make_icon.py
"""
import json, pathlib, struct, zlib

OUT = pathlib.Path(__file__).resolve().parent.parent / \
    "gentence-senerator/gentence-senerator/Assets.xcassets/AppIcon.appiconset"
S = 1024
U = 34  # one cursor pixel

# Geometry, in icon pixels.
FACE = (164, 164, 594, 594)        # x, y, w, h
SHADOW = (287, 287, 594, 594)      # the face, pushed down and right
CX, TOP = 358, 276                 # I-beam centre and top


def ibeam():
    stem = (CX - U // 2, TOP + U, U, 9 * U)
    caps = []
    for y in (TOP, TOP + 10 * U):
        caps += [(CX - U // 2 - 2 * U, y, 2 * U, U), (CX + U // 2, y, 2 * U, U)]
    return [stem] + caps


VARIANTS = {
    # name: (ground, shadow, face, cursor); None = transparent
    "icon-light.png":  ((0xA8, 0x48, 0x1A), (0x6E, 0x2C, 0x0C), (0xF2, 0xF0, 0xE8), (0x23, 0x25, 0x1F)),
    # iOS draws its own dark backdrop behind a transparent dark icon.
    "icon-dark.png":   (None, (0xA8, 0x48, 0x1A), (0xE3, 0xE1, 0xD5), (0x19, 0x1B, 0x16)),
    # Tinted icons are read as luminance; the system supplies the colour.
    "icon-tinted.png": ((0x00, 0x00, 0x00), (0x55, 0x55, 0x55), (0xF0, 0xF0, 0xF0), (0x00, 0x00, 0x00)),
}


def render(ground, shadow, face, cursor):
    px = bytearray(S * S * 4)
    def fill(rect, rgb):
        x, y, w, h = rect
        row = bytes(rgb) + b"\xff"
        for yy in range(y, y + h):
            start = (yy * S + x) * 4
            px[start:start + w * 4] = row * w
    if ground:
        fill((0, 0, S, S), ground)
    fill(SHADOW, shadow)
    fill(FACE, face)
    for r in ibeam():
        fill(r, cursor)
    return px


def png(pixels):
    raw = b"".join(b"\x00" + bytes(pixels[y * S * 4:(y + 1) * S * 4]) for y in range(S))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", S, S, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def main():
    for name, colours in VARIANTS.items():
        (OUT / name).write_bytes(png(render(*colours)))
    contents = json.loads((OUT / "Contents.json").read_text())
    for image in contents["images"]:
        look = next((a["value"] for a in image.get("appearances", [])), "light")
        image["filename"] = f"icon-{look}.png"
    (OUT / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    print("wrote", ", ".join(VARIANTS))


if __name__ == "__main__":
    main()
