#!/usr/bin/env python3
"""Generate movie-style tower and floor textures for The Gibson.

Outputs grayscale-in-RGB + alpha PNGs; the cyan/violet hue is applied in code
(gibson_tint in GibsonSCNScene.mm) so the grade stays tunable in one place.

Tower texture layout (512x1536, matches media/towers.obj UVs):
  rows    0..511   top/bottom caps
  rows  512..1535  the four side faces, image bottom = tower base
The side face is 9.1 x 34.4 world units but gets 512 x 1024 px, so text is
drawn on a taller virtual canvas and squashed to keep glyphs square.

Usage:  tools/.venv/bin/python tools/gen_textures.py [--out media] [--seed 1995]
"""
import argparse
import random
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W = 512
SIDE_H = 1024
CAP_H = 512
FRAMES = 8
SS = 2  # supersample factor
FACE_ASPECT = 34.383 / 9.125  # side face height / width in world units
VIRT_H = int(W * FACE_ASPECT)  # virtual side canvas height for square glyphs

FONT_PATHS = [
    "/System/Library/Fonts/Menlo.ttc",
    "/System/Library/Fonts/Monaco.ttf",
    "/System/Library/Fonts/SFNSMono.ttf",
]

WORDS = [
    "SYS", "CPU", "MEM", "ERR", "LD", "MOV", "JMP", "NOP", "XOR", "CALL", "RET",
    "R606", "7P57", "CH57", "IDLE", "PRO", "CONF", "STAT", "LOG", "DUMP", "SEG",
    "ACCT", "GARB", "ELLIS", "DA VINCI", "PLAGUE", "KERN", "ROOT", "TTY", "UID",
    "::", ">>", "<<", "##", "--", "==",
]


def load_font(px):
    for p in FONT_PATHS:
        try:
            return ImageFont.truetype(p, px)
        except OSError:
            continue
    return ImageFont.load_default()


def token(rng):
    r = rng.random()
    if r < 0.35:
        return "".join(rng.choice("0123456789ABCDEF") for _ in range(rng.randint(2, 8)))
    if r < 0.55:
        return "".join(rng.choice("01") for _ in range(rng.randint(4, 12)))
    if r < 0.85:
        return rng.choice(WORDS)
    return str(rng.randint(0, 99999))


def line_text(rng, max_chars):
    parts, n = [], 0
    target = rng.randint(max(3, max_chars // 4), max_chars)
    while n < target:
        t = token(rng)
        parts.append(t)
        n += len(t) + 1
    return " ".join(parts)[:max_chars]


def layout(rng, width, height, font_px, line_px):
    """Column blocks of short text lines, plus a few small framed 'windows'."""
    char_w = font_px * 0.6
    items = []  # (kind, x, y, w, h_or_text, level)
    x = 6 * SS
    while x < width - 40 * SS:
        col_chars = rng.randint(5, 12)
        col_w = int(col_chars * char_w)
        y = rng.randint(0, 4) * line_px
        while y < height - line_px:
            if rng.random() < 0.012:  # rare small panels
                bw = int(col_w * rng.uniform(0.5, 1.0))
                bh = line_px * rng.randint(3, 7)
                items.append(("box", x, y, bw, bh, rng.choice([0.55, 0.75, 1.0])))
                y += bh + line_px
                continue
            block = rng.randint(3, 14)
            level = rng.choice([0.8, 0.9, 1.0, 1.0])
            for _ in range(block):
                if y >= height - line_px:
                    break
                items.append(("text", x, y, col_chars, line_text(rng, col_chars), level))
                y += line_px
            y += line_px * rng.randint(2, 6)
        x += col_w + int(char_w * rng.randint(2, 4))
    return items


def draw_items(items, size, font, rng, flicker, ink, bg, stroke=0):
    img = Image.new("LA", size, (int(bg[0] * 255), int(bg[1] * 255)))
    d = ImageDraw.Draw(img)
    for kind, x, y, w, payload, level in items:
        if kind == "box":
            v = int(255 * ink * level)
            d.rectangle([x, y, x + w, y + payload], outline=(v, 255), width=SS)
            # a couple of tiny lines inside, like the movie's little panels
            for i in range(2, payload // (font.size + 4)):
                yy = y + i * (font.size + 4) - font.size // 2
                if yy + font.size < y + payload:
                    d.text((x + 3 * SS, yy), line_text(rng, max(3, w // int(font.size * 0.6) - 1)),
                           font=font, fill=(int(v * 0.8), 255))
            continue
        text = payload
        if rng.random() < flicker:
            text = line_text(rng, w)
        if rng.random() < flicker * 0.5:
            continue  # line blinks off this frame
        v = int(255 * min(1.0, ink * level))
        d.text((x, y), text, font=font, fill=(v, 255), stroke_width=stroke, stroke_fill=(v, 255))
    return img


def vertical_ramp(h, bottom_boost, span):
    """0 at top .. 1 at bottom over the last `span` fraction, eased."""
    y = np.linspace(0, 1, h)
    t = np.clip((y - (1 - span)) / span, 0, 1)
    return (t * t) * bottom_boost


def finish_side(img, base_glow, edge, glass):
    """Squash virtual canvas to 512x1024, add glowing base and edges."""
    img = img.resize((W, SIDE_H), Image.LANCZOS)
    a = np.asarray(img).astype(np.float32) / 255.0
    lum, alpha = a[..., 0], a[..., 1]
    ramp = vertical_ramp(SIDE_H, base_glow, 0.22)[:, None]
    lum = np.clip(lum + ramp, 0, 1)
    alpha = np.clip(np.maximum(alpha, glass) + ramp * 0.6, 0, 1)
    # soft bright vertical edges (the movie's glowing glass corners)
    xs = np.arange(W)
    dist = np.minimum(xs, W - 1 - xs).astype(np.float32)
    e = np.exp(-dist / 3.0)[None, :] * edge
    # bright rims along the top and bottom of each face, so towers read as boxes
    ys = np.arange(SIDE_H).astype(np.float32)
    rim = np.exp(-np.minimum(ys, SIDE_H - 1 - ys) / 3.0)[:, None] * edge
    e = np.maximum(e, rim)
    lum = np.clip(lum + e, 0, 1)
    alpha = np.clip(alpha + e, 0, 1)
    return lum, alpha


def make_cap(rng, value, alpha):
    img = Image.new("LA", (W, CAP_H), (int(value * 255), int(alpha * 255)))
    d = ImageDraw.Draw(img)
    for i in range(0, W, 32):
        v = int(255 * min(1, value + 0.08))
        d.line([(i, 0), (i, CAP_H)], fill=(v, int(alpha * 255)), width=1)
        d.line([(0, i), (W, i)], fill=(v, int(alpha * 255)), width=1)
    img = img.filter(ImageFilter.GaussianBlur(1.2))
    a = np.asarray(img).astype(np.float32) / 255.0
    return a[..., 0], a[..., 1]


def to_rgba(lum, alpha):
    l8 = (np.clip(lum, 0, 1) * 255).astype(np.uint8)
    a8 = (np.clip(alpha, 0, 1) * 255).astype(np.uint8)
    return Image.fromarray(np.dstack([l8, l8, l8, a8]), "RGBA")


def tower_set(prefix, out, seed, dark):
    rng = random.Random(seed)
    font_px = 15 * SS
    line_px = 18 * SS
    font = load_font(font_px)
    size = (W * SS, VIRT_H * SS)
    items = layout(rng, size[0], size[1], font_px, line_px)
    # Both kinds are dark, see-through glass with glowing text; "light"
    # towers are just a little lighter and clearer than "dark" ones.
    if dark:
        ink, bg, glass, base_glow, edge = 0.95, (0.03, 0.55), 0.55, 0.25, 1.0
        cap = make_cap(rng, 0.30, 0.6)
    else:
        ink, bg, glass, base_glow, edge = 1.0, (0.10, 0.32), 0.32, 0.30, 1.0
        cap = make_cap(rng, 0.45, 0.5)
    for f in range(FRAMES):
        frng = random.Random(seed * 100 + f)
        side = draw_items(items, size, font, frng, flicker=0.0 if f == 0 else 0.12, ink=ink, bg=bg,
                          stroke=1)
        if not dark:
            # bright white-hot fragments on light towers
            hot = draw_items(items, size, font, random.Random(seed * 7 + f), 0.6, 1.0, (0.0, 0.0))
            ha = np.asarray(hot).astype(np.float32) / 255.0
            sa = np.asarray(side).astype(np.float32) / 255.0
            mask = (ha[..., 0] > 0.5) & (np.random.default_rng(seed + f).random(ha.shape[:2]) < 0.18)
            sa[..., 0] = np.where(mask, 1.0, sa[..., 0])
            side = Image.fromarray((sa * 255).astype(np.uint8), "LA")
        lum, alpha = finish_side(side, base_glow, edge, glass)
        full_l = np.vstack([cap[0], lum])
        full_a = np.vstack([cap[1], alpha])
        path = out / f"{prefix}-{f + 1}.png"
        to_rgba(full_l, full_a).save(path, optimize=True)
        print("wrote", path)


def floor(out, src):
    """Thicken the existing circuit traces, add a soft halo and a navy base."""
    img = Image.open(src).convert("L")
    thick = img  # keep bundles of parallel traces separate
    halo = thick.filter(ImageFilter.GaussianBlur(4))
    a = np.asarray(thick).astype(np.float32) / 255.0
    h = np.asarray(halo).astype(np.float32) / 255.0
    lum = np.clip(np.maximum(a, h * 0.45) + 0.04, 0, 1)
    l8 = (lum * 255).astype(np.uint8)
    path = out / "room.png"
    Image.fromarray(np.dstack([l8, l8, l8]), "RGB").save(path, optimize=True)
    print("wrote", path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="media")
    ap.add_argument("--seed", type=int, default=1995)
    ap.add_argument("--floor-src", default=None,
                    help="original floor art (default: media/room_src.png)")
    args = ap.parse_args()
    out = Path(args.out)
    tower_set("towers1", out, args.seed, dark=True)
    tower_set("towers2", out, args.seed + 1, dark=False)
    src = Path(args.floor_src) if args.floor_src else out / "room_src.png"
    floor(out, src)


if __name__ == "__main__":
    main()
