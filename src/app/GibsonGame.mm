#import "GibsonGame.h"

#import "GibsonCity.h"
#import "GibsonFonts.h"
#import "GibsonGarbage.h"
#import "GibsonMusic.h"
#import "GibsonSCNScene.h"
#import "GibsonSFX.h"

#import <SceneKit/SceneKit.h>
#import <simd/simd.h>

#include <algorithm>
#include <cmath>
#include <os/lock.h>
#include <vector>

#include "gibson_settings.h"

// ---------------------------------------------------------------------------
// Key bindings

typedef NS_ENUM(int, GibsonAction) {
    kActUp,
    kActLeft,
    kActDown,
    kActRight,
    kActLeave,
    kActCount
};

static const char *const kActKeys[kActCount] = {
    "key_up", "key_left", "key_down", "key_right", "key_leave_file",
};
static NSString *const kActDefaults[kActCount] = { @"w", @"a", @"s", @"d", @"q" };
static NSString *const kActLabels[kActCount] = {
    @"CLIMB", @"TURN LEFT", @"DIVE", @"TURN RIGHT", @"LEAVE THE FILE",
};
static const char *const kWordKey = "garbage_word";
static NSString *const kWordDefault = @"garbage";
static const char *const kHUDKey = "show_hud";

/* A key's name as stored in config.txt: a lowercase character, or one of
 * left/right/up/down/space. nil for keys that can't be bound. */
static NSString *gibson_key_name(NSEvent *e)
{
    switch (e.keyCode)
    {
    case 123: return @"left";
    case 124: return @"right";
    case 125: return @"down";
    case 126: return @"up";
    case 49: return @"space";
    case 36: case 76: case 53: case 48: case 51: return nil;   // return, enter, esc, tab, delete
    }
    NSString *c = e.charactersIgnoringModifiers.lowercaseString;
    if (c.length != 1)
        return nil;
    const unichar u = [c characterAtIndex:0];
    return (u > 32 && u < 127) ? c : nil;
}

static NSString *gibson_key_label(NSString *name)
{
    if ([name isEqualToString:@"left"]) return @"←";
    if ([name isEqualToString:@"right"]) return @"→";
    if ([name isEqualToString:@"up"]) return @"↑";
    if ([name isEqualToString:@"down"]) return @"↓";
    return name.uppercaseString;
}

// ---------------------------------------------------------------------------
// Steering on the street grid (render thread)

typedef NS_ENUM(int, GibsonTurn) { kTurnNone, kTurnStraight, kTurnLeft, kTurnRight, kTurnBack };

/* Directions: 0 +z, 1 +x, 2 -z, 3 -x. On screen, right of +z is -x. */
static simd_double2 gibson_dir(int d)
{
    static const simd_double2 v[4] = { { 0, 1 }, { 1, 0 }, { 0, -1 }, { -1, 0 } };
    return v[((d % 4) + 4) % 4];
}

static int gibson_apply_turn(int d, GibsonTurn t)
{
    switch (t)
    {
    case kTurnLeft: return (d + 1) % 4;
    case kTurnRight: return (d + 3) % 4;
    case kTurnBack: return (d + 2) % 4;
    default: return d;
    }
}

static bool gibson_inside(simd_double2 p)
{
    return std::fabs(p.x) <= GIBSON_CITY_LIMIT && std::fabs(p.y) <= GIBSON_CITY_LIMIT;
}

static float gibson_wrap(float a)
{
    while (a > (float)M_PI)
        a -= 2.f * (float)M_PI;
    while (a < -(float)M_PI)
        a += 2.f * (float)M_PI;
    return a;
}

static float gibson_smooth(float e0, float e1, float x)
{
    const float t = std::max(0.f, std::min(1.f, (x - e0) / (e1 - e0)));
    return t * t * (3.f - 2.f * t);
}

struct GibsonPose {
    simd_float3 pos;
    float yaw;     // heading: forward = (sin yaw, 0, cos yaw)
    float pitch;
    float bank;
};

static GibsonPose gibson_mix(const GibsonPose &a, const GibsonPose &b, float w)
{
    GibsonPose p;
    p.pos = a.pos + (b.pos - a.pos) * w;
    p.yaw = a.yaw + gibson_wrap(b.yaw - a.yaw) * w;
    p.pitch = a.pitch + (b.pitch - a.pitch) * w;
    p.bank = a.bank + (b.bank - a.bank) * w;
    return p;
}

/* Same framing as GibsonSCNCamera's -aimWithForward:up:position:. */
static void gibson_apply_pose(SCNNode *camera, const GibsonPose &p)
{
    const simd_float3 f = simd_make_float3(std::sin(p.yaw) * std::cos(p.pitch), std::sin(p.pitch),
                                           std::cos(p.yaw) * std::cos(p.pitch));
    simd_float3 up = simd_make_float3(0, 1, 0);
    if (std::fabs(p.bank) > 1e-4f)
        up = simd_normalize(simd_act(simd_quaternion(p.bank, f), up));
    const simd_float3 z = -f;
    simd_float3 x = simd_cross(up, z);
    if (simd_length(x) < 1e-5f)
        x = simd_cross(simd_make_float3(1, 0, 0), z);
    x = simd_normalize(x);
    const simd_float3 y = simd_normalize(simd_cross(z, x));
    camera.simdPosition = p.pos;
    camera.simdOrientation = simd_quaternion(simd_matrix(x, y, z));
}

static const float kCruise = 18.f;           // units per second, about the flythrough's pace
static const double kPlanAhead = 22.0;        // a corner's turn is locked this far before it
static const double kSmoothHalf = 7.0;        // position averages the route over +- this
static const double kLookAhead = 14.0;
static const float kAltMin = 3.f, kAltMax = 80.f, kAltRate = 16.f;
static const float kColumnWidth = 13.f;
static const float kColumnY = 18.f;

typedef NS_ENUM(int, GibsonDrive) {
    kDriveOff,        // the flythrough has the camera (title screen)
    kDriveStarting,   // blending from the flythrough onto the grid
    kDriveFree,       // steering
    kDriveApproach,   // garbage: flying in, slowing and turning to face the tower
    kDrivePush,       // garbage: easing in, squaring up
    kDriveHold,       // garbage: squared up to the file
    kDriveLeaving,    // garbage: back onto the street
};

typedef NS_ENUM(int, GibsonMode) { kModeTitle, kModeOptions, kModePlaying };

// ---------------------------------------------------------------------------
// Views

@interface GibsonGameWindow : NSWindow
@end
@implementation GibsonGameWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

@class GibsonGameController;

@interface GibsonGameController ()
- (void)keyDown:(NSEvent *)e;
- (void)keyUp:(NSEvent *)e;
@end

@interface GibsonGameContentView : NSView
@property (nonatomic, weak) GibsonGameController *controller;
@end
@implementation GibsonGameContentView
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)e { [_controller keyDown:e]; }
- (void)keyUp:(NSEvent *)e { [_controller keyUp:e]; }
@end

/* Renders at render_scale pixels per point, like the screensaver. */
@interface GibsonGameSCNView : SCNView
@end
@implementation GibsonGameSCNView
- (void)applyScale
{
    const CGFloat backing = self.window.backingScaleFactor > 0 ? self.window.backingScaleFactor : 2.0;
    const CGFloat scale = std::min(backing, std::max(0.5, (double)gibson_render_scale()));
    if (self.layer && self.layer.contentsScale != scale)
        self.layer.contentsScale = scale;
}
- (void)layout { [super layout]; [self applyScale]; }
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [self applyScale]; }
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; [self applyScale]; }
- (void)setFrameSize:(NSSize)s { [super setFrameSize:s]; [self applyScale]; }
@end

static NSColor *gibson_cyan(CGFloat a) { return [NSColor colorWithSRGBRed:0.5 green:0.95 blue:1.0 alpha:a]; }
static NSFont *gibson_ui_font(CGFloat size, NSFontWeight w)
{
    return gibson_film_font(GibsonFontUI, size, w);
}

/* The title and options menus: a small dark panel, cyan type, a solid bar
 * on the selected row. A title heads the panel only when set. */
@interface GibsonMenuView : NSView
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray<NSString *> *items;
@property (nonatomic, copy) NSArray<NSString *> *values;   // right column (options), or nil
@property (nonatomic) NSInteger selected;
@property (nonatomic) CGFloat panelWidth;
- (NSSize)fittingPanelSize;
@end

@implementation GibsonMenuView
static const CGFloat kRowH = 30, kPad = 14, kTitleH = 42;

- (BOOL)isFlipped { return YES; }

- (NSSize)fittingPanelSize
{
    return NSMakeSize(_panelWidth, [self rowsTop] + _items.count * kRowH + kPad - 4);
}

- (CGFloat)rowsTop
{
    return kPad + (_title.length ? kTitleH : 0);
}

- (void)drawRect:(NSRect)dirty
{
    const NSRect b = NSInsetRect(self.bounds, 0.5, 0.5);
    NSBezierPath *panel = [NSBezierPath bezierPathWithRoundedRect:b xRadius:5 yRadius:5];
    [[NSColor colorWithWhite:0 alpha:0.62] setFill];
    [panel fill];
    [gibson_cyan(0.45) setStroke];
    panel.lineWidth = 1;
    [panel stroke];

    NSShadow *glow = [[NSShadow alloc] init];
    glow.shadowColor = gibson_cyan(0.85);
    glow.shadowBlurRadius = 8;
    [_title drawAtPoint:NSMakePoint(kPad + 4, kPad)
         withAttributes:gibson_with_extras(@{
             NSFontAttributeName : gibson_ui_font(19, NSFontWeightBlack),
             NSForegroundColorAttributeName : gibson_cyan(1),
             NSShadowAttributeName : glow,
             NSKernAttributeName : @1.0,
         }, GibsonFontUI)];

    CGFloat y = [self rowsTop];
    for (NSUInteger i = 0; i < _items.count; ++i, y += kRowH)
    {
        const BOOL sel = (NSInteger)i == _selected;
        const NSRect row = NSMakeRect(kPad - 8, y, b.size.width - 2 * kPad + 16, kRowH - 4);
        if (sel)
        {
            [gibson_cyan(0.9) setFill];
            [[NSBezierPath bezierPathWithRoundedRect:row xRadius:2 yRadius:2] fill];
        }
        NSColor *ink = sel ? [NSColor colorWithWhite:0.02 alpha:1] : gibson_cyan(0.72);
        NSDictionary *attrs = gibson_with_extras(@{
            NSFontAttributeName : gibson_ui_font(12.5, sel ? NSFontWeightHeavy : NSFontWeightSemibold),
            NSForegroundColorAttributeName : ink,
            NSKernAttributeName : @0.8,
        }, GibsonFontUI);
        NSString *label = [(sel ? @"▸ " : @"   ") stringByAppendingString:_items[i]];
        const NSSize sz = [label sizeWithAttributes:attrs];
        [label drawAtPoint:NSMakePoint(kPad + 4, NSMidY(row) - sz.height / 2) withAttributes:attrs];
        if (i < _values.count && _values[i].length)
        {
            NSString *v = _values[i];
            const NSSize vs = [v sizeWithAttributes:attrs];
            [v drawAtPoint:NSMakePoint(NSMaxX(row) - 10 - vs.width, NSMidY(row) - vs.height / 2)
                withAttributes:attrs];
        }
    }
}
@end

/* A tiny, faint readout in the corner while playing, easy to miss for
 * anyone watching. Off with show_hud = no (or in Options). */
@interface GibsonHUDView : NSView
@property (nonatomic, copy) NSString *text;
@end
@implementation GibsonHUDView
- (void)drawRect:(NSRect)dirty
{
    NSDictionary *a = gibson_with_extras(@{
        NSFontAttributeName : gibson_ui_font(7, NSFontWeightMedium),
        NSForegroundColorAttributeName : gibson_cyan(0.32),
        NSKernAttributeName : @0.5,
    }, GibsonFontUI);
    const NSSize sz = [_text sizeWithAttributes:a];
    [_text drawAtPoint:NSMakePoint(self.bounds.size.width - sz.width, 0) withAttributes:a];
}
@end

// ---------------------------------------------------------------------------
// Controller

@interface GibsonGameController () <GibsonCameraDriver>
@end

@implementation GibsonGameController
{
    NSURL *_media;
    GibsonSCNScene *_world;
    GibsonGameWindow *_window;
    GibsonGameContentView *_content;
    GibsonGameSCNView *_scnView;
    GibsonMenuView *_menu;
    GibsonHUDView *_hud;
    NSTimer *_hudTimer;

    // main thread
    GibsonMode _mode;
    NSInteger _titleSel, _optionsSel;
    NSInteger _capturing;           // options row waiting for a key, or -1
    NSMutableString *_wordDraft;    // typing a new garbage word
    NSString *_bindings[kActCount];
    NSString *_word;
    BOOL _showHUD;
    NSMutableString *_typed;        // letters of the garbage word typed so far
    NSMutableArray<NSString *> *_swallowed;   // ...and the keys they were
    NSTimeInterval _typedAt;
    BOOL _exiting;

    // shared with the render thread, under _lock
    os_unfair_lock _lock;
    GibsonTurn _pendingTurn;
    BOOL _climb, _dive;
    BOOL _startRequest, _garbageRequest, _leaveRequest;
    BOOL _inFile;
    float _hudAlt;

    // render thread only
    GibsonDrive _drive;
    std::vector<simd_double2> _nodes;
    std::vector<double> _cum;
    std::vector<int> _segDir;
    double _s;
    float _speed;
    float _yaw, _yawRate, _bank, _pitch, _alt, _targetAlt;
    NSTimeInterval _stateStart;
    GibsonPose _fromPose, _endPose, _panPose;
    SCNNode *_hostTower;   // the tower carrying the file, dimmed while it's shown
    SCNNode *_hostDecor;   // dark plates on its faces, holding the other lists
    NSMutableArray<GibsonGarbageColumn *> *_decoys;
    // last event counts seen, for the sound effects
    NSUInteger _mainPulses;
    BOOL _mainOpen;
    float _hostDim;      // host tower's dark tint, 0-1
    float _listFade;     // its directory listings, 0-1
    float _approachX;    // progress through the approach, 0-1
    double _approachS0, _approachD, _approachT, _approachC;
    BOOL _columnStopped;
    GibsonGarbageColumn *_column;
}

- (instancetype)initWithMediaURL:(NSURL *)media
{
    self = [super init];
    if (!self)
        return nil;
    _media = media;
    gibson_fonts_set_media(media);
    _lock = OS_UNFAIR_LOCK_INIT;
    _capturing = -1;
    _typed = [NSMutableString string];
    _swallowed = [NSMutableArray array];
    [self loadBindings];
    return self;
}

// ---- bindings -------------------------------------------------------------

- (void)loadBindings
{
    for (int i = 0; i < kActCount; ++i)
    {
        NSString *v = [NSString stringWithUTF8String:gibson_settings_raw(kActKeys[i])].lowercaseString;
        _bindings[i] = v.length ? v : kActDefaults[i];
    }
    NSString *w = [NSString stringWithUTF8String:gibson_settings_raw(kWordKey)].lowercaseString;
    _word = w.length >= 2 ? w : kWordDefault;
    NSString *h = [NSString stringWithUTF8String:gibson_settings_raw(kHUDKey)].lowercaseString;
    _showHUD = !([h isEqualToString:@"no"] || [h isEqualToString:@"off"] || [h isEqualToString:@"false"] ||
                 [h isEqualToString:@"0"]);
}

- (void)saveBinding:(int)i
{
    gibson_settings_set(kActKeys[i], _bindings[i].UTF8String);
}

- (void)reloadSettings
{
    gibson_settings_reload([NSBundle mainBundle].resourcePath.fileSystemRepresentation);
}

// ---- window ---------------------------------------------------------------

- (void)start
{
    NSScreen *screen = NSScreen.screens.firstObject;   // the primary display
    _window = [[GibsonGameWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 600)
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    _window.releasedWhenClosed = NO;
    _window.level = NSMainMenuWindowLevel + 1;
    _window.backgroundColor = NSColor.blackColor;
    _window.opaque = YES;
    _window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    [_window setFrame:screen.frame display:NO];

    _content = [[GibsonGameContentView alloc] initWithFrame:NSMakeRect(0, 0, screen.frame.size.width,
                                                                       screen.frame.size.height)];
    _content.controller = self;
    _window.contentView = _content;

    _scnView = [[GibsonGameSCNView alloc] initWithFrame:_content.bounds];
    _scnView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [GibsonSCNScene configureView:_scnView preview:NO mediaURL:_media];
    _world = [GibsonSCNScene sharedWorldForPreview:NO mediaURL:_media];
    [_world resetClock];
    _world.cameraDriver = self;
    [_content addSubview:_scnView];

    _menu = [[GibsonMenuView alloc] initWithFrame:NSZeroRect];
    _menu.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [_content addSubview:_menu];
    _hud = [[GibsonHUDView alloc] initWithFrame:NSZeroRect];
    _hud.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    _hud.hidden = YES;
    [_content addSubview:_hud];

    _mode = kModeTitle;
    [self refreshMenu];

    [NSApp setPresentationOptions:NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar];
    [_window makeKeyAndOrderFront:nil];
    [_window makeFirstResponder:_content];
    [NSApp activateIgnoringOtherApps:YES];
    [NSCursor hide];
    [[GibsonMusic shared] viewDidStart];
    [[GibsonSFX shared] start];

    __weak GibsonGameController *weakSelf = self;
    [self scheduleDemo];
    _hudTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
        [weakSelf refreshHUD];
    }];
}

/* Development: GIBSON_GAME_DEMO=1 plays itself (start, a left turn, the
 * garbage file, leave, exit) so the game can be checked without a player. */
- (void)scheduleDemo
{
    if (!getenv("GIBSON_GAME_DEMO"))
        return;
    __weak GibsonGameController *weakSelf = self;
    auto at = ^(double t, void (^block)(GibsonGameController *)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            GibsonGameController *s = weakSelf;
            if (s && !s->_exiting)
                block(s);
        });
    };
    at(3, ^(GibsonGameController *s) { s->_titleSel = 0; [s activateTitle]; });
    at(5, ^(GibsonGameController *s) { [s control:s->_bindings[kActLeft] down:YES]; });
    at(9, ^(GibsonGameController *s) { [s control:s->_bindings[kActUp] down:YES]; });
    at(10, ^(GibsonGameController *s) { [s control:s->_bindings[kActUp] down:NO]; });
    at(13, ^(GibsonGameController *s) {
        os_unfair_lock_lock(&s->_lock);
        s->_garbageRequest = YES;
        os_unfair_lock_unlock(&s->_lock);
    });
    at(38, ^(GibsonGameController *s) {
        os_unfair_lock_lock(&s->_lock);
        s->_leaveRequest = YES;
        os_unfair_lock_unlock(&s->_lock);
    });
    at(43, ^(GibsonGameController *s) { [s exitGame]; });
}

- (void)exitGame
{
    if (_exiting)
        return;
    _exiting = YES;
    [_hudTimer invalidate];
    _world.cameraDriver = nil;
    [_column.node removeFromParentNode];
    _column = nil;
    _hostTower.opacity = 1;
    _hostTower = nil;
    [_hostDecor removeFromParentNode];
    _hostDecor = nil;
    _decoys = nil;
    [[GibsonMusic shared] viewDidStop];
    [[GibsonSFX shared] stop];
    [NSCursor unhide];
    [NSApp setPresentationOptions:NSApplicationPresentationDefault];
    _scnView.playing = NO;
    [_window orderOut:nil];
    [_window close];
    if (_onExit)
        _onExit();
}

// ---- menus ----------------------------------------------------------------

- (NSArray<NSString *> *)optionItems
{
    NSMutableArray *items = [NSMutableArray array];
    for (int i = 0; i < kActCount; ++i)
        [items addObject:kActLabels[i]];
    [items addObjectsFromArray:@[ @"GARBAGE WORD", @"SHOW HUD", @"RESET TO DEFAULTS", @"BACK" ]];
    return items;
}

- (void)refreshMenu
{
    if (_mode == kModePlaying)
    {
        _menu.hidden = YES;
        return;
    }
    _menu.hidden = NO;
    if (_mode == kModeTitle)
    {
        _menu.title = nil;
        _menu.items = @[ @"START GAME", @"OPTIONS", @"EXIT" ];
        _menu.values = nil;
        _menu.selected = _titleSel;
        _menu.panelWidth = 240;
    }
    else
    {
        NSMutableArray *values = [NSMutableArray array];
        for (int i = 0; i < kActCount; ++i)
            [values addObject:_capturing == i ? @"PRESS A KEY" : gibson_key_label(_bindings[i])];
        [values addObject:_capturing == kActCount
                              ? [NSString stringWithFormat:@"%@_", _wordDraft.uppercaseString]
                              : _word.uppercaseString];
        [values addObjectsFromArray:@[ _showHUD ? @"ON" : @"OFF", @"", @"" ]];
        _menu.title = @"OPTIONS";
        _menu.items = [self optionItems];
        _menu.values = values;
        _menu.selected = _optionsSel;
        _menu.panelWidth = 430;
    }
    const NSSize size = [_menu fittingPanelSize];
    const NSRect b = _content.bounds;
    _menu.frame = NSMakeRect(NSMaxX(b) - size.width - 36, 36, size.width, size.height);
    [_menu setNeedsDisplay:YES];
}

- (void)refreshHUD
{
    if (_mode != kModePlaying || !_showHUD)
    {
        _hud.hidden = YES;
        return;
    }
    GibsonTurn turn;
    BOOL inFile;
    float alt;
    os_unfair_lock_lock(&_lock);
    turn = _pendingTurn;
    inFile = _inFile;
    alt = _hudAlt;
    os_unfair_lock_unlock(&_lock);

    NSString *text;
    if (inFile)
        text = [NSString stringWithFormat:@"%@ LEAVE", gibson_key_label(_bindings[kActLeave])];
    else
    {
        NSString *next = turn == kTurnLeft    ? @"◂"
                         : turn == kTurnRight ? @"▸"
                         : turn == kTurnBack  ? @"▾"
                                              : @"▴";
        text = [NSString stringWithFormat:@"%@  %.0f", next, alt];
    }
    if (![text isEqualToString:_hud.text])
    {
        _hud.text = text;
        [_hud setNeedsDisplay:YES];
    }
    const NSRect b = _content.bounds;
    _hud.frame = NSMakeRect(NSMaxX(b) - 140, 14, 120, 12);
    _hud.hidden = NO;
}

- (void)activateTitle
{
    switch (_titleSel)
    {
    case 0:
        _mode = kModePlaying;
        os_unfair_lock_lock(&_lock);
        _startRequest = YES;
        _pendingTurn = kTurnNone;
        os_unfair_lock_unlock(&_lock);
        [self refreshMenu];
        [self refreshHUD];
        break;
    case 1:
        _mode = kModeOptions;
        _optionsSel = 0;
        [self refreshMenu];
        break;
    default:
        [self exitGame];
    }
}

- (void)activateOption
{
    if (_optionsSel < kActCount)
        _capturing = _optionsSel;
    else if (_optionsSel == kActCount)
    {
        _capturing = kActCount;
        _wordDraft = [NSMutableString string];
    }
    else if (_optionsSel == kActCount + 1)
    {
        _showHUD = !_showHUD;
        gibson_settings_set(kHUDKey, _showHUD ? "yes" : "no");
        [self reloadSettings];
    }
    else if (_optionsSel == kActCount + 2)
    {
        for (int i = 0; i < kActCount; ++i)
        {
            _bindings[i] = kActDefaults[i];
            [self saveBinding:i];
        }
        _word = kWordDefault;
        gibson_settings_set(kWordKey, _word.UTF8String);
        _showHUD = YES;
        gibson_settings_set(kHUDKey, "yes");
        [self reloadSettings];
    }
    else
    {
        _mode = kModeTitle;
        _titleSel = 1;
    }
    [self refreshMenu];
}

- (void)captureKey:(NSEvent *)e
{
    if (_capturing == kActCount)
    {
        if (e.keyCode == 36 || e.keyCode == 76)
        {
            if (_wordDraft.length >= 2)
            {
                _word = [_wordDraft copy];
                gibson_settings_set(kWordKey, _word.UTF8String);
                [self reloadSettings];
            }
            _capturing = -1;
        }
        else if (e.keyCode == 51)
        {
            if (_wordDraft.length)
                [_wordDraft deleteCharactersInRange:NSMakeRange(_wordDraft.length - 1, 1)];
        }
        else
        {
            NSString *c = e.charactersIgnoringModifiers.lowercaseString;
            if (c.length == 1 && [[NSCharacterSet lowercaseLetterCharacterSet] characterIsMember:[c characterAtIndex:0]] &&
                _wordDraft.length < 16)
                [_wordDraft appendString:c];
        }
        [self refreshMenu];
        return;
    }

    NSString *name = gibson_key_name(e);
    if (!name)
        return;
    const int i = (int)_capturing;
    // A key does one thing: swap with whatever had it.
    for (int j = 0; j < kActCount; ++j)
        if (j != i && [_bindings[j] isEqualToString:name])
        {
            _bindings[j] = _bindings[i];
            [self saveBinding:j];
        }
    _bindings[i] = name;
    [self saveBinding:i];
    [self reloadSettings];
    _capturing = -1;
    [self refreshMenu];
}

// ---- input ----------------------------------------------------------------

- (void)keyDown:(NSEvent *)e
{
    const unsigned short code = e.keyCode;
    if (code == 53)   // Escape
    {
        if (_mode == kModeOptions && _capturing >= 0)
        {
            _capturing = -1;
            [self refreshMenu];
        }
        else
            [self exitGame];
        return;
    }

    if (_mode == kModeTitle || (_mode == kModeOptions && _capturing < 0))
    {
        NSString *c = e.charactersIgnoringModifiers.lowercaseString;
        const BOOL up = code == 126 || [c isEqualToString:@"w"];
        const BOOL down = code == 125 || [c isEqualToString:@"s"];
        const BOOL pick = code == 36 || code == 76 || code == 49;
        NSInteger *sel = _mode == kModeTitle ? &_titleSel : &_optionsSel;
        const NSInteger count = _mode == kModeTitle ? 3 : (NSInteger)[self optionItems].count;
        if (up)
            *sel = (*sel + count - 1) % count;
        else if (down)
            *sel = (*sel + 1) % count;
        else if (pick)
        {
            if (_mode == kModeTitle)
                [self activateTitle];
            else
                [self activateOption];
            return;
        }
        [self refreshMenu];
        return;
    }
    if (_mode == kModeOptions)
    {
        [self captureKey:e];
        return;
    }

    // Playing.
    if (e.isARepeat)
        return;
    NSString *name = gibson_key_name(e);
    if (!name)
        return;
    BOOL inFile;
    os_unfair_lock_lock(&_lock);
    inFile = _inFile;
    os_unfair_lock_unlock(&_lock);
    if (inFile)
    {
        if ([name isEqualToString:_bindings[kActLeave]])
        {
            os_unfair_lock_lock(&_lock);
            _leaveRequest = YES;
            os_unfair_lock_unlock(&_lock);
        }
        return;
    }

    /* The garbage word: letters that continue it are held back from the
       controls (it has an "a" and an "s" in it). If the word breaks off,
       the held keys are replayed as controls. */
    const NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (_typed.length && now - _typedAt > 1.5)
        [self replaySwallowed];
    if (name.length == 1 && _typed.length < _word.length &&
        [[_word substringWithRange:NSMakeRange(_typed.length, 1)] isEqualToString:name])
    {
        [_typed appendString:name];
        [_swallowed addObject:name];
        _typedAt = now;
        if (_typed.length == _word.length)
        {
            [_typed setString:@""];
            [_swallowed removeAllObjects];
            os_unfair_lock_lock(&_lock);
            _garbageRequest = YES;
            _pendingTurn = kTurnNone;
            os_unfair_lock_unlock(&_lock);
        }
        return;
    }
    if (_typed.length)
    {
        [self replaySwallowed];
        if (name.length == 1 && [[_word substringToIndex:1] isEqualToString:name])
        {
            [_typed appendString:name];
            [_swallowed addObject:name];
            _typedAt = now;
            return;
        }
    }
    [self control:name down:YES];
}

- (void)replaySwallowed
{
    NSArray *keys = [_swallowed copy];
    [_typed setString:@""];
    [_swallowed removeAllObjects];
    for (NSString *k in keys)
    {
        [self control:k down:YES];
        [self control:k down:NO];
    }
}

- (void)keyUp:(NSEvent *)e
{
    if (_mode != kModePlaying)
        return;
    NSString *name = gibson_key_name(e);
    if (name)
        [self control:name down:NO];
}

- (void)control:(NSString *)name down:(BOOL)down
{
    os_unfair_lock_lock(&_lock);
    if ([name isEqualToString:_bindings[kActUp]])
        _climb = down;
    else if ([name isEqualToString:_bindings[kActDown]])
        _dive = down;
    else if (down)
    {
        if ([name isEqualToString:_bindings[kActLeft]])
            _pendingTurn = kTurnLeft;
        else if ([name isEqualToString:_bindings[kActRight]])
            _pendingTurn = kTurnRight;
    }
    os_unfair_lock_unlock(&_lock);
}

// ---- camera driver (render thread) ----------------------------------------

- (simd_double2)routePoint:(double)s
{
    const size_t n = _nodes.size();
    if (s <= _cum[0])
        return _nodes[0] + gibson_dir(_segDir[0]) * (s - _cum[0]);
    if (s >= _cum[n - 1])
        return _nodes[n - 1] + gibson_dir(_segDir[n - 2]) * (s - _cum[n - 1]);
    size_t i = 0;
    while (i + 1 < n && _cum[i + 1] < s)
        ++i;
    return _nodes[i] + gibson_dir(_segDir[i]) * (s - _cum[i]);
}

- (void)appendNode:(int)dir
{
    _nodes.push_back(_nodes.back() + gibson_dir(dir) * GIBSON_CITY_BLOCK);
    _cum.push_back(_cum.back() + GIBSON_CITY_BLOCK);
    _segDir.push_back(dir);
}

/* Plan corners until the route reaches `horizon` past the camera. A corner's
 * direction comes from the turn the player last asked for (consumed), else
 * straight on; at the city's edge it turns back inwards. */
- (void)extendRoute:(double)horizon forceStraight:(BOOL)straight
{
    while (_cum.back() < _s + horizon)
    {
        const int d = _segDir.back();
        GibsonTurn turn = kTurnStraight;
        if (!straight)
        {
            os_unfair_lock_lock(&_lock);
            if (_pendingTurn != kTurnNone)
            {
                turn = _pendingTurn;
                _pendingTurn = kTurnNone;
            }
            os_unfair_lock_unlock(&_lock);
        }
        int nd = gibson_apply_turn(d, turn);
        if (!gibson_inside(_nodes.back() + gibson_dir(nd) * GIBSON_CITY_BLOCK))
        {
            const GibsonTurn order[] = { kTurnStraight, kTurnLeft, kTurnRight, kTurnBack };
            double best = 1e9;
            for (GibsonTurn t : order)
            {
                const int cand = gibson_apply_turn(d, t);
                const simd_double2 p = _nodes.back() + gibson_dir(cand) * GIBSON_CITY_BLOCK;
                if (gibson_inside(p) && simd_length(p) < best)
                {
                    best = simd_length(p);
                    nd = cand;
                }
            }
        }
        [self appendNode:nd];
    }
    // Forget corners well behind.
    while (_nodes.size() > 3 && _cum[1] < _s - 40)
    {
        _nodes.erase(_nodes.begin());
        _cum.erase(_cum.begin());
        _segDir.erase(_segDir.begin());
    }
}

/* Put the flight on the nearest street, heading the way the camera faces. */
- (void)joinGridFrom:(simd_float3)pos forward:(simd_float3)f
{
    int dir;
    simd_double2 node;
    double along;
    if (std::fabs(f.x) > std::fabs(f.z))
    {
        dir = f.x > 0 ? 1 : 3;
        const double z = std::round((pos.z - 15.0) / GIBSON_CITY_BLOCK) * GIBSON_CITY_BLOCK + 15.0;
        const double x = dir == 1 ? std::floor(pos.x / GIBSON_CITY_BLOCK) * GIBSON_CITY_BLOCK
                                  : std::ceil(pos.x / GIBSON_CITY_BLOCK) * GIBSON_CITY_BLOCK;
        node = simd_make_double2(x, z);
        along = std::fabs(pos.x - x);
    }
    else
    {
        dir = f.z > 0 ? 0 : 2;
        const double x = std::round(pos.x / GIBSON_CITY_BLOCK) * GIBSON_CITY_BLOCK;
        const double z0 = (pos.z - 15.0) / GIBSON_CITY_BLOCK;
        const double z = (dir == 0 ? std::floor(z0) : std::ceil(z0)) * GIBSON_CITY_BLOCK + 15.0;
        node = simd_make_double2(x, z);
        along = std::fabs(pos.z - z);
    }
    _nodes = { node - gibson_dir(dir) * GIBSON_CITY_BLOCK, node };
    _cum = { 0.0, GIBSON_CITY_BLOCK };
    _segDir = { dir };
    _s = GIBSON_CITY_BLOCK + along;
    [self extendRoute:kPlanAhead forceStraight:YES];
}

/* Where the street flight puts the camera this frame (also tracked during
 * the garbage sequence, so leaving it blends back smoothly). */
- (GibsonPose)routePoseWithDelta:(float)dt climb:(float)climb
{
    simd_double2 avg = simd_make_double2(0, 0);
    const int k = 4;
    for (int i = -k; i <= k; ++i)
        avg += [self routePoint:_s + kSmoothHalf * i / k];
    avg /= (2 * k + 1);
    const simd_double2 look = [self routePoint:_s + kLookAhead];
    const simd_double2 to = look - avg;
    if (simd_length(to) > 1e-3)
    {
        const float target = (float)std::atan2(to.x, to.y);
        const float step = gibson_wrap(target - _yaw) * (1.f - std::exp(-dt / 0.2f));
        _yaw = gibson_wrap(_yaw + step);
        const float rate = dt > 0 ? step / dt : 0.f;
        _yawRate += (rate - _yawRate) * (1.f - std::exp(-dt / 0.28f));
    }
    const float maxBank = gibson_bank_max_degrees() * (float)M_PI / 180.f;
    const float bankTarget = std::max(-maxBank, std::min(maxBank, -_yawRate * gibson_bank_strength()));
    _bank += (bankTarget - _bank) * (1.f - std::exp(-dt / std::max(0.12f, gibson_bank_smoothing())));

    _targetAlt = std::max(kAltMin, std::min(kAltMax, _targetAlt + climb * kAltRate * dt));
    const float prevAlt = _alt;
    _alt += (_targetAlt - _alt) * (1.f - std::exp(-dt / 0.45f));
    const float vy = dt > 0 ? (_alt - prevAlt) / dt : 0.f;
    // Look down over the rooftops, and a little into climbs and dives.
    const float pitchTarget = -0.55f * gibson_smooth(30.f, 80.f, _alt) + std::max(-0.2f, std::min(0.2f, vy * 0.015f));
    _pitch += (pitchTarget - _pitch) * (1.f - std::exp(-dt / 0.35f));

    GibsonPose p;
    p.pos = simd_make_float3((float)avg.x, _alt, (float)avg.y);
    p.yaw = _yaw;
    p.pitch = _pitch;
    p.bank = _bank;
    return p;
}

static GibsonPose gibson_pose_of(SCNNode *camera)
{
    const simd_float3 f = simd_act(camera.simdOrientation, simd_make_float3(0, 0, -1));
    GibsonPose p;
    p.pos = camera.simdPosition;
    p.yaw = std::atan2(f.x, f.z);
    p.pitch = std::asin(std::max(-1.f, std::min(1.f, f.y)));
    p.bank = 0;
    return p;
}

/* The garbage file:
 *   approach  the file appears on a tower three or four blocks down the street
 *             (fading in while it is still small and edge-on), and the tower
 *             darkens. The camera flies on towards it, slowing, drifting to
 *             the far side of the street and rising to the file's height, and
 *             in the last stretch turns to face it.
 *   push      ease in until it fills the frame, squared up.
 *   hold      until the player leaves (the file stops scrolling and opens). */
static const double kPushTime = 2.4;
static const float kHostDim = 0.7f;   // how much the host tower's own glow drops

/* The whole host tower turns into directory listings, as if it were
 * filtering down to matches: every face goes dark and carries scrolling
 * lists (one above and one below the real file on its face, two on each of
 * the others), each at its own pace. Only the real one ever stops. */
- (void)decorateTowerAt:(simd_double2)centre mainNormal:(simd_float3)mainNormal time:(NSTimeInterval)time
{
    _hostDecor = [SCNNode node];
    _hostDecor.name = @"gibson-garbage-tower";
    _hostDecor.opacity = 0;
    [_world.worldRoot addChildNode:_hostDecor];
    _decoys = [NSMutableArray array];

    const float faceW = 2.f * GIBSON_CITY_TOWER_HALF;
    const simd_float3 c = simd_make_float3((float)centre.x, 0, (float)centre.y);
    const simd_float3 normals[4] = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 } };
    for (const simd_float3 &n : normals)
    {
        const float turn = std::atan2(n.x, n.z);
        const simd_float3 face = c + n * GIBSON_CITY_TOWER_HALF;
        SCNNode *plate = [GibsonGarbageColumn facePlateWithWidth:faceW + 0.1f height:GIBSON_CITY_TOWER_TOP];
        plate.simdPosition = face + n * 0.08f + simd_make_float3(0, GIBSON_CITY_TOWER_TOP / 2, 0);
        plate.simdOrientation = simd_quaternion(turn, simd_make_float3(0, 1, 0));
        [_hostDecor addChildNode:plate];

        /* (width, height of centre, sideways offset) for each list here. */
        const bool main = simd_dot(n, mainNormal) > 0.5f;
        const simd_float3 mainSlots[] = { { 8.5f, 34.5f, -1.5f }, { 6.5f, 5.0f, 2.5f } };
        const simd_float3 otherSlots[] = { { 10.f, 30.f, -1.f }, { 8.f, 12.f, 1.5f } };
        const simd_float3 *slots = main ? mainSlots : otherSlots;
        const simd_float3 across = simd_make_float3(n.z, 0, -n.x);   // the face's left-to-right
        for (int i = 0; i < 2; ++i)
        {
            const simd_float3 s = slots[i];
            const simd_float3 at = face + n * 0.15f + across * s.z + simd_make_float3(0, s.y, 0);
            GibsonGarbageColumn *list = [[GibsonGarbageColumn alloc] initWithParent:_hostDecor
                                                                             center:at
                                                                             normal:n
                                                                              width:s.x
                                                                               time:time];
            list.linesPerSecond = 5.0 + arc4random_uniform(60) / 10.0;
            [list revealAtTime:time];
            [_decoys addObject:list];
        }
    }
}

- (void)beginGarbageAtTime:(NSTimeInterval)time
{
    [self extendRoute:200 forceStraight:YES];
    size_t seg = 0;
    while (seg + 1 < _nodes.size() && _cum[seg] < _s + 70)
        ++seg;
    if (seg + 1 >= _nodes.size())
        return;
    const int d = _segDir[seg];
    const simd_double2 mid = _nodes[seg] + gibson_dir(d) * (GIBSON_CITY_BLOCK / 2);
    const int sideDir = arc4random_uniform(2) ? gibson_apply_turn(d, kTurnLeft) : gibson_apply_turn(d, kTurnRight);
    const simd_double2 side = gibson_dir(sideDir);
    const simd_double2 centre = mid + side * (GIBSON_CITY_BLOCK / 2);
    const simd_double2 face = mid + side * (GIBSON_CITY_BLOCK / 2 - GIBSON_CITY_TOWER_HALF);
    const simd_float3 normal = simd_make_float3((float)-side.x, 0, (float)-side.y);
    const simd_float3 faceP = simd_make_float3((float)face.x, kColumnY, (float)face.y);

    /* Back off until the column fills ~85% of the view's height. */
    const float h = [GibsonGarbageColumn heightForWidth:kColumnWidth];
    const float fov = 72.f * (float)M_PI / 180.f;
    const float dist = h / (0.85f * 2.f * std::tan(fov / 2.f));

    _column = [[GibsonGarbageColumn alloc] initWithParent:_world.worldRoot
                                                   center:faceP + normal * 0.15f
                                                   normal:normal
                                                    width:kColumnWidth
                                                     time:time];
    _mainPulses = 0;
    _mainOpen = NO;
    [_column revealAtTime:time];
    [self decorateTowerAt:centre mainNormal:normal time:time];
    _hostTower = [_world towerNodeAtX:(float)centre.x z:(float)centre.y];
    _columnStopped = NO;
    _endPose.pos = faceP + normal * dist;
    _endPose.yaw = std::atan2((float)side.x, (float)side.y);
    _endPose.pitch = 0;
    _endPose.bank = 0;
    /* The fly-in ends a little further back (still clear of the opposite
       tower, 15.4 from this face), then eases in. */
    _panPose = _endPose;
    _panPose.pos = faceP + normal * std::min(dist * 1.3f, 12.5f);

    _approachS0 = _s;
    _approachD = (_cum[seg] + GIBSON_CITY_BLOCK / 2) - _s;
    const double v0 = std::max(4.0, (double)_speed);
    _approachT = std::max(7.0, std::min(13.0, 2.0 * _approachD / v0));
    _approachC = std::min(3.0, v0 * _approachT / _approachD);   // keeps the ease monotonic
    _drive = kDriveApproach;
    _stateStart = time;
    os_unfair_lock_lock(&_lock);
    _inFile = YES;
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)driveCamera:(SCNNode *)camera atTime:(NSTimeInterval)time delta:(float)delta
{
    BOOL start, garbage, leave;
    float climb;
    os_unfair_lock_lock(&_lock);
    start = _startRequest;
    garbage = _garbageRequest;
    leave = _leaveRequest;
    _startRequest = _garbageRequest = _leaveRequest = NO;
    climb = (_climb ? 1.f : 0.f) - (_dive ? 1.f : 0.f);
    os_unfair_lock_unlock(&_lock);

    if (_drive == kDriveOff)
    {
        if (!start)
            return NO;   // title screen: the flythrough carries on
        _fromPose = gibson_pose_of(camera);
        const simd_float3 f = simd_make_float3(std::sin(_fromPose.yaw), 0, std::cos(_fromPose.yaw));
        [self joinGridFrom:_fromPose.pos forward:f];
        _yaw = _fromPose.yaw;
        _yawRate = 0;
        _bank = 0;
        _pitch = _fromPose.pitch;
        _alt = _fromPose.pos.y;
        _targetAlt = std::max(kAltMin, std::min(kAltMax, _alt));
        _speed = kCruise;
        _drive = kDriveStarting;
        _stateStart = time;
    }

    const float dt = std::max(1.f / 240.f, std::min(0.1f, delta));
    if (garbage && (_drive == kDriveFree || _drive == kDriveStarting))
        [self beginGarbageAtTime:time];
    const double el = time - _stateStart;   // after any state change above

    GibsonPose pose;
    switch (_drive)
    {
    case kDriveStarting:
    case kDriveFree:
    {
        _speed += (kCruise - _speed) * (1.f - std::exp(-dt / 1.0f));
        _s += _speed * dt;
        [self extendRoute:kPlanAhead forceStraight:NO];
        pose = [self routePoseWithDelta:dt climb:climb];
        if (_drive == kDriveStarting)
        {
            pose = gibson_mix(_fromPose, pose, gibson_smooth(0.f, 1.f, (float)(el / 1.5)));
            if (el >= 1.5)
                _drive = kDriveFree;
        }
        break;
    }
    case kDriveApproach:
    {
        const double x = std::min(1.0, el / _approachT);
        _approachX = (float)x;
        const double c = _approachC, a = c - 2.0, b = 3.0 - 2.0 * c;
        const double prev = _s;
        _s = _approachS0 + _approachD * ((a * x + b) * x + c) * x;
        _speed = (float)((_s - prev) / dt);
        [self extendRoute:kPlanAhead forceStraight:YES];
        /* Down the street, then over to the far side and up to the file's
           height, then (last) the turn to face it: one continuous move. */
        GibsonPose route = [self routePoseWithDelta:dt climb:0];
        const float wPos = gibson_smooth(0.4f, 1.f, (float)x);
        const float wTurn = gibson_smooth(0.55f, 1.f, (float)x);
        pose = route;
        pose.pos = route.pos + (_panPose.pos - route.pos) * wPos;
        pose.yaw = route.yaw + gibson_wrap(_panPose.yaw - route.yaw) * wTurn;
        pose.pitch = route.pitch * (1.f - wPos);
        pose.bank = route.bank * (1.f - wTurn);
        if (!_columnStopped && x >= 0.9)
        {
            [_column stopAtTime:time];
            _columnStopped = YES;
        }
        if (x >= 1.0)
        {
            _drive = kDrivePush;
            _stateStart = time;
        }
        break;
    }
    case kDrivePush:
        [self routePoseWithDelta:dt climb:0];
        pose = gibson_mix(_panPose, _endPose, gibson_smooth(0.f, 1.f, (float)(el / kPushTime)));
        if (el >= kPushTime)
        {
            _drive = kDriveHold;
            _stateStart = time;
        }
        break;
    case kDriveHold:
        [self routePoseWithDelta:dt climb:0];
        pose = _endPose;
        if (leave)
        {
            [_column fadeOutAtTime:time];
            _drive = kDriveLeaving;
            _stateStart = time;
            _speed = 0;
        }
        break;
    case kDriveLeaving:
    {
        const float w = gibson_smooth(0.f, 1.f, (float)(el / 1.6));
        _speed = kCruise * w;
        _s += _speed * dt;
        [self extendRoute:kPlanAhead forceStraight:NO];
        pose = gibson_mix(_endPose, [self routePoseWithDelta:dt climb:climb], w);
        if (el >= 1.6)
        {
            _drive = kDriveFree;
            os_unfair_lock_lock(&_lock);
            _inFile = NO;
            os_unfair_lock_unlock(&_lock);
        }
        break;
    }
    default:
        return NO;
    }

    /* The host tower turns as we fly towards it: from an ordinary tower, its
       tint darkens through the approach, and its listings fade in a little
       behind. Both go back as we leave. */
    const bool showing = _drive == kDriveApproach || _drive == kDrivePush || _drive == kDriveHold;
    float tint = 0, lists = 0;
    if (_drive == kDriveApproach)
    {
        tint = gibson_smooth(0.15f, 0.75f, _approachX);
        lists = gibson_smooth(0.35f, 0.9f, _approachX);
    }
    else if (showing)
        tint = lists = 1;
    const float follow = 1.f - std::exp(-dt / (showing ? 0.25f : 0.6f));
    _hostDim += (tint - _hostDim) * follow;
    _listFade += (lists - _listFade) * follow;
    const bool gone = !showing && _hostDim < 0.01f && _listFade < 0.01f;
    if (_column)
        _column.presence = _listFade;
    if (_hostTower)
    {
        _hostTower.opacity = 1.f - kHostDim * _hostDim;
        if (gone)
        {
            _hostTower.opacity = 1;
            _hostTower = nil;
        }
    }
    if (_hostDecor)
    {
        _hostDecor.opacity = _hostDim;
        for (GibsonGarbageColumn *list in _decoys)
        {
            list.presence = _listFade;
            [list updateAtTime:time];
        }
        if (gone)
        {
            [_hostDecor removeFromParentNode];
            _hostDecor = nil;
            _decoys = nil;
        }
    }
    [_column updateAtTime:time];
    if (_column && showing)
    {
        if (_column.fileOpen && !_mainOpen)
            [[GibsonSFX shared] select];
        if (_column.pulses != _mainPulses)
            [[GibsonSFX shared] pulse];
    }
    if (_column)
    {
        _mainPulses = _column.pulses;
        _mainOpen = _column.fileOpen;
    }
    if (_column.finished)
        _column = nil;
    gibson_apply_pose(camera, pose);
    os_unfair_lock_lock(&_lock);
    _hudAlt = pose.pos.y;
    os_unfair_lock_unlock(&_lock);
    return YES;
}

@end
