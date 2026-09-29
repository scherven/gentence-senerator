"""Writes the paper grain tile and the stamp speckle mask into Assets.xcassets.

Fixed seeds: re-running produces identical files.
"""
import json
import os
import random

from PIL import Image, ImageFilter

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "gentence-senerator",
                    "gentence-senerator", "Assets.xcassets")


def imageset(name, image):
    folder = os.path.join(ROOT, f"{name}.imageset")
    os.makedirs(folder, exist_ok=True)
    image.save(os.path.join(folder, f"{name}@2x.png"), optimize=True)
    contents = {
        "images": [
            {"idiom": "universal", "scale": "1x"},
            {"idiom": "universal", "filename": f"{name}@2x.png", "scale": "2x"},
            {"idiom": "universal", "scale": "3x"},
        ],
        "info": {"author": "xcode", "version": 1},
        "properties": {"template-rendering-intent": "original"},
    }
    with open(os.path.join(folder, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)


def grain(size=512, seed=7):
    """Greyscale paper noise, mid-grey centred: fine per-pixel noise plus a
    soft fibre layer. 256pt at @2x."""
    rng = random.Random(seed)
    fine = Image.new("L", (size, size))
    fine.putdata([max(0, min(255, int(rng.gauss(128, 46)))) for _ in range(size * size)])
    small = size // 4
    coarse = Image.new("L", (small, small))
    coarse.putdata([rng.randint(70, 190) for _ in range(small * small)])
    coarse = coarse.resize((size, size), Image.BICUBIC).filter(ImageFilter.GaussianBlur(3))
    return Image.blend(fine, coarse, 0.35)


def speckle(size=256, seed=11):
    """Alpha mask for rubber stamps: opaque with small ink-starved holes."""
    rng = random.Random(seed)
    alpha = Image.new("L", (size, size), 255)
    px = alpha.load()
    for _ in range(int(size * size * 0.018)):
        x, y = rng.randrange(size), rng.randrange(size)
        r = rng.choice([0, 0, 0, 1])
        for dx in range(-r, r + 1):
            for dy in range(-r, r + 1):
                px[(x + dx) % size, (y + dy) % size] = rng.randint(0, 90)
    alpha = alpha.filter(ImageFilter.GaussianBlur(0.6))
    out = Image.new("RGBA", (size, size), (0, 0, 0, 255))
    out.putalpha(alpha)
    return out


if __name__ == "__main__":
    imageset("Grain", grain())
    imageset("Speckle", speckle())
    print("wrote Grain, Speckle")
