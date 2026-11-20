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


def finish_floor(img, out, halo=0.45):
    """Soft halo and a faint base under the traces, saved as media/room.png."""
    blur = img.filter(ImageFilter.GaussianBlur(4))
    a = np.asarray(img).astype(np.float32) / 255.0
    h = np.asarray(blur).astype(np.float32) / 255.0
    lum = np.clip(np.maximum(a, h * halo) + 0.04, 0, 1)
    l8 = (lum * 255).astype(np.uint8)
    path = out / "room.png"
    Image.fromarray(np.dstack([l8, l8, l8]), "RGB").save(path, optimize=True)
    print("wrote", path)


# Floor traces inferred from the film (tools/trace_analysis.py on stills from
# all three clips, rectified to top-down): uniform orthogonal traces, gaps
# between parallel lines ~0.7x the line width, ~15% of the floor covered,
# buses of 2-3 lines with occasional wide 6-10 line buses that jog sideways in
# nested-L staircases, single traces with right-angle bends ending in square
# pads, inline paired-bracket and oval pads, and short stubs off junctions.
#
# The film's floor reads as one big board, not a uniform mix, so the floor is
# a 3x3 macro tile laid out like a PCB: a few wide "lanes" (buses) cross the
# whole tile at irregular spacing, carving it into blocks, and each block gets
# a role -- a chip footprint with pins fanning out, local buses, sparse singles
# with components, or empty -- so neighbourhoods differ.
TRACE_W = 8               # line width, px
TRACE_GAP = 6             # gap between bundled lines (~0.7 x width)
PITCH = TRACE_W + TRACE_GAP
CELLS_PER_TILE = 72       # one 1008 px tile = 72 cells
MACRO = 3                 # macro tile = 3 x 3 tiles = 216 cells = 3024 px
GRID = CELLS_PER_TILE * MACRO
TILE = GRID * PITCH
BUS_SIZES = [2, 3, 4, 6, 8, 10]
BUS_WEIGHTS = [0.32, 0.28, 0.14, 0.12, 0.08, 0.06]
LANE_SIZES = [3, 4, 5, 6]
FEEDER_SIZES = [2, 3]
BLOCK_ROLES = ["chip", "cluster", "bus", "sparse", "empty"]
BLOCK_WEIGHTS = [0.35, 0.30, 0.10, 0.15, 0.10]
BLOCK_BUS_MAX = 4         # buses inside blocks stay narrow; lanes are the wide ones
# connecting traces between chips/clusters
ROUTE_MAX_DIST = 110      # max Manhattan distance (cells) between joined pads
ROUTE_CANDIDATES = 12     # nearest partner pads tried per pad
ROUTE_PASSES = 2          # extra passes retry pads left unconnected
CHIPS_PER_BLOCK = (2, 4)
CLUSTERS_PER_BLOCK = (3, 5)
CLUSTER_PAD_P = 0.9       # chance a cluster trace end gets a pad (= a port)
LANE_TAP_P = 0.6          # chance a still-unconnected pad runs into a lane it faces


class TraceBoard:
    """Cell grid (toroidal, so the macro tile repeats) plus a drawing surface."""

    def __init__(self, rng):
        self.rng = rng
        self.used = np.zeros((GRID, GRID), bool)     # cells holding a trace
        self.keepout = np.zeros((GRID, GRID), bool)  # used + 1-cell clearance
        self.img = Image.new("L", (TILE, TILE), 0)
        self.d = ImageDraw.Draw(self.img)
        self.ports = []        # (cell, cluster id, outward dir): pad ends routes may join
        self.next_cluster = 0
        self.lane = np.zeros((GRID, GRID), bool)   # cells belonging to lanes
        self.routed = set()

    def new_cluster(self):
        self.next_cluster += 1
        return self.next_cluster

    # --- drawing with wraparound -------------------------------------
    def _rect(self, x0, y0, x1, y1):
        for dx in (-TILE, 0, TILE):
            for dy in (-TILE, 0, TILE):
                self.d.rectangle([x0 + dx, y0 + dy, x1 + dx, y1 + dy], fill=255)

    def _ellipse(self, x0, y0, x1, y1, width):
        for dx in (-TILE, 0, TILE):
            for dy in (-TILE, 0, TILE):
                self.d.ellipse([x0 + dx, y0 + dy, x1 + dx, y1 + dy], outline=255, width=width)

    def seg(self, a, b):
        """Straight run between two cells (same row or column), inclusive."""
        (x0, y0), (x1, y1) = a, b
        px0, px1 = sorted((x0 * PITCH, x1 * PITCH))
        py0, py1 = sorted((y0 * PITCH, y1 * PITCH))
        self._rect(px0, py0, px1 + TRACE_W - 1, py1 + TRACE_W - 1)

    def path(self, pts):
        for a, b in zip(pts, pts[1:]):
            self.seg(a, b)

    def pad(self, c, size=2.2):
        cx, cy = c[0] * PITCH + TRACE_W / 2, c[1] * PITCH + TRACE_W / 2
        r = TRACE_W * size / 2
        self._rect(cx - r, cy - r, cx + r, cy + r)

    def bracket_pair(self, c, horizontal):
        """Two facing pads across a gap in the line (the film's '-[ ]-')."""
        cx, cy = c[0] * PITCH + TRACE_W / 2, c[1] * PITCH + TRACE_W / 2
        long_, short = TRACE_W * 1.4, TRACE_W * 0.55
        g = TRACE_W * 0.5
        if horizontal:
            self._rect(cx - g - short * 2, cy - long_, cx - g, cy + long_)
            self._rect(cx + g, cy - long_, cx + g + short * 2, cy + long_)
        else:
            self._rect(cx - long_, cy - g - short * 2, cx + long_, cy - g)
            self._rect(cx - long_, cy + g, cx + long_, cy + g + short * 2)

    def oval(self, c, horizontal):
        cx, cy = c[0] * PITCH + TRACE_W / 2, c[1] * PITCH + TRACE_W / 2
        a, b = (TRACE_W * 1.8, TRACE_W * 1.1) if horizontal else (TRACE_W * 1.1, TRACE_W * 1.8)
        self._ellipse(cx - a, cy - b, cx + a, cy + b, max(2, TRACE_W // 2))

    # --- occupancy ----------------------------------------------------
    def free(self, cells, region=None):
        for x, y in cells:
            if region is not None:
                x0, y0, x1, y1 = region
                if not (x0 <= x < x1 and y0 <= y < y1):
                    return False
            if self.keepout[y % GRID, x % GRID]:
                return False
        return True

    def claim(self, cells):
        for x, y in cells:
            self.used[y % GRID, x % GRID] = True
        for x, y in cells:
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    self.keepout[(y + dy) % GRID, (x + dx) % GRID] = True

    def coverage(self, region=None):
        a = np.asarray(self.img) > 0
        if region is not None:
            x0, y0, x1, y1 = region
            a = a[y0 * PITCH:y1 * PITCH, x0 * PITCH:x1 * PITCH]
        return float(a.mean()) if a.size else 1.0


def line_cells(a, b):
    (x0, y0), (x1, y1) = a, b
    if y0 == y1:
        step = 1 if x1 >= x0 else -1
        return [(x, y0) for x in range(x0, x1 + step, step)]
    step = 1 if y1 >= y0 else -1
    return [(x0, y) for y in range(y0, y1 + step, step)]


def path_cells(pts):
    """Cells along a polyline; each corner counted once (so a duplicate cell
    really means the path crosses itself)."""
    cells = []
    for k, (a, b) in enumerate(zip(pts, pts[1:])):
        run = line_cells(a, b)
        cells.extend(run if k == 0 else run[1:])
    return cells


def bus_paths(rng, n, length, jogs_k=None):
    """Polylines for an n-line bus heading +x, with sideways jogs drawn as
    nested-L staircases so the lines never cross. jogs_k: list of (x, k)."""
    if jogs_k is None:
        njog = rng.choice([0, 1, 1, 2])
        xs = sorted(rng.sample(range(4, max(5, length - n - 4)), k=min(njog, max(0, length - n - 8))))
        # keep jogs at least a bus-width apart so the staircases don't overlap
        if len(xs) == 2 and xs[1] - xs[0] < n + 4:
            xs = xs[:1]
        jogs_k = [(x, rng.randint(2, 6) * rng.choice([-1, 1])) for x in xs]
    paths = [[(0, i)] for i in range(n)]
    offset = 0
    for jx, k in jogs_k:
        for i in range(n):
            order = (n - 1 - i) if k > 0 else i   # line nearest the jog turns first
            turn_x = jx + order
            y = i + offset
            paths[i] += [(turn_x, y), (turn_x, y + k)]
        offset += k
    for i in range(n):
        paths[i].append((length, i + offset))
    return paths


def transform(p, ox, oy, vertical):
    x, y = p
    return (ox + y, oy + x) if vertical else (ox + x, oy + y)


# --- block contents -----------------------------------------------------
def try_bus(board, rng, region):
    x0, y0, x1, y1 = region
    sizes = [n for n in BUS_SIZES if n <= BLOCK_BUS_MAX]
    n = rng.choices(sizes, BUS_WEIGHTS[:len(sizes)])[0]
    vertical = rng.random() < 0.5
    span = (y1 - y0) if vertical else (x1 - x0)
    if span < 12:
        return False
    length = rng.randint(min(10, span - 2), max(10, span - 2))
    ox, oy = rng.randrange(x0, x1), rng.randrange(y0, y1)
    paths = [[transform(p, ox, oy, vertical) for p in path]
             for path in bus_paths(rng, n, length)]
    cells = [c for path in paths for c in path_cells(path)]
    if len(set(cells)) != len(cells) or not board.free(cells, region):
        return False
    for path in paths:
        board.path(path)
    board.claim(cells)
    return True


def try_single(board, rng, region, cluster=None):
    x0, y0, x1, y1 = region
    x, y = rng.randrange(x0, x1), rng.randrange(y0, y1)
    pts = [(x, y)]
    horizontal = rng.random() < 0.5
    long_ = rng.random() < 0.4
    for _ in range(rng.randint(2, 4) if long_ else rng.randint(1, 3)):
        L = (rng.randint(6, 20) if long_ else rng.randint(3, 9)) * rng.choice([-1, 1])
        x, y = (x + L, y) if horizontal else (x, y + L)
        pts.append((x, y))
        horizontal = not horizontal
    cells = path_cells(pts)
    if len(set(cells)) != len(cells) or not board.free(cells, region):
        return False
    board.path(pts)
    board.claim(cells)
    for end, prev in ((pts[0], pts[1]), (pts[-1], pts[-2])):
        if rng.random() < (CLUSTER_PAD_P if cluster is not None else 0.7):
            board.pad(end, rng.choice([2.0, 2.4, 2.8]))
            if cluster is not None:
                d = (int(np.sign(end[0] - prev[0])), int(np.sign(end[1] - prev[1])))
                board.ports.append((end, cluster, d))
    for a, b in zip(pts, pts[1:]):
        run = line_cells(a, b)
        if len(run) >= 6 and rng.random() < 0.55:
            mid = run[len(run) // 2]
            horiz = a[1] == b[1]
            (board.bracket_pair if rng.random() < 0.6 else board.oval)(mid, horiz)
    if len(pts) > 2 and rng.random() < 0.4:
        c = pts[1]
        dx, dy = rng.choice([(1, 0), (-1, 0), (0, 1), (0, -1)])
        stub = [(c[0] + dx * k, c[1] + dy * k) for k in range(1, rng.randint(3, 5))]
        if board.free(stub, region):
            board.seg(c, stub[-1])
            board.pad(stub[-1], 2.0)
            board.claim(stub)
    return True


def place_chip(board, rng, region, small=False):
    """IC-like footprint: a trace outline with pins along its long sides;
    pin ends become ports that connecting traces can join."""
    x0, y0, x1, y1 = region
    bw, bh = x1 - x0, y1 - y0
    if bw < 16 or bh < 14:
        return False
    wmin, wmax, hmin, hmax = (6, 12, 4, 8) if small else (10, 22, 7, 12)
    w = rng.randint(min(wmin, bw - 8), min(wmax, bw - 8))
    h = rng.randint(min(hmin, bh - 8), min(hmax, bh - 8))
    cx = rng.randint(x0 + 4, x1 - 4 - w)
    cy = rng.randint(y0 + 4, y1 - 4 - h)
    body = [(cx, cy), (cx + w, cy), (cx + w, cy + h), (cx, cy + h), (cx, cy)]
    cells = path_cells(body)
    if not board.free(cells, region):
        return False
    board.path(body)
    board.claim(cells)
    cluster = board.new_cluster()
    horizontal_pins = w >= h          # pins along the longer sides
    side_len = w if horizontal_pins else h
    for side in (-1, 1):
        for k in range(2, side_len - 1, 2):
            if horizontal_pins:
                base = (cx + k, cy if side < 0 else cy + h)
                step = (0, side)
            else:
                base = (cx if side < 0 else cx + w, cy + k)
                step = (side, 0)
            if rng.random() < 0.12:
                # run on toward the block edge
                end = base
                while True:
                    nxt = (end[0] + step[0], end[1] + step[1])
                    if not (x0 + 1 <= nxt[0] < x1 - 1 and y0 + 1 <= nxt[1] < y1 - 1):
                        break
                    end = nxt
                length = abs(end[0] - base[0]) + abs(end[1] - base[1])
            else:
                length = rng.randint(2, 3)
                end = (base[0] + step[0] * length, base[1] + step[1] * length)
            if length < 2:
                continue
            first = (base[0] + step[0] * 2, base[1] + step[1] * 2)
            stub = line_cells(first, end)
            if not board.free(stub, region):
                continue
            board.seg(base, end)
            board.pad(end, 1.9)
            board.claim(stub)
            board.ports.append((end, cluster, step))
    return True


def place_cluster(board, rng, region):
    """A tight group of short components (pads, brackets, ovals) whose pad
    ends become ports for connecting traces."""
    x0, y0, x1, y1 = region
    r = rng.randint(7, 13)
    cx = rng.randint(x0 + r // 2, max(x0 + r // 2, x1 - r // 2 - 1))
    cy = rng.randint(y0 + r // 2, max(y0 + r // 2, y1 - r // 2 - 1))
    sub = (max(x0, cx - r), max(y0, cy - r), min(x1, cx + r), min(y1, cy + r))
    cluster = board.new_cluster()
    placed = 0
    for _ in range(120):
        if try_single(board, rng, sub, cluster):
            placed += 1
        if placed >= rng.randint(5, 10):
            break
    return placed > 0


def anchor_block(board, rng, region, role):
    """Phase 1: the block's main structures (before connecting traces)."""
    if role == "chip":
        chips = rng.randint(*CHIPS_PER_BLOCK)
        for _ in range(80):
            if place_chip(board, rng, region, small=chips > 1):
                chips -= 1
                if chips == 0:
                    break
    elif role == "cluster":
        for _ in range(rng.randint(*CLUSTERS_PER_BLOCK)):
            place_cluster(board, rng, region)
    elif role == "bus":
        tries = 0
        while board.coverage(region) < 0.13 and tries < 800:
            tries += 1
            try_bus(board, rng, region)


def fill_block(board, rng, region, role):
    """Phase 3: light filler around what is already there."""
    target = {"bus": 0.17, "sparse": 0.09, "chip": 0.11, "cluster": 0.12,
              "empty": 0.02}[role]
    tries = 0
    while board.coverage(region) < target and tries < 800:
        tries += 1
        try_single(board, rng, region)


# --- connecting traces ------------------------------------------------------
def _try_route(board, rng, a, da, b, db):
    """Escape straight out of both pads, then join with an L or Z."""
    def escape(p, d, n):
        return (p[0] + d[0] * n, p[1] + d[1] * n)

    ea, eb = escape(a, da, rng.randint(2, 4)), escape(b, db, rng.randint(2, 4))
    routes = [[ea, (eb[0], ea[1]), eb], [ea, (ea[0], eb[1]), eb]]
    for _ in range(5):
        mx = rng.randint(min(ea[0], eb[0]), max(ea[0], eb[0]))
        my = rng.randint(min(ea[1], eb[1]), max(ea[1], eb[1]))
        routes += [[ea, (mx, ea[1]), (mx, eb[1]), eb], [ea, (ea[0], my), (eb[0], my), eb]]
    rng.shuffle(routes)
    for mid in routes:
        pts = [a] + mid + [b]
        pts = [p for k, p in enumerate(pts) if k == 0 or p != pts[k - 1]]
        if any(p[0] != q[0] and p[1] != q[1] for p, q in zip(pts, pts[1:])):
            continue
        cells = path_cells(pts)
        if len(set(cells)) != len(cells):
            continue
        # the ends sit on existing pads; everything else must be clear
        inner = [c for c in cells
                 if max(abs(c[0] - a[0]), abs(c[1] - a[1])) > 1
                 and max(abs(c[0] - b[0]), abs(c[1] - b[1])) > 1]
        if not inner or not board.free(inner):
            continue
        board.path(pts)
        board.claim(inner)
        return True
    return False


def _try_lane_tap(board, a, d, max_len=40):
    """Run straight out of a pad until it meets a lane, and join it there."""
    cells = []
    p = a
    for _ in range(max_len):
        p = (p[0] + d[0], p[1] + d[1])
        if board.lane[p[1] % GRID, p[0] % GRID]:
            inner = [c for c in cells if max(abs(c[0] - a[0]), abs(c[1] - a[1])) > 1]
            if len(cells) < 3 or not board.free(inner[:-1]):
                return False
            board.seg(a, p)
            board.claim(inner[:-1])
            return True
        cells.append(p)
    return False


def route_ports(board, rng, max_dist=ROUTE_MAX_DIST):
    """Join pad ends of different clusters with single traces. Pairs are tried
    shortest-first (so long routes don't block short ones); pads left over may
    tap into a lane they face."""
    ports = board.ports
    used = board.routed
    pairs = []
    for i, (a, ca, da) in enumerate(ports):
        near = []
        for b, cb, db in ports[i + 1:]:
            if cb == ca:
                continue
            dist = abs(b[0] - a[0]) + abs(b[1] - a[1])
            if 6 <= dist <= max_dist:
                near.append((dist, rng.random(), (a, da), (b, db)))
        near.sort()
        pairs.extend(near[:ROUTE_CANDIDATES])
    pairs.sort()
    made = 0
    for _, _, (a, da), (b, db) in pairs:
        if a in used or b in used:
            continue
        if _try_route(board, rng, a, da, b, db):
            used.update((a, b))
            made += 1
    for a, _, da in ports:
        if a not in used and rng.random() < LANE_TAP_P and _try_lane_tap(board, a, da):
            used.add(a)
            made += 1
    return made


# --- lanes ----------------------------------------------------------------
def lane_positions(rng, count, min_gap):
    while True:
        pos = sorted(rng.sample(range(GRID), count))
        gaps = [(pos[(i + 1) % count] - pos[i]) % GRID for i in range(count)]
        if min(gaps) >= min_gap:
            return pos


def floor_movie(out, seed):
    rng = random.Random(seed)
    board = TraceBoard(rng)
    # horizontal lanes: full width, wrapping; paired jogs (+k, -k) keep the
    # ends level so the macro tile still repeats seamlessly
    hpos = lane_positions(rng, 3, 46)
    hlanes = []
    for y in hpos:
        n = rng.choice(LANE_SIZES)
        jx = rng.randint(20, GRID // 2 - 20)
        k = rng.randint(2, 5) * rng.choice([-1, 1])
        jogs = [(jx, k), (jx + rng.randint(40, GRID // 2), -k)]
        paths = [[(px, py + y) for px, py in path] for path in bus_paths(rng, n, GRID - 1, jogs)]
        for path in paths:
            # close the loop across the wrap seam
            path.append((GRID, path[-1][1]))
            board.path(path)
            board.claim(path_cells(path))
            for x, y in path_cells(path):
                board.lane[y % GRID, x % GRID] = True
        lo = y + min(0, k) - 1
        hi = y + n + max(0, k) + 1
        hlanes.append((lo, hi))
    # vertical lanes: run within each band between horizontal lanes and end
    # in a row of pads short of the next lane (connector look)
    vpos = lane_positions(rng, 3, 50)
    bands = []
    for i, (lo, hi) in enumerate(hlanes):
        nlo, _ = hlanes[(i + 1) % len(hlanes)]
        start, stop = hi + 2, (nlo + GRID if nlo < hi else nlo) - 2
        bands.append((start, stop))
    vwidth = {}
    for x in vpos:
        n = rng.choice(FEEDER_SIZES)
        vwidth[x] = n
        for start, stop in bands:
            if stop - start < 10 or rng.random() < 0.5:
                continue
            for i in range(n):
                a, b = (x + i, start), (x + i, stop)
                cells = line_cells(a, b)
                board.seg(a, b)
                board.claim(cells)
                for cx_, cy_ in cells:
                    board.lane[cy_ % GRID, cx_ % GRID] = True
                board.pad(a, 1.8)
                board.pad(b, 1.8)
    # blocks between lanes, each with a role
    xs = sorted(vpos)
    roles = []
    for start, stop in bands:
        for j, x in enumerate(xs):
            xa = x + vwidth[x] + 2
            xb = xs[(j + 1) % len(xs)] - 2
            if xb <= xa:
                xb += GRID
            region = (xa, start, xb, stop)
            role = rng.choices(BLOCK_ROLES, BLOCK_WEIGHTS)[0]
            roles.append((region, role))
            anchor_block(board, rng, region, role)
    links = sum(route_ports(board, rng) for _ in range(ROUTE_PASSES))
    for region, role in roles:
        fill_block(board, rng, region, role)
    roles = [r for _, r in roles]
    print(f"floor: macro {TILE}px, blocks {roles}, {len(board.ports)} ports, "
          f"{links} connecting traces, coverage {board.coverage() * 100:.1f}%")
    finish_floor(board.img, out)
    board.img.save(out / "room_traces.png")  # raw mask, for measuring


# --- "pcb" floor: modeled on a seamless circuit-board texture ---------------
# Dense maze-like right-angle routing (~30% of the area), two trace weights,
# round vias (filled circles with a hole) at trace ends and inline, parallel
# bundles that turn together as nested corners and end staggered on vias, and
# small square-pad arrays with traces escaping from them. Measured on the
# reference: thin trace ~0.36 x pitch, thick ~0.64 x pitch, via ~1.2 x pitch.
PCB_PITCH = 12
PCB_GRID = 168                # 168 * 12 = 2016 px tile
PCB_TILE = PCB_GRID * PCB_PITCH
PCB_THIN = 5
PCB_THICK = 8
PCB_VIA_R = 7
PCB_HOLE_R = 2.5
PCB_THIN_V = 215              # thin and thick traces read as two "colors"
PCB_THICK_V = 255
PCB_COVERAGE = 0.074          # sparse: well below the reference's ~30%
DIRS = [(1, 0), (0, 1), (-1, 0), (0, -1)]


class PCBBoard:
    def __init__(self):
        g = PCB_GRID
        self.used = np.zeros((g, g), bool)
        self.keepout = np.zeros((g, g), bool)
        self.img = Image.new("L", (PCB_TILE, PCB_TILE), 0)
        self.d = ImageDraw.Draw(self.img)

    @staticmethod
    def center(c):
        return c[0] * PCB_PITCH + PCB_PITCH / 2, c[1] * PCB_PITCH + PCB_PITCH / 2

    def _wrap(self, fn):
        for dx in (-PCB_TILE, 0, PCB_TILE):
            for dy in (-PCB_TILE, 0, PCB_TILE):
                fn(dx, dy)

    def seg(self, a, b, w, v):
        (ax, ay), (bx, by) = self.center(a), self.center(b)
        x0, x1 = sorted((ax, bx))
        y0, y1 = sorted((ay, by))
        h = w / 2
        self._wrap(lambda dx, dy: self.d.rectangle(
            [x0 - h + dx, y0 - h + dy, x1 + h - 1 + dx, y1 + h - 1 + dy], fill=v))

    def path(self, pts, w, v):
        for a, b in zip(pts, pts[1:]):
            self.seg(a, b, w, v)

    def via(self, c, v=255):
        if not self.via_ok(c):
            return
        self.claim_via(c)
        cx, cy = self.center(c)
        r, hr = PCB_VIA_R, PCB_HOLE_R
        self._wrap(lambda dx, dy: self.d.ellipse([cx - r + dx, cy - r + dy, cx + r + dx, cy + r + dy], fill=v))
        self._wrap(lambda dx, dy: self.d.ellipse([cx - hr + dx, cy - hr + dy, cx + hr + dx, cy + hr + dy], fill=0))

    def square_pad(self, c, v=255):
        cx, cy = self.center(c)
        r = PCB_PITCH * 0.42
        self._wrap(lambda dx, dy: self.d.rectangle([cx - r + dx, cy - r + dy, cx + r + dx, cy + r + dy], fill=v))

    # Traces may run in neighbouring cells (a 12 px pitch leaves a 7 px gap
    # between 5 px lines, like the reference); only vias need room, since a
    # 14 px via is wider than a cell.
    def free(self, cells):
        g = PCB_GRID
        return all(not self.used[y % g, x % g] for x, y in cells)

    def via_ok(self, c):
        g = PCB_GRID
        return not self.keepout[c[1] % g, c[0] % g]

    def claim(self, cells):
        g = PCB_GRID
        for x, y in cells:
            self.used[y % g, x % g] = True

    def claim_via(self, c):
        g = PCB_GRID
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                self.keepout[(c[1] + dy) % g, (c[0] + dx) % g] = True
                # a via also crowds the cells next to it for new traces
                if dx == 0 or dy == 0:
                    self.used[(c[1] + dy) % g, (c[0] + dx) % g] = True

    def cell_fill(self):
        return float(self.used.mean())

    def coverage(self):
        return float((np.asarray(self.img) > 0).mean())


def _normal(d):
    return (-d[1], d[0])


def pcb_bundle(board, rng):
    """2-6 parallel traces that turn together (nested corners, offset rule
    corner = v + i * (n_in + n_out)) and end staggered, mostly on vias."""
    n = rng.choices([2, 3, 4, 5, 6], [0.30, 0.28, 0.18, 0.14, 0.10])[0]
    thick = n <= 3 and rng.random() < 0.35
    w, v = (PCB_THICK, PCB_THICK_V) if thick else (PCB_THIN, PCB_THIN_V)
    di = rng.randrange(4)
    p = (rng.randrange(PCB_GRID), rng.randrange(PCB_GRID))
    verts, dirs = [p], []
    for _ in range(rng.randint(2, 6)):
        d = DIRS[di]
        length = rng.randint(2 * n + 3, 2 * n + 30)
        p = (p[0] + d[0] * length, p[1] + d[1] * length)
        verts.append(p)
        dirs.append(d)
        di = (di + rng.choice([1, 3])) % 4      # turn left or right
    lines = []
    for i in range(n):
        pts = []
        for k, vtx in enumerate(verts):
            if k == 0:
                nn = _normal(dirs[0])
                q = (vtx[0] + i * nn[0], vtx[1] + i * nn[1])
                back = rng.randint(0, 4)
                q = (q[0] - dirs[0][0] * back, q[1] - dirs[0][1] * back)
            elif k == len(verts) - 1:
                nn = _normal(dirs[-1])
                q = (vtx[0] + i * nn[0], vtx[1] + i * nn[1])
                ext = rng.randint(0, 5)
                q = (q[0] + dirs[-1][0] * ext, q[1] + dirs[-1][1] * ext)
            else:
                a, b = _normal(dirs[k - 1]), _normal(dirs[k])
                q = (vtx[0] + i * (a[0] + b[0]), vtx[1] + i * (a[1] + b[1]))
            pts.append(q)
        lines.append(pts)
    cells = [c for pts in lines for c in path_cells(pts)]
    if len(set(cells)) != len(cells) or not board.free(cells):
        return False
    for pts in lines:
        board.path(pts, w, v)
        for end in (pts[0], pts[-1]):
            if rng.random() < 0.8:
                board.via(end, v)
    board.claim(cells)
    return True


def pcb_snake(board, rng, start=None, first_dir=None):
    """A maze-like trace grown one segment at a time: each step tries a few
    turn/length options and takes the first that fits, so traces wind into
    the gaps left by others. Vias at the ends and now and then inline."""
    thick = rng.random() < 0.25
    w, v = (PCB_THICK, PCB_THICK_V) if thick else (PCB_THIN, PCB_THIN_V)
    g = PCB_GRID
    if start is None:
        for _ in range(20):
            p = (rng.randrange(g), rng.randrange(g))
            if board.free([p]):
                break
        else:
            return False
    else:
        p = start
    di = DIRS.index(first_dir) if first_dir is not None else rng.randrange(4)
    pts = [p]
    taken = {p} if start is None else set()
    target_segs = rng.randint(3, 10)
    for seg_i in range(target_segs):
        options = [di] if seg_i == 0 else [(di + 1) % 4, (di + 3) % 4]
        rng.shuffle(options)
        grown = False
        for nd in options:
            d = DIRS[nd]
            for length in sorted(rng.sample(range(2, 24), 4), reverse=True):
                run = [(p[0] + d[0] * k, p[1] + d[1] * k) for k in range(1, length + 1)]
                if any(c in taken for c in run) or not board.free(run):
                    continue
                taken.update(run)
                p = run[-1]
                pts.append(p)
                di = nd
                grown = True
                break
            if grown:
                break
        if not grown:
            break
    if len(pts) < 3 or len(taken) < 8:
        return False
    board.path(pts, w, v)
    board.claim(list(taken))
    if start is None and rng.random() < 0.9:
        board.via(pts[0], v)
    if rng.random() < 0.9:
        board.via(pts[-1], v)
    for a in pts[1:-1]:
        if rng.random() < 0.12:
            board.via(a, v)                  # inline via at a corner
    return True


def pcb_pad_array(board, rng):
    """A short row (or pair of rows) of square pads, traces escaping outward."""
    k = rng.randint(3, 8)
    rows = rng.choice([1, 1, 2])
    gap = rng.randint(3, 6)
    horizontal = rng.random() < 0.5
    x0, y0 = rng.randrange(PCB_GRID), rng.randrange(PCB_GRID)
    pads = []
    for r in range(rows):
        for j in range(k):
            off = (j * 2, r * gap)
            pads.append(((x0 + off[0], y0 + off[1]) if horizontal else (x0 + off[1], y0 + off[0]), r))
    cells = [c for c, _ in pads]
    if not board.free(cells):
        return False
    for c, _ in pads:
        board.square_pad(c)
    board.claim(cells)
    for c, r in pads:
        if rng.random() < 0.5:
            out = (0, -1 if r == 0 else 1) if horizontal else (-1 if r == 0 else 1, 0)
            if rows == 1:
                out = rng.choice([(0, -1), (0, 1)]) if horizontal else rng.choice([(-1, 0), (1, 0)])
            pcb_snake(board, rng, start=c, first_dir=out)
    return True


def floor_pcb(out, seed):
    rng = random.Random(seed)
    board = PCBBoard()
    attempts = 0
    while attempts < 60000:
        attempts += 1
        r = rng.random()
        if r < 0.30:
            pcb_bundle(board, rng)
        elif r < 0.95:
            pcb_snake(board, rng)
        else:
            pcb_pad_array(board, rng)
        if attempts % 50 == 0 and board.coverage() >= PCB_COVERAGE:
            break
    print(f"floor (pcb): {PCB_TILE}px, coverage {board.coverage() * 100:.1f}%, "
          f"cells {board.cell_fill() * 100:.0f}% after {attempts} attempts")
    finish_floor(board.img, out, halo=0.25)
    board.img.save(out / "room_traces.png")


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
    ap.add_argument("--floor", choices=["pcb", "movie", "legacy"], default="pcb",
                    help="pcb: dense circuit-board routing with vias (default); "
                         "movie: board laid out from the film's stills; legacy: media/room_src.png")
    ap.add_argument("--floor-src", default=None,
                    help="legacy floor art (default: media/room_src.png)")
    ap.add_argument("--floor-only", action="store_true")
    args = ap.parse_args()
    out = Path(args.out)
    if not args.floor_only:
        tower_set("towers1", out, args.seed, dark=True)
        tower_set("towers2", out, args.seed + 1, dark=False)
    if args.floor == "pcb":
        floor_pcb(out, args.seed)
    elif args.floor == "movie":
        floor_movie(out, args.seed)
    else:
        src = Path(args.floor_src) if args.floor_src else out / "room_src.png"
        floor(out, src)


if __name__ == "__main__":
    main()
