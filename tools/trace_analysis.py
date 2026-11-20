#!/usr/bin/env python3
"""Infer the film's floor-trace pattern from movie stills.

Stages (each writes into compare/traces/):
  select   score every still by visible trace pixels, keep the best floor views
  rectify  find the two trace-direction vanishing points per still and warp
           the floor to a top-down view
  measure  trace widths, spacing, bundle sizes, segment lengths, motifs

Usage: tools/.venv/bin/python tools/trace_analysis.py [select|rectify|measure|all]
"""
import glob
import json
import sys
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
CMP = ROOT / "compare"
OUT = CMP / "traces"
CLIPS = ["movie1", "movie2", "movie3"]


# Trace hue range per clip (OpenCV hue 0-180): traces are blue in Untitled,
# violet-blue in Untitled-2, magenta in Untitled-3 (whose tower glass is blue).
HUES = {"movie1": (112, 128), "movie2": (108, 135), "movie3": (128, 170)}


def trace_mask(bgr, clip):
    """Thin, saturated trace-colored structures (not tower glass or glare)."""
    lo, hi = HUES[clip]
    hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)
    h, s, v = hsv[..., 0], hsv[..., 1], hsv[..., 2]
    m = ((h >= lo) & (h <= hi) & (s >= 100) & (v >= 80)).astype(np.uint8) * 255
    m = cv2.morphologyEx(m, cv2.MORPH_OPEN, np.ones((2, 2), np.uint8))
    # drop thick blobs (glass slabs, glow): keep what a 31px opening removes
    thick = cv2.morphologyEx(m, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_RECT, (31, 31)))
    return cv2.subtract(m, thick)


def stage_select(keep=18):
    OUT.mkdir(parents=True, exist_ok=True)
    rows = []
    for clip in CLIPS:
        for f in sorted(glob.glob(str(CMP / clip / "f_*.png"))):
            img = cv2.imread(f)
            m = trace_mask(img, clip)
            h = m.shape[0]
            lower = m[h // 3:]
            frac = float((lower > 0).mean())
            # line-ness: long thin structures (traces) vs blobs (glare)
            edges = cv2.Canny(lower, 50, 150)
            lines = cv2.HoughLinesP(edges, 1, np.pi / 180, 40, minLineLength=40, maxLineGap=6)
            nlines = 0 if lines is None else len(lines)
            rows.append({"file": f, "clip": clip, "frac": frac, "lines": nlines})
    # good floor views: plenty of trace pixels AND many straight segments
    for r in rows:
        r["score"] = r["frac"] * 100 + r["lines"] * 0.15
    rows.sort(key=lambda r: -r["score"])
    best = [r for r in rows if r["frac"] > 0.02 and r["lines"] > 25][:keep]
    for i, r in enumerate(best):
        img = cv2.imread(r["file"])
        m = trace_mask(img, r["clip"])
        cv2.imwrite(str(OUT / f"sel_{i:02d}_mask.png"), m)
        cv2.imwrite(str(OUT / f"sel_{i:02d}_src.png"), img)
        r["id"] = i
    (OUT / "selected.json").write_text(json.dumps(best, indent=1))
    print(f"scored {len(rows)} stills, kept {len(best)}")
    for r in best:
        print(f"  {r['id']:02d} {Path(r['file']).parent.name}/{Path(r['file']).name} "
              f"trace {r['frac'] * 100:.1f}%  lines {r['lines']}")


def seg_lines(mask):
    """Straight trace segments as (x1, y1, x2, y2) from the mask."""
    lsd = cv2.createLineSegmentDetector(cv2.LSD_REFINE_STD)
    segs = lsd.detect(mask)[0]
    if segs is None:
        return np.zeros((0, 4))
    segs = segs.reshape(-1, 4).astype(float)
    length = np.hypot(segs[:, 2] - segs[:, 0], segs[:, 3] - segs[:, 1])
    return segs[length > 18]


def homog_line(seg):
    return np.cross([seg[0], seg[1], 1.0], [seg[2], seg[3], 1.0])


def vp_inliers(segs, vp, tol_deg=2.0):
    """Segments whose direction points at the (homogeneous) vanishing point."""
    mid = np.stack([(segs[:, 0] + segs[:, 2]) / 2, (segs[:, 1] + segs[:, 3]) / 2], 1)
    d_seg = np.stack([segs[:, 2] - segs[:, 0], segs[:, 3] - segs[:, 1]], 1)
    if abs(vp[2]) < 1e-9:
        d_vp = np.tile(vp[:2], (len(segs), 1))
    else:
        d_vp = vp[:2] / vp[2] - mid
    cos = np.abs((d_seg * d_vp).sum(1)) / (
        np.linalg.norm(d_seg, axis=1) * np.linalg.norm(d_vp, axis=1) + 1e-9)
    return cos > np.cos(np.radians(tol_deg))


def find_vp(segs, rng, iters=1500):
    lines = np.array([homog_line(s) for s in segs])
    weights = np.hypot(segs[:, 2] - segs[:, 0], segs[:, 3] - segs[:, 1])
    best_in = None
    for _ in range(iters):
        i, j = rng.choice(len(segs), 2, replace=False)
        vp = np.cross(lines[i], lines[j])
        n = np.linalg.norm(vp)
        if n < 1e-9:
            continue
        inl = vp_inliers(segs, vp / n)
        if best_in is None or weights[inl].sum() > weights[best_in].sum():
            best_in = inl
    # refine: point closest to all inlier lines (weighted least squares)
    L = lines[best_in]
    L = L / np.linalg.norm(L[:, :2], axis=1, keepdims=True)
    _, _, vt = np.linalg.svd(L * weights[best_in][:, None])
    vp = vt[-1]
    return vp / np.linalg.norm(vp), best_in


def rectify_one(src_mask, rng):
    segs = seg_lines(src_mask)
    if len(segs) < 20:
        return None, "too few segments"
    vp1, in1 = find_vp(segs, rng)
    rest = segs[~in1]
    if len(rest) < 10:
        return None, "one direction only"
    vp2, in2 = find_vp(rest, rng)
    # affine rectification: send the vanishing line to infinity
    vline = np.cross(vp1, vp2)
    if abs(vline[2]) < 1e-12:
        return None, "vanishing line through origin"
    vline = vline / vline[2]
    Ha = np.array([[1, 0, 0], [0, 1, 0], vline])
    d1, d2 = Ha @ vp1, Ha @ vp2
    M = np.array([[d1[0], d2[0]], [d1[1], d2[1]]])
    if abs(np.linalg.det(M)) < 1e-12:
        return None, "parallel directions"
    Hb = np.eye(3)
    Hb[:2, :2] = np.linalg.inv(M)
    H = Hb @ Ha
    # floor side of the vanishing line; drop the far 35% (it smears)
    ys, xs = np.nonzero(src_mask)
    pts = np.stack([xs, ys, np.ones_like(xs)], 1).astype(float)
    side = pts @ vline
    side *= np.sign(np.median(side))
    near = side > np.percentile(side, 35)
    tp = (H @ pts[near].T).T
    tp = tp[:, :2] / tp[:, 2:3]
    lo, hi = np.percentile(tp, 2, axis=0), np.percentile(tp, 98, axis=0)
    span = hi - lo
    if np.any(span <= 0):
        return None, "degenerate"
    scale = 1000.0 / span.max()
    T = np.array([[scale, 0, -lo[0] * scale], [0, scale, -lo[1] * scale], [0, 0, 1]])
    w, h = int(span[0] * scale) + 1, int(span[1] * scale) + 1
    keep = np.zeros_like(src_mask)
    keep[ys[near], xs[near]] = 255
    top = cv2.warpPerspective(keep, T @ H, (min(w, 1400), min(h, 1400)), flags=cv2.INTER_NEAREST)
    return top, f"{len(segs)} segs, {int(in1.sum())}/{int(in2.sum())} per direction"


def axis_runs(top, axis):
    """Run lengths of trace pixels along rows (axis=1) or columns (axis=0)."""
    m = (top > 0).astype(np.int8)
    if axis == 0:
        m = m.T
    runs = []
    for row in m:
        d = np.diff(np.concatenate([[0], row, [0]]))
        runs.extend((np.nonzero(d == -1)[0] - np.nonzero(d == 1)[0]).tolist())
    return np.array(runs)


def typical_width(top, axis):
    r = axis_runs(top, axis)
    r = r[(r >= 2) & (r < 40)]
    return float(np.median(r)) if len(r) else 0.0


def stage_rectify():
    sel = json.loads((OUT / "selected.json").read_text())
    rng = np.random.default_rng(7)
    report = []
    for r in sel:
        mask = cv2.imread(str(OUT / f"sel_{r['id']:02d}_mask.png"), 0)
        top, info = rectify_one(mask, rng)
        if top is None:
            print(f"  {r['id']:02d} skip: {info}")
            continue
        # aspect fix: traces have one width in both directions, so stretch y
        # until horizontal traces are as thick as vertical ones
        wx, wy = typical_width(top, 1), typical_width(top, 0)
        sy = float(np.clip(wx / wy, 0.25, 4.0)) if wx > 0 and wy > 0 else 1.0
        top = cv2.resize(top, (top.shape[1], max(1, int(top.shape[0] * sy))),
                         interpolation=cv2.INTER_NEAREST)
        cv2.imwrite(str(OUT / f"top_{r['id']:02d}.png"), top)
        report.append({"id": r["id"], "src": r["file"], "info": info, "aspect_fix": sy})
        print(f"  {r['id']:02d} {info}  aspect x{sy:.2f}")
    (OUT / "rectified.json").write_text(json.dumps(report, indent=1))


def profile_stats(top, axis):
    """Along rows/cols: trace widths, gaps between neighbouring traces, and
    bundle sizes (runs of traces separated by gaps < 2.5 widths)."""
    m = (top > 0).astype(np.int8)
    if axis == 0:
        m = m.T
    widths, gaps, bundles = [], [], []
    for row in m:
        d = np.diff(np.concatenate([[0], row, [0]]))
        s, e = np.nonzero(d == 1)[0], np.nonzero(d == -1)[0]
        w = e - s
        ok = (w >= 2) & (w < 40)
        s, e, w = s[ok], e[ok], w[ok]
        if len(w) < 2:
            continue
        widths.extend(w.tolist())
        g = s[1:] - e[:-1]
        gaps.extend(g.tolist())
        wmed = np.median(w)
        n = 1
        for gg in g:
            if gg < 2.5 * wmed:
                n += 1
            else:
                bundles.append(n)
                n = 1
        bundles.append(n)
    return np.array(widths), np.array(gaps), np.array(bundles)


def stage_measure():
    rect = json.loads((OUT / "rectified.json").read_text())
    rows = []
    for r in rect:
        top = cv2.imread(str(OUT / f"top_{r['id']:02d}.png"), 0)
        if top is None or top.size == 0:
            continue
        # only the region that has content (bounding box of traces)
        ys, xs = np.nonzero(top)
        if len(xs) < 500:
            continue
        crop = top[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
        stats = {}
        allw, allg, allb = [], [], []
        for axis in (0, 1):
            w, g, b = profile_stats(crop, axis)
            allw.append(w), allg.append(g), allb.append(b)
        w = np.concatenate(allw)
        g = np.concatenate(allg)
        b = np.concatenate(allb)
        if len(w) < 50:
            continue
        wmed = float(np.median(w))
        small_gaps = g[g < 2.5 * wmed]
        # straight segment lengths via skeleton runs, in line widths
        skel = cv2.ximgproc.thinning(crop) if hasattr(cv2, "ximgproc") else None
        stats.update({
            "id": r["id"],
            "width_px": wmed,
            "gap_over_width": float(np.median(small_gaps) / wmed) if len(small_gaps) else None,
            "bundle_p": {k: float((b == k).mean()) for k in range(1, 9)},
            "bundle_ge9": float((b >= 9).mean()),
            "coverage": float((crop > 0).mean()),
            "bundle_mean_multi": float(b[b > 1].mean()) if (b > 1).any() else 1.0,
        })
        rows.append(stats)
        print(f"  {r['id']:02d} width {wmed:4.1f}px  gap/width "
              f"{stats['gap_over_width'] or 0:.2f}  coverage {stats['coverage'] * 100:4.1f}%  "
              f"multi-line bundles avg {stats['bundle_mean_multi']:.1f}")
    gw = [s["gap_over_width"] for s in rows if s["gap_over_width"]]
    cov = [s["coverage"] for s in rows]
    summary = {
        "frames": len(rows),
        "gap_over_width_median": float(np.median(gw)),
        "coverage_median": float(np.median(cov)),
        "bundle_mean_multi_median": float(np.median([s["bundle_mean_multi"] for s in rows])),
    }
    (OUT / "measure.json").write_text(json.dumps({"summary": summary, "frames": rows}, indent=1))
    print("summary:", json.dumps(summary))


if __name__ == "__main__":
    stage = sys.argv[1] if len(sys.argv) > 1 else "select"
    if stage in ("measure", "all"):
        pass
    if stage in ("select", "all"):
        stage_select()
    if stage in ("rectify", "all"):
        stage_rectify()
    if stage in ("measure", "all"):
        stage_measure()
