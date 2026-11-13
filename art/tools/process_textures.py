"""Turn the chosen raw generations into the app's skin textures (batch 1).

Run with any Python that has numpy, scipy and Pillow, e.g. ComfyUI's venv:
    ~/AI/ComfyUI/current/.venv/bin/python -I art/tools/process_textures.py

Reads art/textures/raw/, writes art/textures/*.png and copies them into Sources/msg-app/Skin/.
Targets are the ones in art/textures.md.
"""
import shutil
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter

ROOT = Path(__file__).resolve().parents[2]
RAW, OUT, APP = ROOT / "art/textures/raw", ROOT / "art/textures", ROOT / "Sources/msg-app/Skin"


def load(name):
    return np.asarray(Image.open(RAW / name).convert("RGB"), dtype=np.float64) / 255


def save(arr, name, alpha=None):
    rgb = (np.clip(arr, 0, 1) * 255 + 0.5).astype(np.uint8)
    img = Image.fromarray(rgb, "RGB")
    if alpha is not None:
        img.putalpha(Image.fromarray((np.clip(alpha, 0, 1) * 255 + 0.5).astype(np.uint8), "L"))
    img.save(OUT / name, optimize=True)
    shutil.copy(OUT / name, APP / name)
    print("wrote", name, img.size)


def srgb(hex_):
    return np.array([int(hex_[i:i + 2], 16) for i in (1, 3, 5)]) / 255


def flatten(arr, sigma):
    """Remove light falloff and blotches bigger than ~sigma pixels, keeping the fine grain."""
    low = np.stack([gaussian_filter(arr[..., c], sigma) for c in range(3)], -1)
    return arr - low + low.mean(axis=(0, 1))


def tone(arr, target, detail, saturation):
    """Set the average colour to `target` and the grain's spread to `detail` (std dev, 0-1)."""
    lum = arr.mean(-1, keepdims=True)
    arr = lum + (arr - lum) * saturation
    dev = arr - arr.mean(axis=(0, 1))
    dev *= detail / max(dev.std(), 1e-6)
    return target + dev


def seamless(arr, band=128):
    """Cross-fade each edge with the opposite one, so the texture tiles without a seam."""
    h, w, _ = arr.shape
    out = arr.copy()
    ramp = np.linspace(0, 1, band)[:, None]
    # Rolled copy has the seams in the middle; blend its middle back over the edges.
    rolled = np.roll(arr, (h // 2, w // 2), (0, 1))
    mask = np.zeros((h, w))
    for i in range(band):
        f = 1 - i / band
        mask[i, :] = np.maximum(mask[i, :], f)
        mask[h - 1 - i, :] = np.maximum(mask[h - 1 - i, :], f)
        mask[:, i] = np.maximum(mask[:, i], f)
        mask[:, w - 1 - i] = np.maximum(mask[:, w - 1 - i], f)
    mask = 0.5 * mask[..., None]  # at the very edge, half and half with the rolled copy
    out = arr * (1 - mask) + rolled * mask
    # Make the opposite edges agree exactly.
    out[-1, :] = out[0, :]
    out[:, -1] = out[:, 0]
    return out


def panel():
    a = load("panel-303-klein.png")
    a = flatten(a, 60)
    a = tone(a, srgb("#2B2B2D"), detail=0.012, saturation=0.25)
    a = seamless(a)
    save(a, "panel.png")


def knob_cap():
    a = load("knob-cap-404-klein.png")
    lum = a.mean(-1)
    ys, xs = np.nonzero(lum > 0.06)
    cy, cx = (ys.min() + ys.max()) / 2, (xs.min() + xs.max()) / 2
    r = min(ys.max() - ys.min(), xs.max() - xs.min()) / 2 * 0.95  # inside the outer rim
    size = 512
    img = Image.fromarray((a * 255).astype(np.uint8)).crop((cx - r, cy - r, cx + r, cy + r)).resize((size, size), Image.LANCZOS)
    c = np.asarray(img, dtype=np.float64) / 255
    lum = c.mean(-1, keepdims=True)
    c = lum + (c - lum) * 0.3                           # nearly neutral graphite
    c = c - c.mean(axis=(0, 1)) + srgb("#3A3A3D")       # average face tone
    yy, xx = np.mgrid[0:size, 0:size]
    d = np.hypot(yy - size / 2 + 0.5, xx - size / 2 + 0.5) / (size / 2)
    alpha = np.clip((1 - d) * size / 2, 0, 1)           # 1 px antialiased edge
    save(c, "knob-cap.png", alpha)


def lcd():
    a = load("lcd-404-klein.png")
    h, w, _ = a.shape
    a = a[:, int(w * 0.02): int(w * 0.98)]              # trim the darker side strips
    a = np.asarray(Image.fromarray((a * 255).astype(np.uint8)).resize((1536, 512), Image.LANCZOS), dtype=np.float64) / 255
    # Soften big blotches but keep a gentle centre-bright backlight and fine mottling.
    low = np.stack([gaussian_filter(a[..., c], 90) for c in range(3)], -1)
    a = a - low * 0.6 + low.mean(axis=(0, 1)) * 0.6
    yy, xx = np.mgrid[0:512, 0:1536]
    glow = 1 + 0.08 * np.exp(-(((xx - 768) / 700) ** 2 + ((yy - 256) / 300) ** 2))
    a = tone(a, srgb("#1F2620"), detail=0.012, saturation=0.6) * glow[..., None]
    save(a, "lcd.png")


if __name__ == "__main__":
    APP.mkdir(parents=True, exist_ok=True)
    for job in (panel, knob_cap, lcd):
        job()
    sys.exit(0)
