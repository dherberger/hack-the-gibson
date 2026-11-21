#import "GibsonArrange.h"

#import "GibsonLidAngle.h"
#import "GibsonSCNCamera.h"
#import "GibsonSCNScene.h"
#import "GibsonWallScreens.h"

#import <SceneKit/SceneKit.h>

#include "gibson_settings.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>

@interface GibsonArrangeItem : NSObject
@property(nonatomic, strong) NSScreen *screen;
@property(nonatomic, copy) NSString *key;
@property(nonatomic) double cx, cy, w, h;   // mm on the wall, y up
@property(nonatomic) double tilt;           // degrees leaning back, top edge away
@property(nonatomic) double swivel;         // degrees turned, right edge nearer
/* Frame around the picture, in mm. Only the editor uses it: it lets frames be
   butted together, and the picture positions then come out right by themselves. */
@property(nonatomic) double bezelSide, bezelTop, bezelBottom;
@end

@implementation GibsonArrangeItem
- (GibsonWallRect)rect
{
    return GibsonWallRect{_cx - _w * 0.5, _cy - _h * 0.5, _cx + _w * 0.5, _cy + _h * 0.5};
}
@end

/* Where the city starts: a few seconds into the flythrough, towers either side
 * and floor traces running across the view give plenty of edges to line up. */
static const double kArrangeStillTime = 6.0;

static void gibson_arrange_reload_settings(void)
{
    gibson_settings_reload([NSBundle mainBundle].resourcePath.fileSystemRepresentation);
}

/* display_<UUID> holds the position; bezel_<UUID> is kept apart so that
   "Reset to System Arrangement" doesn't throw the measurements away. */
static NSString *gibson_arrange_bezel_key(NSString *displayKey)
{
    static NSString *const prefix = @"display_";
    if (![displayKey hasPrefix:prefix])
        return nil;
    return [@"bezel_" stringByAppendingString:[displayKey substringFromIndex:prefix.length]];
}

static NSArray<GibsonArrangeItem *> *gibson_arrange_load(void)
{
    gibson_arrange_reload_settings();
    const std::vector<GibsonWallScreen> screens = gibson_wall_screens();
    NSArray<NSScreen *> *ns = [NSScreen screens];
    NSMutableArray<GibsonArrangeItem *> *items = [NSMutableArray array];
    for (NSUInteger i = 0; i < ns.count && i < screens.size(); ++i)
    {
        const GibsonWallRect r = gibson_wall_rect(screens.data(), (int)screens.size(), (int)i);
        GibsonArrangeItem *item = [[GibsonArrangeItem alloc] init];
        item.screen = ns[i];
        item.key = gibson_display_key(ns[i]);
        item.cx = (r.x0 + r.x1) * 0.5;
        item.cy = (r.y0 + r.y1) * 0.5;
        item.w = r.x1 - r.x0;
        item.h = r.y1 - r.y0;
        item.tilt = screens[i].tiltDeg;
        item.swivel = screens[i].swivelDeg;
        NSString *bezelKey = gibson_arrange_bezel_key(item.key);
        double side = 0, top = 0, bottom = 0;
        if (bezelKey && std::sscanf(gibson_settings_raw(bezelKey.UTF8String), "%lf %lf %lf",
                                    &side, &top, &bottom) == 3)
        {
            item.bezelSide = std::max(0.0, std::min(100.0, side));
            item.bezelTop = std::max(0.0, std::min(100.0, top));
            item.bezelBottom = std::max(0.0, std::min(100.0, bottom));
        }
        [items addObject:item];
    }
    return items;
}

static GibsonWallRect gibson_arrange_bounds(NSArray<GibsonArrangeItem *> *items)
{
    GibsonWallRect u{0, 0, 1, 1};
    BOOL first = YES;
    for (GibsonArrangeItem *item in items)
    {
        const GibsonWallRect r = [item rect];
        if (first)
            u = r;
        else
        {
            u.x0 = std::min(u.x0, r.x0);
            u.y0 = std::min(u.y0, r.y0);
            u.x1 = std::max(u.x1, r.x1);
            u.y1 = std::max(u.y1, r.y1);
        }
        first = NO;
    }
    return u;
}

static simd_double3 gibson_arrange_eye(NSArray<GibsonArrangeItem *> *items)
{
    return gibson_wall_eye(gibson_arrange_bounds(items));
}

/* Corners of part of a panel (mm from the picture's lower-left corner) as the
 * viewer sees them on the wall plane, counter-clockwise from lower left. An
 * upright panel is its plain rectangle; a tilted one is the trapezoid you see
 * from your seat, which is also where its edges must meet its neighbours'. */
static void gibson_arrange_quad(GibsonArrangeItem *item, const simd_double3 &eye, double x0,
                                double y0, double x1, double y1, simd_double2 out[4])
{
    const GibsonWallPlane p = gibson_wall_plane([item rect], item.tilt, item.swivel);
    const double px[4] = {x0, x1, x1, x0}, py[4] = {y0, y0, y1, y1};
    for (int i = 0; i < 4; ++i)
    {
        double x, y;
        gibson_panel_to_wall(eye, p, px[i], py[i], &x, &y);
        out[i] = simd_make_double2(x, y);
    }
}

static void gibson_arrange_active_quad(GibsonArrangeItem *item, const simd_double3 &eye,
                                       simd_double2 out[4])
{
    gibson_arrange_quad(item, eye, 0, 0, item.w, item.h, out);
}

static void gibson_arrange_outer_quad(GibsonArrangeItem *item, const simd_double3 &eye,
                                      simd_double2 out[4])
{
    gibson_arrange_quad(item, eye, -item.bezelSide, -item.bezelBottom, item.w + item.bezelSide,
                        item.h + item.bezelTop, out);
}

static GibsonWallRect gibson_arrange_box(const simd_double2 q[4])
{
    GibsonWallRect r{q[0].x, q[0].y, q[0].x, q[0].y};
    for (int i = 1; i < 4; ++i)
    {
        r.x0 = std::min(r.x0, q[i].x);
        r.y0 = std::min(r.y0, q[i].y);
        r.x1 = std::max(r.x1, q[i].x);
        r.y1 = std::max(r.y1, q[i].y);
    }
    return r;
}

static GibsonWallRect gibson_arrange_outer_box(GibsonArrangeItem *item, const simd_double3 &eye)
{
    simd_double2 q[4];
    gibson_arrange_outer_quad(item, eye, q);
    return gibson_arrange_box(q);
}

static bool gibson_arrange_overlap(const GibsonWallRect &a, const GibsonWallRect &b, double by)
{
    return std::min(a.x1, b.x1) - std::max(a.x0, b.x0) > by &&
           std::min(a.y1, b.y1) - std::max(a.y0, b.y0) > by;
}

/* Which sides of a display's frame rest against a neighbour's frame. */
struct GibsonArrangeContacts
{
    bool left, right, below, above;
};

static GibsonArrangeContacts gibson_arrange_contacts(NSArray<GibsonArrangeItem *> *items,
                                                     GibsonArrangeItem *sel)
{
    const double tol = 1.0;
    const simd_double3 eye = gibson_arrange_eye(items);
    const GibsonWallRect s = gibson_arrange_outer_box(sel, eye);
    GibsonArrangeContacts c{false, false, false, false};
    for (GibsonArrangeItem *item in items)
    {
        if (item == sel)
            continue;
        const GibsonWallRect o = gibson_arrange_outer_box(item, eye);
        const bool sideBySide = std::min(s.y1, o.y1) - std::max(s.y0, o.y0) > tol;
        const bool stacked = std::min(s.x1, o.x1) - std::max(s.x0, o.x0) > tol;
        if (sideBySide && std::fabs(s.x0 - o.x1) < tol) c.left = true;
        if (sideBySide && std::fabs(s.x1 - o.x0) < tol) c.right = true;
        if (stacked && std::fabs(s.y0 - o.y1) < tol) c.below = true;
        if (stacked && std::fabs(s.y1 - o.y0) < tol) c.above = true;
    }
    return c;
}

/* Changes a display's tilt or bezels without opening a gap or an overlap: a
 * side of its frame that rested on a neighbour stays there, the way a laptop
 * lid under a monitor keeps meeting it as you tilt it. */
static void gibson_arrange_keep_contacts(NSArray<GibsonArrangeItem *> *items,
                                         GibsonArrangeItem *sel, void (^change)(void))
{
    const GibsonArrangeContacts c = gibson_arrange_contacts(items, sel);
    const GibsonWallRect before = gibson_arrange_outer_box(sel, gibson_arrange_eye(items));
    change();
    /* The eye follows the layout, so settle over a few passes. */
    for (int pass = 0; pass < 4; ++pass)
    {
        const GibsonWallRect now = gibson_arrange_outer_box(sel, gibson_arrange_eye(items));
        if (c.left != c.right)
            sel.cx += c.left ? before.x0 - now.x0 : before.x1 - now.x1;
        if (c.below != c.above)
            sel.cy += c.below ? before.y0 - now.y0 : before.y1 - now.y1;
    }
}

/* Pulls the dragged display's frame edges onto nearby frame edges of the
 * others, within `tol` mm. */
static void gibson_arrange_snap(NSArray<GibsonArrangeItem *> *items, GibsonArrangeItem *sel,
                                double tol)
{
    const simd_double3 eye = gibson_arrange_eye(items);
    const GibsonWallRect s = gibson_arrange_outer_box(sel, eye);
    double dx = 0, dy = 0, bestX = tol, bestY = tol;
    for (GibsonArrangeItem *item in items)
    {
        if (item == sel)
            continue;
        const GibsonWallRect o = gibson_arrange_outer_box(item, eye);
        const double xs[4] = {o.x1 - s.x0, o.x0 - s.x1, o.x0 - s.x0, o.x1 - s.x1};
        const double ys[4] = {o.y1 - s.y0, o.y0 - s.y1, o.y0 - s.y0, o.y1 - s.y1};
        for (int i = 0; i < 4; ++i)
        {
            if (std::fabs(xs[i]) < bestX)
            {
                bestX = std::fabs(xs[i]);
                dx = xs[i];
            }
            if (std::fabs(ys[i]) < bestY)
            {
                bestY = std::fabs(ys[i]);
                dy = ys[i];
            }
        }
    }
    sel.cx += dx;
    sel.cy += dy;
}

static NSColor *gibson_arrange_accent(void)
{
    return [NSColor colorWithCalibratedRed:0.25 green:0.75 blue:1.0 alpha:1.0];
}

#pragma mark - Canvas

@interface GibsonArrangeCanvas : NSView
@property(nonatomic, copy) NSArray<GibsonArrangeItem *> *items;
@property(nonatomic, copy) void (^onMove)(void);     // while dragging
@property(nonatomic, copy) void (^onCommit)(void);   // drag ended or nudged
@property(nonatomic, copy) void (^onSelect)(void);
@property(nonatomic, readonly) GibsonArrangeItem *selected;
@end

@implementation GibsonArrangeCanvas
{
    GibsonArrangeItem *_selected;
    BOOL _dragging;
    NSPoint _lastMouse;
    /* mm -> view: v = offset + (mm - origin) * scale. Frozen during a drag so
       the layout doesn't rescale under the pointer. */
    double _scale, _originX, _originY, _offsetX, _offsetY;
    double _rawX, _rawY;   // the dragged display's centre before snapping
}

- (GibsonArrangeItem *)selected { return _selected; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)setItems:(NSArray<GibsonArrangeItem *> *)items
{
    _items = [items copy];
    if (![_items containsObject:_selected])
        _selected = nil;
    [self refit];
    if (_onSelect)
        _onSelect();
}

- (void)refit
{
    /* Fit the frames, bezels included. */
    GibsonWallRect u = gibson_arrange_bounds(_items);
    const simd_double3 eye = gibson_arrange_eye(_items);
    for (GibsonArrangeItem *item in _items)
    {
        const GibsonWallRect r = gibson_arrange_outer_box(item, eye);
        u = GibsonWallRect{std::min(u.x0, r.x0), std::min(u.y0, r.y0), std::max(u.x1, r.x1),
                           std::max(u.y1, r.y1)};
    }
    const double pad = 28;
    const double bw = std::max(1.0, u.x1 - u.x0), bh = std::max(1.0, u.y1 - u.y0);
    const NSSize size = self.bounds.size;
    _scale = std::max(0.01, std::min((size.width - 2 * pad) / bw, (size.height - 2 * pad) / bh));
    _originX = u.x0;
    _originY = u.y0;
    _offsetX = (size.width - bw * _scale) * 0.5;
    _offsetY = (size.height - bh * _scale) * 0.5;
    [self setNeedsDisplay:YES];
}

- (void)setFrameSize:(NSSize)newSize
{
    [super setFrameSize:newSize];
    if (!_dragging)
        [self refit];
}

- (NSPoint)viewPoint:(simd_double2)mm
{
    return NSMakePoint(_offsetX + (mm.x - _originX) * _scale, _offsetY + (mm.y - _originY) * _scale);
}

- (NSBezierPath *)pathForQuad:(const simd_double2 *)q
{
    NSBezierPath *path = [NSBezierPath bezierPath];
    [path moveToPoint:[self viewPoint:q[0]]];
    for (int i = 1; i < 4; ++i)
        [path lineToPoint:[self viewPoint:q[i]]];
    [path closePath];
    path.lineJoinStyle = NSLineJoinStyleRound;
    return path;
}

- (NSBezierPath *)framePathFor:(GibsonArrangeItem *)item eye:(simd_double3)eye
{
    simd_double2 q[4];
    gibson_arrange_outer_quad(item, eye, q);
    return [self pathForQuad:q];
}

- (void)drawRect:(NSRect)dirty
{
    [[NSColor colorWithCalibratedWhite:0.11 alpha:1.0] setFill];
    NSRectFill(self.bounds);

    const simd_double3 eye = gibson_arrange_eye(_items);
    for (GibsonArrangeItem *item in _items)
    {
        const BOOL sel = item == _selected;
        simd_double2 active[4];
        gibson_arrange_active_quad(item, eye, active);
        NSBezierPath *picture = [self pathForQuad:active];

        /* Frames that overlap can't both be where they are on the desk. */
        const GibsonWallRect box = gibson_arrange_outer_box(item, eye);
        BOOL clash = NO;
        for (GibsonArrangeItem *other in _items)
            if (other != item && gibson_arrange_overlap(box, gibson_arrange_outer_box(other, eye), 0.5))
                clash = YES;

        const BOOL bezel = item.bezelSide > 0 || item.bezelTop > 0 || item.bezelBottom > 0;
        if (bezel)
        {
            NSBezierPath *frame = [self framePathFor:item eye:eye];
            [[NSColor colorWithCalibratedWhite:0.03 alpha:1.0] setFill];
            [frame fill];
            [(clash ? NSColor.systemRedColor
                    : sel ? gibson_arrange_accent() : [NSColor colorWithCalibratedWhite:0.55 alpha:1.0])
                setStroke];
            frame.lineWidth = sel || clash ? 2 : 1;
            [frame stroke];
        }
        [[NSColor colorWithCalibratedRed:0.10 green:0.26 blue:0.42 alpha:sel ? 1.0 : 0.85] setFill];
        [picture fill];
        if (!bezel)
        {
            [(clash ? NSColor.systemRedColor
                    : sel ? gibson_arrange_accent() : [NSColor colorWithCalibratedWhite:0.75 alpha:1.0])
                setStroke];
            picture.lineWidth = sel || clash ? 2 : 1;
        }
        else
        {
            [[NSColor colorWithCalibratedWhite:0.75 alpha:0.6] setStroke];
            picture.lineWidth = 0.5;
        }
        [picture stroke];

        /* Evenly spaced lines across a tilted or turned panel bunch up towards
           its far edge, so the angle reads at a glance even when the trapezoid
           is subtle: across for tilt, up and down for swivel. */
        const BOOL tilted = fabs(item.tilt) >= 0.25, turned = fabs(item.swivel) >= 0.25;
        if (tilted || turned)
        {
            [NSGraphicsContext saveGraphicsState];
            [picture addClip];
            NSBezierPath *rungs = [NSBezierPath bezierPath];
            const int n = 10;
            for (int i = 1; i < n; ++i)
            {
                simd_double2 q[4];
                if (tilted)
                {
                    const double y = item.h * i / n;
                    gibson_arrange_quad(item, eye, 0, y, item.w, y, q);
                    [rungs moveToPoint:[self viewPoint:q[0]]];
                    [rungs lineToPoint:[self viewPoint:q[1]]];
                }
                if (turned)
                {
                    const double x = item.w * i / n;
                    gibson_arrange_quad(item, eye, x, 0, x, item.h, q);
                    [rungs moveToPoint:[self viewPoint:q[0]]];
                    [rungs lineToPoint:[self viewPoint:q[3]]];
                }
            }
            [[gibson_arrange_accent() colorWithAlphaComponent:0.18] setStroke];
            rungs.lineWidth = 1;
            [rungs stroke];
            [NSGraphicsContext restoreGraphicsState];
        }

        const NSRect r = picture.bounds;
        NSString *label = [NSString stringWithFormat:@"%@\n%.0f × %.0f mm",
                           item.screen.localizedName, item.w, item.h];
        if (bezel)
            label = [label stringByAppendingFormat:@"\nbezel ↔ %g  ↑ %g  ↓ %g", item.bezelSide,
                     item.bezelTop, item.bezelBottom];
        if (fabs(item.tilt) >= 0.25)
            label = [label stringByAppendingFormat:@"\nleans %.1f° %@", fabs(item.tilt),
                     item.tilt > 0 ? @"back" : @"forward"];
        if (fabs(item.swivel) >= 0.25)
            label = [label stringByAppendingFormat:@"\nturned %.1f°, %@ edge nearer",
                     fabs(item.swivel), item.swivel > 0 ? @"right" : @"left"];
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        style.alignment = NSTextAlignmentCenter;
        NSDictionary *attrs = @{
            NSFontAttributeName : [NSFont systemFontOfSize:11],
            NSForegroundColorAttributeName : NSColor.whiteColor,
            NSParagraphStyleAttributeName : style,
        };
        const NSSize ts = [label boundingRectWithSize:r.size
                                              options:NSStringDrawingUsesLineFragmentOrigin
                                           attributes:attrs].size;
        [label drawInRect:NSMakeRect(r.origin.x, NSMidY(r) - ts.height * 0.5, r.size.width, ts.height)
           withAttributes:attrs];
    }

    /* Where the camera points: the middle of the wall's bounding box. */
    const GibsonWallRect u = gibson_arrange_bounds(_items);
    const double vx = _offsetX + ((u.x0 + u.x1) * 0.5 - _originX) * _scale;
    const double vy = _offsetY + ((u.y0 + u.y1) * 0.5 - _originY) * _scale;
    [gibson_arrange_accent() setStroke];
    NSBezierPath *cross = [NSBezierPath bezierPath];
    [cross moveToPoint:NSMakePoint(vx - 9, vy)];
    [cross lineToPoint:NSMakePoint(vx + 9, vy)];
    [cross moveToPoint:NSMakePoint(vx, vy - 9)];
    [cross lineToPoint:NSMakePoint(vx, vy + 9)];
    [cross appendBezierPathWithOvalInRect:NSMakeRect(vx - 5, vy - 5, 10, 10)];
    cross.lineWidth = 1.5;
    [cross stroke];
}

- (void)mouseDown:(NSEvent *)event
{
    [self.window makeFirstResponder:self];
    const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    _selected = nil;
    const simd_double3 eye = gibson_arrange_eye(_items);
    for (GibsonArrangeItem *item in _items.reverseObjectEnumerator)
    {
        if ([[self framePathFor:item eye:eye] containsPoint:p])
        {
            _selected = item;
            break;
        }
    }
    _dragging = _selected != nil;
    _lastMouse = p;
    _rawX = _selected.cx;
    _rawY = _selected.cy;
    [self setNeedsDisplay:YES];
    if (_onSelect)
        _onSelect();
}

- (void)mouseDragged:(NSEvent *)event
{
    if (!_dragging)
        return;
    const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    /* Follow the pointer unsnapped, then snap, so an edge lets go once you
       drag past it. Option drags freely. */
    _rawX += (p.x - _lastMouse.x) / _scale;
    _rawY += (p.y - _lastMouse.y) / _scale;
    _lastMouse = p;
    _selected.cx = _rawX;
    _selected.cy = _rawY;
    if (!(event.modifierFlags & NSEventModifierFlagOption))
        gibson_arrange_snap(_items, _selected, 8.0 / _scale);
    [self setNeedsDisplay:YES];
    if (_onMove)
        _onMove();
}

- (void)mouseUp:(NSEvent *)event
{
    if (!_dragging)
        return;
    _dragging = NO;
    /* config.txt keeps tenths of a millimetre; rounding to whole ones would
       pull a snapped frame off its neighbour. */
    _selected.cx = std::round(_selected.cx * 10.0) / 10.0;
    _selected.cy = std::round(_selected.cy * 10.0) / 10.0;
    [self refit];
    if (_onCommit)
        _onCommit();
}

- (void)keyDown:(NSEvent *)event
{
    if (!_selected)
    {
        [super keyDown:event];
        return;
    }
    const double step = (event.modifierFlags & NSEventModifierFlagShift) ? 10.0 : 1.0;
    switch (event.keyCode)
    {
        case 123: _selected.cx -= step; break;
        case 124: _selected.cx += step; break;
        case 125: _selected.cy -= step; break;
        case 126: _selected.cy += step; break;
        default:
            [super keyDown:event];
            return;
    }
    [self refit];
    if (_onCommit)
        _onCommit();
}

@end

#pragma mark - Alignment pattern

/* Drawn on every real display from the same wall coordinates the screensaver
 * uses: when the layout matches the desk, the lines and rings run straight
 * across the gaps between displays. */
@interface GibsonArrangePattern : NSView
@property(nonatomic, strong) GibsonArrangeItem *item;
@property(nonatomic, copy) NSArray<GibsonArrangeItem *> *items;
@property(nonatomic) BOOL overScene;   // a rendered frame of the city sits behind
@end

@implementation GibsonArrangePattern

- (void)drawRect:(NSRect)dirty
{
    if (!_overScene)
    {
        [[NSColor colorWithCalibratedWhite:0.0 alpha:0.88] setFill];
        NSRectFillUsingOperation(self.bounds, NSCompositingOperationCopy);
    }
    if (!_item || _item.w <= 0 || _item.h <= 0)
        return;

    /* Lines and rings live on the flat wall plane; a tilted panel shows them
       the way the screensaver's camera for that panel would. */
    const GibsonWallRect u = gibson_arrange_bounds(_items);
    const simd_double3 eye = gibson_wall_eye(u);
    const GibsonWallPlane plane = gibson_wall_plane([_item rect], _item.tilt, _item.swivel);
    const double sx = self.bounds.size.width / _item.w;
    const double sy = self.bounds.size.height / _item.h;

    /* The part of the wall plane this panel can see, plus a margin. */
    GibsonWallRect vis{0, 0, 0, 0};
    for (int i = 0; i < 4; ++i)
    {
        double x, y;
        gibson_panel_to_wall(eye, plane, (i & 1) ? plane.w : 0.0, (i & 2) ? plane.h : 0.0, &x, &y);
        if (i == 0)
            vis = GibsonWallRect{x, y, x, y};
        vis.x0 = std::min(vis.x0, x);
        vis.y0 = std::min(vis.y0, y);
        vis.x1 = std::max(vis.x1, x);
        vis.y1 = std::max(vis.y1, y);
    }
    const double margin = 10.0;
    vis = GibsonWallRect{vis.x0 - margin, vis.y0 - margin, vis.x1 + margin, vis.y1 + margin};

    auto pt = [&](double x, double y, NSPoint *out) {
        double px, py;
        if (!gibson_wall_to_panel(eye, plane, x, y, &px, &py))
            return false;
        *out = NSMakePoint(px * sx, py * sy);
        return true;
    };

    /* Diagonals both ways, so a seam shows both sideways and vertical error.
       Each is y = slope * x + c, clipped to the visible part of the wall. */
    const double pitch = 60.0;
    NSBezierPath *lines = [NSBezierPath bezierPath];
    for (int dir = 0; dir < 2; ++dir)
    {
        const double slope = dir ? 1.0 : -1.0;
        const double cA = vis.y0 - slope * vis.x0, cB = vis.y1 - slope * vis.x1;
        const double cC = vis.y0 - slope * vis.x1, cD = vis.y1 - slope * vis.x0;
        const double cMin = std::min(std::min(cA, cB), std::min(cC, cD));
        const double cMax = std::max(std::max(cA, cB), std::max(cC, cD));
        for (double c = std::ceil(cMin / pitch) * pitch; c <= cMax; c += pitch)
        {
            /* x range where the line stays inside vis vertically */
            double xa = (vis.y0 - c) / slope, xb = (vis.y1 - c) / slope;
            if (xa > xb)
                std::swap(xa, xb);
            xa = std::max(xa, vis.x0);
            xb = std::min(xb, vis.x1);
            NSPoint p0, p1;
            if (xa >= xb || !pt(xa, slope * xa + c, &p0) || !pt(xb, slope * xb + c, &p1))
                continue;
            [lines moveToPoint:p0];
            [lines lineToPoint:p1];
        }
    }
    /* Over the city the grid is only a guide; keep it from hiding the picture. */
    [(_overScene ? [NSColor colorWithCalibratedRed:1.0 green:0.45 blue:0.75 alpha:0.45]
                 : [NSColor colorWithCalibratedRed:0.2 green:0.55 blue:1.0 alpha:0.9]) setStroke];
    lines.lineWidth = _overScene ? 1.0 : 1.5;
    [lines stroke];

    /* Rings around the point the camera looks at. */
    const double cx = (u.x0 + u.x1) * 0.5, cy = (u.y0 + u.y1) * 0.5;
    const double span = (u.x1 - u.x0) + (u.y1 - u.y0);
    NSBezierPath *rings = [NSBezierPath bezierPath];
    auto segment = [&](double x0, double y0, double x1, double y1) {
        auto inside = [&](double x, double y) {
            return x >= vis.x0 && x <= vis.x1 && y >= vis.y0 && y <= vis.y1;
        };
        NSPoint a, b;
        if ((!inside(x0, y0) && !inside(x1, y1)) || !pt(x0, y0, &a) || !pt(x1, y1, &b))
            return;
        [rings moveToPoint:a];
        [rings lineToPoint:b];
    };
    for (double radius = 100.0; radius <= span; radius += 100.0)
    {
        const int steps = 240;
        for (int i = 0; i < steps; ++i)
        {
            const double a0 = 2.0 * M_PI * i / steps, a1 = 2.0 * M_PI * (i + 1) / steps;
            segment(cx + radius * std::cos(a0), cy + radius * std::sin(a0),
                    cx + radius * std::cos(a1), cy + radius * std::sin(a1));
        }
    }
    segment(cx - 30, cy, cx + 30, cy);
    segment(cx, cy - 30, cx, cy + 30);
    [[NSColor colorWithCalibratedRed:1.0 green:0.85 blue:0.3 alpha:_overScene ? 0.7 : 0.95] setStroke];
    rings.lineWidth = _overScene ? 1.5 : 2.5;
    rings.lineCapStyle = NSLineCapStyleRound;
    [rings stroke];

    NSDictionary *attrs = @{
        NSFontAttributeName : [NSFont boldSystemFontOfSize:22],
        NSForegroundColorAttributeName : NSColor.whiteColor,
    };
    [_item.screen.localizedName drawAtPoint:NSMakePoint(24, 24) withAttributes:attrs];
}

@end

#pragma mark - Tilt glyph

/* Side view of the selected display, seen from its left: you on the left
 * looking right, the panel as a bar that leans the way the slider says. */
@interface GibsonTiltGlyph : NSView
@property(nonatomic) double tilt;
@property(nonatomic) BOOL active;
@end

/* Top view of the selected display: you at the bottom looking up, the panel
 * as a bar that turns the way the swivel slider says. */
@interface GibsonSwivelGlyph : GibsonTiltGlyph
@end

@implementation GibsonSwivelGlyph

- (void)drawRect:(NSRect)dirty
{
    const NSRect b = self.bounds;
    const CGFloat alpha = self.active ? 1.0 : 0.35;
    const NSPoint eye = NSMakePoint(NSMidX(b), 6);
    const NSPoint pivot = NSMakePoint(NSMidX(b), b.size.height - 10);
    const CGFloat half = b.size.width * 0.5 - 10;

    [[NSColor.secondaryLabelColor colorWithAlphaComponent:alpha] set];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(eye.x - 3.5, eye.y - 3.5, 7, 7)] fill];
    const CGFloat dash[] = {2, 3};
    NSBezierPath *sight = [NSBezierPath bezierPath];
    [sight moveToPoint:NSMakePoint(eye.x, eye.y + 6)];
    [sight lineToPoint:NSMakePoint(pivot.x, pivot.y - 4)];
    [sight setLineDash:dash count:2 phase:0];
    [sight stroke];
    NSBezierPath *ref = [NSBezierPath bezierPath];
    [ref moveToPoint:NSMakePoint(pivot.x - half, pivot.y)];
    [ref lineToPoint:NSMakePoint(pivot.x + half, pivot.y)];
    [ref setLineDash:dash count:2 phase:0];
    [ref stroke];

    /* Positive swivel brings the right end nearer (down, towards you). */
    const double s = self.tilt * M_PI / 180.0;
    const CGFloat dx = half * std::cos(s), dy = half * std::sin(s);
    NSBezierPath *panel = [NSBezierPath bezierPath];
    [panel moveToPoint:NSMakePoint(pivot.x - dx, pivot.y + dy)];
    [panel lineToPoint:NSMakePoint(pivot.x + dx, pivot.y - dy)];
    panel.lineWidth = 3;
    panel.lineCapStyle = NSLineCapStyleRound;
    [[gibson_arrange_accent() colorWithAlphaComponent:alpha] setStroke];
    [panel stroke];
}

@end

@implementation GibsonTiltGlyph

- (NSSize)intrinsicContentSize { return NSMakeSize(64, 40); }

- (void)setTilt:(double)tilt
{
    _tilt = tilt;
    [self setNeedsDisplay:YES];
}

- (void)setActive:(BOOL)active
{
    _active = active;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirty
{
    const NSRect b = self.bounds;
    const CGFloat alpha = _active ? 1.0 : 0.35;
    const NSPoint eye = NSMakePoint(8, NSMidY(b));
    const NSPoint pivot = NSMakePoint(b.size.width - 22, NSMidY(b));
    const CGFloat half = b.size.height * 0.5 - 4;

    /* You, and your line of sight. */
    [[NSColor.secondaryLabelColor colorWithAlphaComponent:alpha] set];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(eye.x - 3.5, eye.y - 3.5, 7, 7)] fill];
    NSBezierPath *sight = [NSBezierPath bezierPath];
    [sight moveToPoint:NSMakePoint(eye.x + 6, eye.y)];
    [sight lineToPoint:NSMakePoint(pivot.x - 6, pivot.y)];
    const CGFloat dash[] = {2, 3};
    [sight setLineDash:dash count:2 phase:0];
    sight.lineWidth = 1;
    [sight stroke];

    /* Upright reference. */
    NSBezierPath *ref = [NSBezierPath bezierPath];
    [ref moveToPoint:NSMakePoint(pivot.x, pivot.y - half)];
    [ref lineToPoint:NSMakePoint(pivot.x, pivot.y + half)];
    [ref setLineDash:dash count:2 phase:0];
    ref.lineWidth = 1;
    [ref stroke];

    /* The panel: leaning back moves its top away from you (to the right). */
    const double t = _tilt * M_PI / 180.0;
    const CGFloat dx = half * std::sin(t), dy = half * std::cos(t);
    NSBezierPath *panel = [NSBezierPath bezierPath];
    [panel moveToPoint:NSMakePoint(pivot.x - dx, pivot.y - dy)];
    [panel lineToPoint:NSMakePoint(pivot.x + dx, pivot.y + dy)];
    panel.lineWidth = 3;
    panel.lineCapStyle = NSLineCapStyleRound;
    [[gibson_arrange_accent() colorWithAlphaComponent:alpha] setStroke];
    [panel stroke];
}

@end

#pragma mark - Controller

@implementation GibsonArrangeController
{
    NSWindow *_window;
    GibsonArrangeCanvas *_canvas;
    NSButton *_patternBox;
    NSTextField *_tiltTitle;
    NSSlider *_tiltSlider;
    NSTextField *_tiltValue;
    GibsonTiltGlyph *_tiltGlyph;
    NSTextField *_swivelTitle;
    NSSlider *_swivelSlider;
    NSTextField *_swivelValue;
    GibsonSwivelGlyph *_swivelGlyph;
    NSButton *_lidButton;
    NSTextField *_bezelTitle;
    NSTextField *_bezelFields[3];   // sides, top, bottom
    NSStepper *_bezelSteppers[3];
    /* The city behind the pattern: its own clock, so it can run slowly,
       pause, or jump to another part of the flight. */
    NSStackView *_cityRow;
    NSButton *_playButton;
    NSPopUpButton *_speedPopup;
    NSSlider *_timeline;
    NSTextField *_momentLabel;
    NSButton *_linesBox;
    NSTimer *_cityTimer;
    NSArray<NSDictionary *> *_moments;
    double _cityTime, _citySpeed, _loop;
    CFTimeInterval _lastFrame;
    BOOL _cityPlaying;
    NSMutableArray<GibsonArrangePattern *> *_patternViews;
    NSMutableArray<SCNView *> *_sceneViews;
    NSMutableArray<SCNNode *> *_sceneCams;
    NSArray<GibsonArrangeItem *> *_items;
    NSMutableArray<NSWindow *> *_patterns;
}

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _patterns = [NSMutableArray array];
        _patternViews = [NSMutableArray array];
        _sceneViews = [NSMutableArray array];
        _sceneCams = [NSMutableArray array];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(screensChanged:)
                                                     name:NSApplicationDidChangeScreenParametersNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)buildWindow
{
    _canvas = [[GibsonArrangeCanvas alloc] initWithFrame:NSMakeRect(0, 0, 640, 380)];
    _canvas.translatesAutoresizingMaskIntoConstraints = NO;
    __weak GibsonArrangeController *weakSelf = self;
    _canvas.onMove = ^{ [weakSelf redrawPatterns]; };
    _canvas.onCommit = ^{ [weakSelf save]; };
    _canvas.onSelect = ^{ [weakSelf refreshTilt]; };

    _tiltTitle = [NSTextField labelWithString:@"Tilt:"];
    _tiltSlider = [NSSlider sliderWithValue:0 minValue:-45 maxValue:45
                                     target:self action:@selector(tiltMoved:)];
    _tiltSlider.continuous = YES;
    [_tiltSlider.widthAnchor constraintGreaterThanOrEqualToConstant:160].active = YES;
    _tiltValue = [NSTextField labelWithString:@""];
    _tiltValue.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize
                                                       weight:NSFontWeightRegular];
    [_tiltValue.widthAnchor constraintGreaterThanOrEqualToConstant:104].active = YES;
    _tiltGlyph = [[GibsonTiltGlyph alloc] initWithFrame:NSZeroRect];
    _tiltGlyph.toolTip = @"Side view: you are the dot on the left, the bar is the display.";
    auto end = [](NSString *text) {
        NSTextField *f = [NSTextField labelWithString:text];
        f.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        f.textColor = NSColor.secondaryLabelColor;
        return f;
    };
    NSButton *level = [NSButton buttonWithTitle:@"Upright" target:self action:@selector(tiltReset:)];
    level.controlSize = NSControlSizeSmall;
    _lidButton = [NSButton buttonWithTitle:@"Use Lid Angle" target:self action:@selector(tiltFromLid:)];
    _lidButton.controlSize = NSControlSizeSmall;
    _lidButton.toolTip = @"Reads the MacBook's hinge sensor. Assumes the MacBook's base is lying "
                         @"flat; on a sloped stand, adjust by the stand's angle.";
    NSStackView *tiltRow = [NSStackView stackViewWithViews:@[
        _tiltTitle, end(@"forward"), _tiltSlider, end(@"back"), _tiltGlyph, _tiltValue, level,
        _lidButton
    ]];
    tiltRow.spacing = 8;

    _swivelTitle = [NSTextField labelWithString:@"Swivel:"];
    _swivelSlider = [NSSlider sliderWithValue:0 minValue:-45 maxValue:45
                                       target:self action:@selector(swivelMoved:)];
    _swivelSlider.continuous = YES;
    [_swivelSlider.widthAnchor constraintGreaterThanOrEqualToConstant:160].active = YES;
    _swivelValue = [NSTextField labelWithString:@""];
    _swivelValue.font = _tiltValue.font;
    [_swivelValue.widthAnchor constraintGreaterThanOrEqualToConstant:104].active = YES;
    _swivelGlyph = [[GibsonSwivelGlyph alloc] initWithFrame:NSZeroRect];
    _swivelGlyph.toolTip = @"Top view: you are the dot at the bottom, the bar is the display.";
    NSButton *straight = [NSButton buttonWithTitle:@"Straight" target:self action:@selector(swivelReset:)];
    straight.controlSize = NSControlSizeSmall;
    NSButton *faceMe = [NSButton buttonWithTitle:@"Face Me" target:self action:@selector(swivelFaceMe:)];
    faceMe.controlSize = NSControlSizeSmall;
    faceMe.toolTip = @"Turn the display to face your seat squarely, as side monitors often are.";
    NSStackView *swivelRow = [NSStackView stackViewWithViews:@[
        _swivelTitle, end(@"left nearer"), _swivelSlider, end(@"right nearer"), _swivelGlyph,
        _swivelValue, straight, faceMe
    ]];
    swivelRow.spacing = 8;

    _bezelTitle = [NSTextField labelWithString:@"Bezel:"];
    NSMutableArray<NSView *> *bezelViews = [NSMutableArray arrayWithObject:_bezelTitle];
    NSNumberFormatter *mm = [[NSNumberFormatter alloc] init];
    mm.numberStyle = NSNumberFormatterDecimalStyle;
    mm.minimum = @0;
    mm.maximum = @100;
    mm.minimumFractionDigits = 0;
    mm.maximumFractionDigits = 1;
    NSArray<NSString *> *sides = @[ @"sides", @"top", @"bottom" ];
    NSString *bottomTip = @"Height of the frame below the picture, in mm. For a MacBook, "
                          @"measure to where the hinge hides the lid.";
    NSArray<NSString *> *tips = @[
        @"Width of the frame at the left and right of the picture, in mm.",
        @"Height of the frame above the picture, in mm.", bottomTip,
    ];
    for (int i = 0; i < 3; ++i)
    {
        NSTextField *field = [NSTextField textFieldWithString:@"0"];
        field.formatter = mm;
        field.alignment = NSTextAlignmentRight;
        field.tag = i;
        field.target = self;
        field.action = @selector(bezelTyped:);
        field.toolTip = tips[i];
        [field.cell setSendsActionOnEndEditing:YES];
        [field.widthAnchor constraintEqualToConstant:48].active = YES;
        NSStepper *stepper = [[NSStepper alloc] init];
        stepper.minValue = 0;
        stepper.maxValue = 100;
        stepper.increment = 0.5;
        stepper.valueWraps = NO;
        stepper.autorepeat = YES;
        stepper.tag = i;
        stepper.target = self;
        stepper.action = @selector(bezelStepped:);
        _bezelFields[i] = field;
        _bezelSteppers[i] = stepper;
        [bezelViews addObjectsFromArray:@[ end(sides[i]), field, stepper ]];
    }
    [bezelViews addObject:end(@"mm")];
    NSStackView *bezelRow = [NSStackView stackViewWithViews:bezelViews];
    bezelRow.spacing = 6;
    [bezelRow setCustomSpacing:14 afterView:_bezelSteppers[0]];
    [bezelRow setCustomSpacing:14 afterView:_bezelSteppers[1]];

    NSTextField *note = [NSTextField wrappingLabelWithString:
        @"Enter each display's bezel (the frame around the picture), then drag the displays "
        @"to match your desk: frame edges snap together (hold Option to drag freely), and "
        @"frames shown in red overlap. Arrow keys nudge the selected display by 1 mm "
        @"(Shift: 10 mm). Tilt is how far the selected display leans from upright: back "
        @"means its top edge is further from you than its bottom edge, as when a laptop lid "
        @"is opened past 90°. Swivel is how far it is turned sideways: a monitor off to your "
        @"right that is angled towards you has its right edge nearer. Displays are drawn as "
        @"you see them from your seat, so a tilted or turned one shows as a trapezoid; a side "
        @"resting against a neighbour stays there as you change its tilt, swivel or bezel. "
        @"The crosshair marks where the camera points."];
    note.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    note.textColor = NSColor.secondaryLabelColor;

    _patternBox = [NSButton checkboxWithTitle:@"Show alignment pattern on the displays"
                                       target:self action:@selector(togglePattern:)];
    NSButton *reset = [NSButton buttonWithTitle:@"Reset to System Arrangement"
                                         target:self action:@selector(reset:)];
    NSButton *done = [NSButton buttonWithTitle:@"Done" target:self action:@selector(done:)];
    done.keyEquivalent = @"\r";
    NSView *spacer = [[NSView alloc] init];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *buttons = [NSStackView stackViewWithViews:@[ _patternBox, spacer, reset, done ]];
    buttons.spacing = 10;

    /* Shown with the pattern: drive the city behind it. */
    _playButton = [NSButton buttonWithTitle:@"Play" target:self action:@selector(togglePlay:)];
    _playButton.controlSize = NSControlSizeSmall;
    _speedPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _speedPopup.controlSize = NSControlSizeSmall;
    const double speeds[] = {0.1, 0.25, 0.5, 1.0};
    for (double s : speeds)
    {
        [_speedPopup addItemWithTitle:[NSString stringWithFormat:@"%g× speed", s]];
        _speedPopup.lastItem.representedObject = @(s);
    }
    [_speedPopup selectItemAtIndex:1];
    _speedPopup.target = self;
    _speedPopup.action = @selector(speedChanged:);
    _citySpeed = 0.25;
    _loop = [GibsonSCNCamera loopDuration];
    _cityTime = kArrangeStillTime;
    _timeline = [NSSlider sliderWithValue:_cityTime minValue:0 maxValue:_loop
                                   target:self action:@selector(scrubbed:)];
    _timeline.continuous = YES;
    _timeline.controlSize = NSControlSizeSmall;
    _timeline.toolTip = @"Where along the flight the city is shown.";
    [_timeline.widthAnchor constraintGreaterThanOrEqualToConstant:160].active = YES;
    NSButton *prev = [NSButton buttonWithTitle:@"◀ View" target:self action:@selector(previousMoment:)];
    NSButton *next = [NSButton buttonWithTitle:@"View ▶" target:self action:@selector(nextMoment:)];
    prev.controlSize = NSControlSizeSmall;
    next.controlSize = NSControlSizeSmall;
    prev.toolTip = next.toolTip = @"Jump to another part of the flight: turns, the rooftop "
                                  @"swoop, straight runs.";
    _momentLabel = [NSTextField labelWithString:@""];
    _momentLabel.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _momentLabel.textColor = NSColor.secondaryLabelColor;
    [_momentLabel.widthAnchor constraintGreaterThanOrEqualToConstant:150].active = YES;
    _linesBox = [NSButton checkboxWithTitle:@"Guide lines" target:self action:@selector(toggleLines:)];
    _linesBox.controlSize = NSControlSizeSmall;
    _linesBox.state = NSControlStateValueOn;
    _cityRow = [NSStackView stackViewWithViews:@[
        end(@"City:"), _playButton, _speedPopup, _timeline, prev, next, _momentLabel, _linesBox
    ]];
    _cityRow.spacing = 8;
    _cityRow.hidden = YES;

    NSStackView *content =
        [NSStackView stackViewWithViews:@[ _canvas, tiltRow, swivelRow, bezelRow, note, _cityRow,
                                           buttons ]];
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.alignment = NSLayoutAttributeLeading;
    content.spacing = 12;
    content.edgeInsets = NSEdgeInsetsMake(16, 16, 16, 16);
    content.translatesAutoresizingMaskIntoConstraints = NO;

    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 860, 680)
                                          styleMask:(NSWindowStyleMaskTitled |
                                                     NSWindowStyleMaskClosable |
                                                     NSWindowStyleMaskResizable)
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = @"Arrange Displays";
    _window.releasedWhenClosed = NO;
    _window.delegate = self;
    _window.contentMinSize = NSMakeSize(820, 560);
    NSView *host = [[NSView alloc] init];
    [host addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:host.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
        [_canvas.widthAnchor constraintEqualToAnchor:content.widthAnchor constant:-32],
        [buttons.widthAnchor constraintEqualToAnchor:content.widthAnchor constant:-32],
        [_canvas.heightAnchor constraintGreaterThanOrEqualToConstant:240],
    ]];
    [_canvas setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    _window.contentView = host;
    [_window center];
}

- (void)reloadItems
{
    _items = gibson_arrange_load();
    _canvas.items = _items;
    [self refreshTilt];
    if (_patterns.count)
        [self showPatterns];
}

- (void)show
{
    if (!_window)
        [self buildWindow];
    [self reloadItems];
    [_window makeKeyAndOrderFront:nil];
    [_window makeFirstResponder:_canvas];
    if (std::getenv("GIBSON_ARRANGE_PATTERN") && !_patterns.count)   /* dev: start with it on */
    {
        _patternBox.state = NSControlStateValueOn;
        [self showPatterns];
        if (std::getenv("GIBSON_ARRANGE_PLAY"))
            [self setCityPlaying:YES];
    }
}

- (void)close
{
    [_window close];
}

- (void)refreshTilt
{
    GibsonArrangeItem *item = _canvas.selected;
    _tiltSlider.enabled = item != nil;
    _tiltSlider.doubleValue = item ? item.tilt : 0;
    _tiltTitle.stringValue = item ? [NSString stringWithFormat:@"Tilt of %@:", item.screen.localizedName]
                                  : @"Tilt (select a display):";
    _tiltTitle.textColor = item ? NSColor.labelColor : NSColor.secondaryLabelColor;
    if (!item)
        _tiltValue.stringValue = @"";
    else if (fabs(item.tilt) < 0.25)
        _tiltValue.stringValue = @"upright";
    else
        _tiltValue.stringValue = [NSString stringWithFormat:@"%.1f° %@", fabs(item.tilt),
                                  item.tilt > 0 ? @"back" : @"forward"];
    _tiltGlyph.tilt = item ? item.tilt : 0;
    _tiltGlyph.active = item != nil;

    /* Only the MacBook's own display has a hinge to read. */
    NSNumber *num = item.screen.deviceDescription[@"NSScreenNumber"];
    double lid = 0;
    const BOOL canRead = num && CGDisplayIsBuiltin((CGDirectDisplayID)num.unsignedIntValue)
        && gibson_lid_angle(&lid);
    _lidButton.hidden = !canRead;
    if (canRead)
        _lidButton.title = [NSString stringWithFormat:@"Use Lid Angle (%.0f°)", lid];

    _swivelSlider.enabled = item != nil;
    _swivelSlider.doubleValue = item ? item.swivel : 0;
    _swivelTitle.stringValue = item ? [NSString stringWithFormat:@"Swivel of %@:", item.screen.localizedName]
                                    : @"Swivel (select a display):";
    _swivelTitle.textColor = _tiltTitle.textColor;
    if (!item)
        _swivelValue.stringValue = @"";
    else if (fabs(item.swivel) < 0.25)
        _swivelValue.stringValue = @"straight on";
    else
        _swivelValue.stringValue = [NSString stringWithFormat:@"%.1f° %@ nearer", fabs(item.swivel),
                                    item.swivel > 0 ? @"right" : @"left"];
    _swivelGlyph.tilt = item ? item.swivel : 0;
    _swivelGlyph.active = item != nil;

    _bezelTitle.stringValue = item ? [NSString stringWithFormat:@"Bezel of %@:", item.screen.localizedName]
                                   : @"Bezel (select a display):";
    _bezelTitle.textColor = _tiltTitle.textColor;
    const double bezels[3] = {item.bezelSide, item.bezelTop, item.bezelBottom};
    for (int i = 0; i < 3; ++i)
    {
        _bezelFields[i].enabled = item != nil;
        _bezelSteppers[i].enabled = item != nil;
        _bezelFields[i].doubleValue = item ? bezels[i] : 0;
        _bezelSteppers[i].doubleValue = item ? bezels[i] : 0;
    }
}

- (void)setSelectedTilt:(double)tilt
{
    GibsonArrangeItem *item = _canvas.selected;
    if (!item)
        return;
    const double value = std::round(tilt * 2.0) / 2.0;
    gibson_arrange_keep_contacts(_items, item, ^{ item.tilt = value; });
    [self refreshTilt];
    [_canvas refit];
    [self save];
}

- (void)setSelectedSwivel:(double)swivel
{
    GibsonArrangeItem *item = _canvas.selected;
    if (!item)
        return;
    const double value = std::round(std::max(-45.0, std::min(45.0, swivel)) * 2.0) / 2.0;
    gibson_arrange_keep_contacts(_items, item, ^{ item.swivel = value; });
    [self refreshTilt];
    [_canvas refit];
    [self save];
}

- (void)swivelMoved:(NSSlider *)sender
{
    [self setSelectedSwivel:sender.doubleValue];
}

- (void)swivelReset:(id)sender
{
    [self setSelectedSwivel:0];
}

/* Square on to the seat: a display right of centre turns its right edge in. */
- (void)swivelFaceMe:(id)sender
{
    GibsonArrangeItem *item = _canvas.selected;
    if (!item)
        return;
    const simd_double3 eye = gibson_arrange_eye(_items);
    [self setSelectedSwivel:std::atan2(item.cx - eye.x, eye.z) * 180.0 / M_PI];
}

- (void)setSelectedBezel:(int)which to:(double)value
{
    GibsonArrangeItem *item = _canvas.selected;
    if (!item || which < 0 || which > 2)
        return;
    value = std::round(std::max(0.0, std::min(100.0, value)) * 10.0) / 10.0;
    gibson_arrange_keep_contacts(_items, item, ^{
        switch (which)
        {
            case 0: item.bezelSide = value; break;
            case 1: item.bezelTop = value; break;
            default: item.bezelBottom = value; break;
        }
    });
    [self refreshTilt];
    [_canvas refit];
    [self save];
}

- (void)bezelTyped:(NSTextField *)sender
{
    [self setSelectedBezel:(int)sender.tag to:sender.doubleValue];
}

- (void)bezelStepped:(NSStepper *)sender
{
    [self setSelectedBezel:(int)sender.tag to:sender.doubleValue];
}

- (void)tiltMoved:(NSSlider *)sender
{
    [self setSelectedTilt:sender.doubleValue];
}

/* A lid square to the keyboard (90°) is upright when the base lies flat. */
- (void)tiltFromLid:(id)sender
{
    double lid = 0;
    if (!gibson_lid_angle(&lid))
        return;
    [self setSelectedTilt:std::max(-45.0, std::min(45.0, lid - 90.0))];
}

- (void)tiltReset:(id)sender
{
    [self setSelectedTilt:0];
}

- (void)save
{
    [self redrawPatterns];
    for (GibsonArrangeItem *item in _items)
    {
        if (!item.key)
            continue;
        NSString *value = [NSString stringWithFormat:@"%.1f %.1f %.1f %.1f", item.cx, item.cy,
                           item.tilt, item.swivel];
        if (!gibson_settings_set(item.key.UTF8String, value.UTF8String))
            NSLog(@"The Gibson: couldn't write %@ to config.txt", item.key);
        NSString *bezelKey = gibson_arrange_bezel_key(item.key);
        const BOOL any = item.bezelSide > 0 || item.bezelTop > 0 || item.bezelBottom > 0;
        if (bezelKey && (any || gibson_settings_raw(bezelKey.UTF8String)[0]))
        {
            NSString *bezel = [NSString stringWithFormat:@"%.1f %.1f %.1f", item.bezelSide,
                               item.bezelTop, item.bezelBottom];
            gibson_settings_set(bezelKey.UTF8String, bezel.UTF8String);
        }
    }
    gibson_arrange_reload_settings();
}

- (void)reset:(id)sender
{
    for (GibsonArrangeItem *item in _items)
    {
        /* Only touch lines that exist; "auto" doesn't parse as a position. */
        if (item.key && gibson_settings_raw(item.key.UTF8String)[0])
            gibson_settings_set(item.key.UTF8String, "auto");
    }
    [self reloadItems];
}

- (void)done:(id)sender
{
    [_window close];
}

#pragma mark Pattern windows

- (void)hidePatterns
{
    [self setCityPlaying:NO];
    _cityRow.hidden = YES;
    for (NSWindow *w in _patterns)
        [w orderOut:nil];
    for (SCNNode *cam in _sceneCams)
        [cam removeFromParentNode];
    if (_sceneCams.count && _media)
        [[GibsonSCNScene sharedWorldForPreview:NO mediaURL:_media] resetClock];
    [_patterns removeAllObjects];
    [_patternViews removeAllObjects];
    [_sceneViews removeAllObjects];
    [_sceneCams removeAllObjects];
}

- (GibsonSCNScene *)cityWorld
{
    if (!_media)
        return nil;
    GibsonSCNScene *world = [GibsonSCNScene sharedWorldForPreview:NO mediaURL:_media];
    [world seekToTime:_cityTime];
    return world;
}

- (void)redrawCity
{
    for (SCNView *view in _sceneViews)
        [view setNeedsDisplay:YES];
    _timeline.doubleValue = _cityTime;
    /* Name the stretch of flight on screen. */
    NSString *name = @"";
    for (NSDictionary *m in _moments)
    {
        if ([m[@"time"] doubleValue] <= _cityTime + 0.5)
            name = m[@"name"];
    }
    const int s = (int)_cityTime;
    _momentLabel.stringValue = [NSString stringWithFormat:@"%d:%02d %@", s / 60, s % 60, name];
}

- (void)setCityTime:(double)time
{
    _cityTime = std::fmod(std::fmod(time, _loop) + _loop, _loop);
    if (_sceneViews.count && _media)
        [[GibsonSCNScene sharedWorldForPreview:NO mediaURL:_media] seekToTime:_cityTime];
    [self redrawCity];
}

- (void)cityFrame:(NSTimer *)timer
{
    const CFTimeInterval now = CACurrentMediaTime();
    const double dt = std::min(0.1, now - _lastFrame);
    _lastFrame = now;
    if (!_cityPlaying || !_sceneViews.count || !_media)
        return;
    const double t = _cityTime + dt * _citySpeed;
    if (t >= _loop)
    {
        [self setCityTime:t];
        return;
    }
    _cityTime = t;
    [[GibsonSCNScene sharedWorldForPreview:NO mediaURL:_media] tickAtTime:_cityTime];
    [self redrawCity];
}

- (void)setCityPlaying:(BOOL)playing
{
    _cityPlaying = playing && _sceneViews.count;
    _playButton.title = _cityPlaying ? @"Pause" : @"Play";
    [_cityTimer invalidate];
    _cityTimer = nil;
    if (_cityPlaying)
    {
        _lastFrame = CACurrentMediaTime();
        _cityTimer = [NSTimer timerWithTimeInterval:1.0 / 60.0 target:self
                                           selector:@selector(cityFrame:) userInfo:nil repeats:YES];
        /* Common modes: keep moving while a slider is being dragged. */
        [[NSRunLoop mainRunLoop] addTimer:_cityTimer forMode:NSRunLoopCommonModes];
    }
}

- (void)togglePlay:(id)sender
{
    [self setCityPlaying:!_cityPlaying];
}

- (void)speedChanged:(NSPopUpButton *)sender
{
    _citySpeed = [sender.selectedItem.representedObject doubleValue];
}

- (void)scrubbed:(NSSlider *)sender
{
    [self setCityTime:sender.doubleValue];
}

- (void)nextMoment:(id)sender
{
    if (!_moments.count)
        return;
    for (NSDictionary *m in _moments)
    {
        if ([m[@"time"] doubleValue] > _cityTime + 0.5)
        {
            [self setCityTime:[m[@"time"] doubleValue]];
            return;
        }
    }
    [self setCityTime:[_moments.firstObject[@"time"] doubleValue]];
}

- (void)previousMoment:(id)sender
{
    if (!_moments.count)
        return;
    for (NSDictionary *m in _moments.reverseObjectEnumerator)
    {
        if ([m[@"time"] doubleValue] < _cityTime - 0.5)
        {
            [self setCityTime:[m[@"time"] doubleValue]];
            return;
        }
    }
    [self setCityTime:[_moments.lastObject[@"time"] doubleValue]];
}

- (void)toggleLines:(NSButton *)sender
{
    for (GibsonArrangePattern *view in _patternViews)
        view.hidden = sender.state != NSControlStateValueOn;
}

/* Each display shows the frame exactly as the screensaver would draw it for
 * the layout currently in the editor, saved or not. */
- (void)updateSceneCameras
{
    if (_sceneCams.count != _items.count)
        return;
    const GibsonWallRect u = gibson_arrange_bounds(_items);
    const simd_double3 eye = gibson_wall_eye(u);
    for (NSUInteger i = 0; i < _items.count; ++i)
    {
        GibsonArrangeItem *item = _items[i];
        const GibsonWallView v = gibson_wall_view_for(eye, gibson_wall_plane([item rect], item.tilt, item.swivel));
        _sceneCams[i].camera.projectionTransform = SCNMatrix4FromMat4(
            gibson_wall_projection(v.slice, GIBSON_CAM_Z_NEAR, GIBSON_CAM_Z_FAR));
        _sceneCams[i].simdOrientation = simd_quaternion(v.basis);
        [_sceneViews[i] setNeedsDisplay:YES];
    }
}

- (void)showPatterns
{
    [self hidePatterns];
    GibsonSCNScene *world = [self cityWorld];
    if (world && !_moments)
        _moments = [GibsonSCNCamera flightMoments];
    for (GibsonArrangeItem *item in _items)
    {
        const NSRect frame = item.screen.frame;
        NSWindow *w = [[NSWindow alloc] initWithContentRect:frame
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        w.releasedWhenClosed = NO;
        w.opaque = world != nil;
        w.backgroundColor = world ? NSColor.blackColor : NSColor.clearColor;
        w.ignoresMouseEvents = YES;
        w.hasShadow = NO;
        w.level = NSFloatingWindowLevel;
        w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorStationary;

        const NSRect bounds = NSMakeRect(0, 0, frame.size.width, frame.size.height);
        NSView *container = [[NSView alloc] initWithFrame:bounds];
        container.wantsLayer = YES;
        if (world)
        {
            SCNView *scn = [[SCNView alloc] initWithFrame:bounds];
            scn.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            scn.scene = world.scene;
            scn.backgroundColor = NSColor.blackColor;
            scn.antialiasingMode = SCNAntialiasingModeNone;
            scn.autoenablesDefaultLighting = NO;
            scn.allowsCameraControl = NO;
            scn.playing = NO;
            scn.rendersContinuously = NO;
            SCNNode *cam = [world makeViewCameraNode];
            cam.camera.motionBlurIntensity = 0.0;   // a still has nothing to blur
            scn.pointOfView = cam;
            [container addSubview:scn];
            [_sceneViews addObject:scn];
            [_sceneCams addObject:cam];
        }
        GibsonArrangePattern *view = [[GibsonArrangePattern alloc] initWithFrame:bounds];
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        view.wantsLayer = YES;
        view.item = item;
        view.items = _items;
        view.overScene = world != nil;
        view.hidden = world && _linesBox.state != NSControlStateValueOn;
        [container addSubview:view];
        [_patternViews addObject:view];

        w.contentView = container;
        [w setFrame:frame display:YES];
        [w orderFront:nil];
        [_patterns addObject:w];
    }
    [self updateSceneCameras];
    _cityRow.hidden = world == nil;
    [self redrawCity];
    /* Keep the editor above the pattern on its own display. */
    _window.level = NSFloatingWindowLevel + 1;
    [_window orderFront:nil];
}

- (void)redrawPatterns
{
    [self updateSceneCameras];
    for (GibsonArrangePattern *view in _patternViews)
        [view setNeedsDisplay:YES];
}

- (void)togglePattern:(NSButton *)sender
{
    if (sender.state == NSControlStateValueOn)
        [self showPatterns];
    else
    {
        [self hidePatterns];
        _window.level = NSNormalWindowLevel;
    }
}

- (void)screensChanged:(NSNotification *)note
{
    if (_window.visible)
        [self reloadItems];
}

- (void)windowWillClose:(NSNotification *)note
{
    [self hidePatterns];
    _patternBox.state = NSControlStateValueOff;
    _window.level = NSNormalWindowLevel;
}

@end
