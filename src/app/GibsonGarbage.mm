#import "GibsonGarbage.h"

#import <AppKit/AppKit.h>

#import "GibsonFonts.h"

#include <algorithm>
#include <cmath>

/* The directory list as it scrolls past in the film, in order (it wraps).
 * Spellings as on screen. GARBAGE appears twice per cycle. */
static NSString *const kNames[] = {
    @"ANNUAL BUDGETS",     @"COMP. OPERATIONS",  @"KINEMATICS",        @"SEA-BOARD LAWS",
    @"TPGC. EXPEND.",      @"WRHSE. LOCATION",   @"COMPANY STATUS",    @"COMPOSITE PLANTS",
    @"EXPLOR. DVLT.",      @"EXPLOR. RESEARCH",  @"GEOLOGIC RESEARCH", @"GARBAGE",
    @"GEOLOGIC BUDGETS",   @"DIVING CONSULTANTS", @"BALLAST REPORTS",  @"MINE DEVELOPMENT",
    @"BLAST FRNC. STATUS", @"NUCLEAR REARSCH",   @"RECRUITMENT",       @"AIRFREIGHT STATUS",
    @"COMP. SYSTEMS",      @"SCIENTIFIC EXPEND", @"URBAN RELOCATION",  @"VIRAL PROTECTION",
    @"COMPANY SPENDING",   @"PERSONNEL",         @"SHIPPING FORCASTS", @"ACCOUNTANTS",
    @"SHIPPING ROUTINGS",  @"TPGC. REPORTS",     @"WRHSE. EXPEND.",    @"GARBAGE",
};
static const int kCycle = sizeof(kNames) / sizeof(kNames[0]);

static const int kRows = 24;          // lines visible on the tower
static const int kGarbageRow = 11;    // where GARBAGE comes to rest (just above the middle, as in the film)
static const CGFloat kLineH = 48;     // texture pixels per line
static const CGFloat kTexW = 1024;
static const CGFloat kNameRight = 600;
static const CGFloat kPanelLeft = 636;   // just right of the ▸ markers (they end at ~623)
static const CGFloat kPanelRight = 912;

/* Timing, measured from the clip at 120 fps. */
static const double kScrollSpeed = 8.0;    // lines per second while scrolling
static const double kSelectDelay = 0.65;   // stop -> GARBAGE turns blue
static const double kBoxFirst = 0.07;      // blue -> first file box
static const double kBoxStep = 0.135;      // between boxes
static const double kBlinkStart = 0.95;    // blue -> first blink
static const double kFadeIn = 1.5;
static const double kFadeOut = 0.5;

/* The list in the pale cyan of the towers' own text (the film's is red); the
 * selection and panel near-white with an electric-blue glow, so they stand
 * out from it. */
static NSColor *gibson_cyan(CGFloat a) { return [NSColor colorWithSRGBRed:0.68 green:0.95 blue:1.0 alpha:a]; }
static NSColor *gibson_cyan_glow(CGFloat a) { return [NSColor colorWithSRGBRed:0.3 green:0.8 blue:1.0 alpha:a]; }
static NSColor *gibson_blue(CGFloat a) { return [NSColor colorWithSRGBRed:0.88 green:0.92 blue:1.0 alpha:a]; }
static NSColor *gibson_blue_glow(CGFloat a) { return [NSColor colorWithSRGBRed:0.25 green:0.4 blue:1.0 alpha:a]; }

static NSFont *gibson_font(CGFloat size, NSFontWeight weight)
{
    return gibson_film_font(GibsonFontList, size, weight);
}

static NSShadow *gibson_glow(NSColor *color, CGFloat blur)
{
    NSShadow *s = [[NSShadow alloc] init];
    s.shadowColor = color;
    s.shadowBlurRadius = blur;
    s.shadowOffset = NSZeroSize;
    return s;
}

static void gibson_text(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color,
                        NSColor *glow, CGFloat x, CGFloat y, int align /* -1 right, 0 centre */)
{
    NSDictionary *attrs = gibson_with_extras(@{
        NSFontAttributeName : gibson_font(size, weight),
        NSForegroundColorAttributeName : color,
        NSShadowAttributeName : gibson_glow(glow, 9),
        NSKernAttributeName : @(size * 0.04),
    }, GibsonFontList);
    const NSSize sz = [text sizeWithAttributes:attrs];
    const CGFloat left = align < 0 ? x - sz.width : x - sz.width / 2;
    [text drawAtPoint:NSMakePoint(left, y - sz.height / 2) withAttributes:attrs];
}

static void gibson_marker(CGFloat x, CGFloat cy, NSColor *color, NSColor *glow)
{
    [NSGraphicsContext saveGraphicsState];
    [gibson_glow(glow, 8) set];
    [color setFill];
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(x, cy - 6)];
    [p lineToPoint:NSMakePoint(x + 11, cy)];
    [p lineToPoint:NSMakePoint(x, cy + 6)];
    [p closePath];
    [p fill];
    [NSGraphicsContext restoreGraphicsState];
}

/* Lines top .. top+rows-1 of the list (wrapping). highlightRow: the row shown
 * in blue with the panel beside it (-1 for none). boxes: file boxes shown
 * (0-4). blinkOff: the blink's dark half, selection and panel hidden. */
static CGImageRef gibson_render(int top, int rows, int highlightRow, int boxes, bool blinkOff)
{
    const size_t w = (size_t)kTexW, h = (size_t)(rows * kLineH);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(nullptr, w, h, 8, 0, cs,
                                             kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx)
        return nullptr;
    CGContextTranslateCTM(ctx, 0, h);
    CGContextScaleCTM(ctx, 1, -1);   // y down, like the rows
    NSGraphicsContext *g = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:YES];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = g;

    NSColor *ink = gibson_cyan(1), *inkGlow = gibson_cyan_glow(0.9);
    NSColor *blue = gibson_blue(1), *blueGlow = gibson_blue_glow(1.0);
    for (int r = 0; r < rows; ++r)
    {
        const int idx = ((top + r) % kCycle + kCycle) % kCycle;
        const CGFloat cy = r * kLineH + kLineH / 2;
        const bool hl = r == highlightRow;
        if (hl && blinkOff)
            continue;
        gibson_text(kNames[idx], 19, NSFontWeightBlack, hl ? blue : ink, hl ? blueGlow : inkGlow,
                    kNameRight, cy, -1);
        gibson_marker(kNameRight + 12, cy, hl ? blue : ink, hl ? blueGlow : inkGlow);
    }

    if (highlightRow >= 0 && !blinkOff)
    {
        const CGFloat mid = (kPanelLeft + kPanelRight) / 2;
        const CGFloat head = (highlightRow - 2) * kLineH;
        gibson_text(@"CONFIDENTIAL", 16, NSFontWeightBlack, blue, blueGlow, mid, head + 14, 0);
        gibson_text(@"FILES", 12.5, NSFontWeightBlack, blue, blueGlow, mid, head + 34, 0);
        const CGFloat note = (highlightRow - 1) * kLineH;
        gibson_text(@"DO NOT DELETE", 9, NSFontWeightHeavy, blue, blueGlow, mid, note + 10, 0);
        gibson_text(@"BEFORE FINAL", 9, NSFontWeightHeavy, blue, blueGlow, mid, note + 23, 0);
        gibson_text(@"BACKUP IS COMPLETED", 9, NSFontWeightHeavy, blue, blueGlow, mid, note + 36, 0);
        for (int b = 0; b < boxes; ++b)
        {
            const CGFloat y = (highlightRow + b) * kLineH;
            const NSRect box = NSMakeRect(kPanelLeft + 14, y + 6, kPanelRight - kPanelLeft - 28, 24);
            [NSGraphicsContext saveGraphicsState];
            [gibson_glow(blueGlow, 8) set];
            [blue setStroke];
            NSBezierPath *frame = [NSBezierPath bezierPathWithRect:box];
            frame.lineWidth = 3;
            [frame stroke];
            [NSGraphicsContext restoreGraphicsState];
            gibson_text([NSString stringWithFormat:@"FILE %d", b + 1], 14, NSFontWeightBlack, blue,
                        blueGlow, NSMidX(box), NSMidY(box), 0);
            gibson_text(@"WAITING FOR BACKUP", 8, NSFontWeightHeavy, blue, blueGlow, mid, y + 41, 0);
        }
    }

    [NSGraphicsContext restoreGraphicsState];
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return img;
}

static NSString *const kDiscardEmpty =
    @"#pragma body\n"
    @"if (_output.color.a < 0.06) discard_fragment();\n";

/* One cycle of the list, tiled vertically and scrolled with the texture
 * transform. Built once. */
static id gibson_strip(void)
{
    static id strip;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGImageRef img = gibson_render(0, kCycle, -1, 0, false);
        strip = (__bridge_transfer id)img;
    });
    return strip;
}

typedef NS_ENUM(int, GibsonColumnPhase) { kScrolling, kStopping, kStopped };

@implementation GibsonGarbageColumn
{
    SCNMaterial *_material;
    GibsonColumnPhase _phase;
    NSTimeInterval _start;
    double _top0;            // top line at _start
    NSTimeInterval _stopStart;
    double _stopFrom, _stopDistance, _stopDuration;
    int _restTop;            // top line once stopped
    NSTimeInterval _restTime;
    NSArray *_frames;        // [0..4] boxes shown, [5] blink off; built off-thread
    int _shown;              // which frame the material shows (-1: the strip)
    NSTimeInterval _fadeStart;
    BOOL _fading;
    NSTimeInterval _revealTime;
}

+ (float)heightForWidth:(float)width
{
    return width * (float)(kRows * kLineH / kTexW);
}

- (instancetype)initWithParent:(SCNNode *)parent
                        center:(simd_float3)center
                        normal:(simd_float3)normal
                         width:(float)width
                          time:(NSTimeInterval)time
{
    self = [super init];
    if (!self)
        return nil;
    SCNPlane *plane = [SCNPlane planeWithWidth:width height:[GibsonGarbageColumn heightForWidth:width]];
    _material = [SCNMaterial material];
    _material.lightingModelName = SCNLightingModelConstant;
    _material.diffuse.contents = gibson_strip();
    _material.diffuse.wrapT = SCNWrapModeRepeat;
    _material.diffuse.intensity = 1.4;   // past 1.0 so the HDR bloom catches it
    _material.blendMode = SCNBlendModeAlpha;
    /* SceneKit draws the tower glass after this plane whatever its rendering
       order, and the glass would land on top. So write depth where there is
       ink (glyphs and their glow) and drop the empty pixels: the tower face
       behind still shows between the letters, but can't cover them. */
    _material.writesToDepthBuffer = YES;
    _material.shaderModifiers = @{ SCNShaderModifierEntryPointFragment : kDiscardEmpty };
    _material.doubleSided = YES;
    plane.materials = @[ _material ];

    _node = [SCNNode nodeWithGeometry:plane];
    _node.name = @"gibson-garbage";
    _node.renderingOrder = 100;   // over the tower glass it sits on
    _node.simdPosition = center;
    _node.simdOrientation = simd_quaternion(std::atan2(normal.x, normal.z), simd_make_float3(0, 1, 0));
    _node.opacity = 0;
    _node.hidden = YES;
    _presence = 1;
    [parent addChildNode:_node];


    _phase = kScrolling;
    _linesPerSecond = kScrollSpeed;
    _start = time;
    _top0 = arc4random_uniform(kCycle);
    _shown = -1;
    [self showTop:_top0];
    return self;
}

- (void)showTop:(double)top
{
    /* As in the film: no smooth glide, each step drops every entry down one
       line. (Slowing down just spaces the steps out.) */
    top = std::floor(top + 1e-6);
    const double cycle = std::fmod(std::fmod(top, kCycle) + kCycle, kCycle);
    const SCNMatrix4 scale = SCNMatrix4MakeScale(1, (CGFloat)kRows / kCycle, 1);
    const SCNMatrix4 shift = SCNMatrix4MakeTranslation(0, cycle / kCycle, 0);
    _material.diffuse.contentsTransform = SCNMatrix4Mult(scale, shift);
}

- (void)showFrame:(int)index
{
    if (index == _shown)
        return;
    if (_shown == 5)
        ++_pulses;   // lit again after a dark half
    _shown = index;
    _material.diffuse.contents = _frames[index];
    _material.diffuse.contentsTransform = SCNMatrix4Identity;
    _material.diffuse.wrapT = SCNWrapModeClamp;
}

- (void)stopAtTime:(NSTimeInterval)time
{
    if (_phase != kScrolling)
        return;
    const double top = _top0 - _linesPerSecond * (time - _start);
    /* The nearest resting place at least 6 lines on: a top line that puts a
       GARBAGE entry on kGarbageRow. Ease out from scrolling speed to it. */
    int rest = (int)std::floor(top - 6);
    for (;; --rest)
    {
        const int idx = ((rest + kGarbageRow) % kCycle + kCycle) % kCycle;
        if ([kNames[idx] isEqualToString:@"GARBAGE"])
            break;
    }
    _phase = kStopping;
    _stopStart = time;
    _stopFrom = top;
    _stopDistance = top - rest;
    _stopDuration = 2.0 * _stopDistance / _linesPerSecond;
    _restTop = rest;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *frames = [NSMutableArray array];
        for (int boxes = 0; boxes <= 4; ++boxes)
            [frames addObject:(__bridge_transfer id)gibson_render(rest, kRows, kGarbageRow, boxes, false)];
        [frames addObject:(__bridge_transfer id)gibson_render(rest, kRows, kGarbageRow, 0, true)];
        @synchronized(self)
        {
            self->_frames = frames;
        }
        /* Development: GIBSON_GARBAGE_DUMP=dir writes the strip and frames. */
        if (const char *dir = getenv("GIBSON_GARBAGE_DUMP"))
        {
            NSMutableArray *all = [NSMutableArray arrayWithObject:gibson_strip()];
            [all addObjectsFromArray:frames];
            for (NSUInteger i = 0; i < all.count; ++i)
            {
                NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:(__bridge CGImageRef)all[i]];
                NSString *path = [NSString stringWithFormat:@"%s/garbage_%lu.png", dir, (unsigned long)i];
                [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
            }
        }
    });
}

+ (SCNNode *)facePlateWithWidth:(float)width height:(float)height
{
    SCNPlane *plate = [SCNPlane planeWithWidth:width height:height];
    SCNMaterial *pm = [SCNMaterial material];
    pm.lightingModelName = SCNLightingModelConstant;
    pm.diffuse.contents = [NSColor colorWithSRGBRed:0.0 green:0.015 blue:0.05 alpha:0.86];
    pm.blendMode = SCNBlendModeAlpha;
    pm.writesToDepthBuffer = YES;   // hides the tower's own text drawn after it
    pm.doubleSided = YES;
    plate.materials = @[ pm ];
    SCNNode *node = [SCNNode nodeWithGeometry:plate];
    node.renderingOrder = 99;
    return node;
}

- (void)revealAtTime:(NSTimeInterval)time
{
    if (_revealed)
        return;
    _revealed = YES;
    _revealTime = time;
    _node.hidden = NO;
}

- (void)fadeOutAtTime:(NSTimeInterval)time
{
    if (_fading)
        return;
    _fading = YES;
    _fadeStart = time;
}

- (BOOL)fileOpen
{
    return _phase == kStopped && _shown >= 0;
}

- (void)updateAtTime:(NSTimeInterval)time
{
    if (_finished)
        return;
    if (_fading)
    {
        const double k = 1.0 - (time - _fadeStart) / kFadeOut;
        _node.opacity = std::max(0.0, std::min(_node.opacity, k));
        if (k <= 0)
        {
            [_node removeFromParentNode];
            _finished = YES;
            return;
        }
    }
    else if (_revealed)
        _node.opacity = std::min(1.0, (time - _revealTime) / kFadeIn) * _presence;

    if (_phase == kScrolling)
    {
        [self showTop:_top0 - _linesPerSecond * (time - _start)];
        return;
    }
    if (_phase == kStopping)
    {
        const double x = std::min(1.0, (time - _stopStart) / _stopDuration);
        [self showTop:_stopFrom - _stopDistance * (1 - (1 - x) * (1 - x))];
        if (x >= 1)
        {
            _phase = kStopped;
            _restTime = time;
        }
        return;
    }

    const double since = time - _restTime - kSelectDelay;
    NSArray *frames;
    @synchronized(self)
    {
        frames = _frames;
    }
    if (since < 0 || frames.count < 6)
        return;
    if (!_frames)
        _frames = frames;

    int boxes = since < kBoxFirst ? 0 : std::min(4, 1 + (int)((since - kBoxFirst) / kBoxStep));
    bool off = false;
    if (since >= kBlinkStart)
    {
        /* A long first beat (dark 0.55 s, lit 0.6 s), then a slow, steady
           blink: lit 0.85 s of every 1.3 s (slower than the film's ~1.3 Hz). */
        const double b = since - kBlinkStart;
        if (b < 1.15)
            off = b < 0.55;
        else
            off = std::fmod(b - 1.15, 1.3) < 0.45;
    }
    [self showFrame:off ? 5 : boxes];
}

@end
