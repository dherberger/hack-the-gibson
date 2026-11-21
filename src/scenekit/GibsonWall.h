#ifndef GIBSON_WALL_H_
#define GIBSON_WALL_H_

/* Multi-monitor "video wall": every display renders its own slice of one
 * shared frustum, so the displays together act as windows onto a single view.
 *
 * The wall is laid out in millimetres rather than points, because displays
 * with different pixel densities would otherwise show the same object at
 * different physical sizes on either side of a seam. */

#include <algorithm>
#include <cmath>

#import <simd/simd.h>

struct GibsonWallScreen
{
    double x, y, w, h;   /* frame in points, global Cocoa coordinates (y up) */
    double mmW, mmH;     /* physical size; <= 0 when the display doesn't say */
    bool placed;         /* the user positioned it in Arrange Displays */
    double cx, cy;       /* its centre on the wall in mm, when placed */
    double tiltDeg;      /* leaning back from vertical, top edge away */
    double swivelDeg;    /* turned about its vertical centre line, right edge nearer */
};

/* Frustum extents at unit distance from the eye (tangents of the half-angles). */
struct GibsonWallSlice
{
    double l, r, b, t;
};

#define GIBSON_WALL_DEFAULT_MM_PER_PT 0.25
#define GIBSON_WALL_VFOV_DEG 72.0       /* matches the single-display camera */
#define GIBSON_WALL_MAX_HFOV_DEG 110.0  /* wider than this smears the edges */

struct GibsonWallRect
{
    double x0, y0, x1, y1;   /* mm */
};

static inline double gibson_wall_mm_per_pt(const GibsonWallScreen &s)
{
    if (s.mmW > 0 && s.mmH > 0 && s.w > 0)
        return s.mmW / s.w;
    return GIBSON_WALL_DEFAULT_MM_PER_PT;
}

/* By default screen centres keep their arrangement from System Settings,
 * scaled by the coarsest display's mm-per-point; each screen then takes its
 * true physical size around that centre. Denser displays end up with a few mm
 * of gap to their neighbours, and nothing overlaps. That is only a guess at
 * where the panels really sit, so a display placed by hand uses that instead. */
static inline GibsonWallRect gibson_wall_rect(const GibsonWallScreen *screens, int count, int i)
{
    double scale = 0;
    for (int k = 0; k < count; ++k)
        scale = std::max(scale, gibson_wall_mm_per_pt(screens[k]));
    const GibsonWallScreen &s = screens[i];
    const double own = gibson_wall_mm_per_pt(s);
    const double cx = s.placed ? s.cx : (s.x + s.w * 0.5) * scale;
    const double cy = s.placed ? s.cy : (s.y + s.h * 0.5) * scale;
    const bool known = s.mmW > 0 && s.mmH > 0;
    const double hw = (known ? s.mmW : s.w * own) * 0.5;
    const double hh = (known ? s.mmH : s.h * own) * 0.5;
    return GibsonWallRect{cx - hw, cy - hh, cx + hw, cy + hh};
}

static inline GibsonWallRect gibson_wall_bounds(const GibsonWallScreen *screens, int count)
{
    GibsonWallRect u = gibson_wall_rect(screens, count, 0);
    for (int k = 1; k < count; ++k)
    {
        const GibsonWallRect r = gibson_wall_rect(screens, count, k);
        u.x0 = std::min(u.x0, r.x0);
        u.y0 = std::min(u.y0, r.y0);
        u.x1 = std::max(u.x1, r.x1);
        u.y1 = std::max(u.y1, r.y1);
    }
    return u;
}

/* The eye sits in front of the centre of the wall's bounding box, far enough
 * back that the box spans the usual vertical field of view, or further if that
 * would make it wider than the horizontal limit. Wall space is x right, y up,
 * z towards the viewer, with untilted panels lying in z = 0. */
static inline simd_double3 gibson_wall_eye(const GibsonWallRect &u)
{
    const double rad = M_PI / 180.0;
    const double halfW = (u.x1 - u.x0) * 0.5;
    const double halfH = (u.y1 - u.y0) * 0.5;
    const double dist = std::max(halfH / std::tan(GIBSON_WALL_VFOV_DEG * 0.5 * rad),
                                 halfW / std::tan(GIBSON_WALL_MAX_HFOV_DEG * 0.5 * rad));
    return simd_make_double3((u.x0 + u.x1) * 0.5, (u.y0 + u.y1) * 0.5, dist);
}

/* A panel in wall space. Tilt leans it back about its horizontal centre line
 * (top edge away from the viewer), like a laptop lid opened past vertical.
 * Swivel then turns it about the vertical line through its centre, positive
 * bringing its right edge nearer, as when a monitor off to your right is
 * turned to face you. Tilt is in the panel's own frame, as on a monitor stand. */
struct GibsonWallPlane
{
    simd_double3 centre, right, up, normal;   /* normal faces the viewer */
    double w, h;
};

static inline GibsonWallPlane gibson_wall_plane(const GibsonWallRect &r, double tiltDeg,
                                                double swivelDeg)
{
    const double t = tiltDeg * M_PI / 180.0;
    const double s = swivelDeg * M_PI / 180.0;
    const double ct = std::cos(t), st = std::sin(t), cs = std::cos(s), ss = std::sin(s);
    GibsonWallPlane p;
    p.centre = simd_make_double3((r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5, 0.0);
    p.right = simd_make_double3(cs, 0, ss);
    p.up = simd_make_double3(st * ss, ct, -st * cs);
    p.normal = simd_make_double3(-ct * ss, st, ct * cs);
    p.w = r.x1 - r.x0;
    p.h = r.y1 - r.y0;
    return p;
}

/* What one display renders: an off-axis frustum through the panel's corners,
 * seen by a camera turned to face the panel squarely (generalised perspective
 * projection). `basis` holds the camera's right, up and back axes relative to
 * the shared fly camera. */
struct GibsonWallView
{
    GibsonWallSlice slice;
    simd_float3x3 basis;
};

static inline GibsonWallView gibson_wall_view_for(const simd_double3 &eye,
                                                  const GibsonWallPlane &p)
{
    const simd_double3 pa = p.centre - p.right * (p.w * 0.5) - p.up * (p.h * 0.5);
    const simd_double3 pb = pa + p.right * p.w;
    const simd_double3 pc = pa + p.up * p.h;
    const double dist = std::max(1e-6, -simd_dot(p.normal, pa - eye));
    GibsonWallView v;
    v.slice = GibsonWallSlice{simd_dot(p.right, pa - eye) / dist, simd_dot(p.right, pb - eye) / dist,
                              simd_dot(p.up, pa - eye) / dist, simd_dot(p.up, pc - eye) / dist};
    v.basis = simd_matrix(
        simd_make_float3((float)p.right.x, (float)p.right.y, (float)p.right.z),
        simd_make_float3((float)p.up.x, (float)p.up.y, (float)p.up.z),
        simd_make_float3((float)p.normal.x, (float)p.normal.y, (float)p.normal.z));
    return v;
}

/* Where a point of the z = 0 wall plane appears on a panel, in mm from the
 * panel's lower-left corner. False when the panel can't show it. */
static inline bool gibson_wall_to_panel(const simd_double3 &eye, const GibsonWallPlane &p,
                                        double x, double y, double *px, double *py)
{
    const simd_double3 ray = simd_make_double3(x, y, 0.0) - eye;
    const double den = simd_dot(p.normal, ray);
    if (den > -1e-9)
        return false;
    const simd_double3 hit = eye + ray * (simd_dot(p.normal, p.centre - eye) / den);
    *px = simd_dot(hit - p.centre, p.right) + p.w * 0.5;
    *py = simd_dot(hit - p.centre, p.up) + p.h * 0.5;
    return true;
}

/* The inverse for a point on the panel (mm from its lower-left corner). */
static inline void gibson_panel_to_wall(const simd_double3 &eye, const GibsonWallPlane &p,
                                        double px, double py, double *x, double *y)
{
    const simd_double3 q = p.centre + p.right * (px - p.w * 0.5) + p.up * (py - p.h * 0.5);
    const double s = eye.z / std::max(1e-6, eye.z - q.z);
    *x = eye.x + (q.x - eye.x) * s;
    *y = eye.y + (q.y - eye.y) * s;
}

static inline bool gibson_wall_view(const GibsonWallScreen *screens, int count, int index,
                                    GibsonWallView *out)
{
    if (count < 1 || index < 0 || index >= count)
        return false;
    const GibsonWallRect u = gibson_wall_bounds(screens, count);
    if (u.x1 - u.x0 <= 0 || u.y1 - u.y0 <= 0)
        return false;
    *out = gibson_wall_view_for(
        gibson_wall_eye(u),
        gibson_wall_plane(gibson_wall_rect(screens, count, index), screens[index].tiltDeg,
                          screens[index].swivelDeg));
    return true;
}

/* Off-axis perspective matrix (OpenGL clip conventions, as SCNCamera expects). */
static inline simd_float4x4 gibson_wall_projection(const GibsonWallSlice &s, double zNear,
                                                   double zFar)
{
    const double l = s.l * zNear, r = s.r * zNear, b = s.b * zNear, t = s.t * zNear;
    return simd_matrix(
        simd_make_float4((float)(2.0 * zNear / (r - l)), 0, 0, 0),
        simd_make_float4(0, (float)(2.0 * zNear / (t - b)), 0, 0),
        simd_make_float4((float)((r + l) / (r - l)), (float)((t + b) / (t - b)),
                         (float)(-(zFar + zNear) / (zFar - zNear)), -1),
        simd_make_float4(0, 0, (float)(-2.0 * zFar * zNear / (zFar - zNear)), 0));
}

#endif
