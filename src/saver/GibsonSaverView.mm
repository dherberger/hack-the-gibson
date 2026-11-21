#import "GibsonSaverView.h"
#import "GibsonMusic.h"
#import "GibsonSCNScene.h"

#import <QuartzCore/QuartzCore.h>
#import <SceneKit/SceneKit.h>
#include <os/log.h>
#include <unistd.h>

#include "gibson_settings.h"

/* Public so `log stream --predicate 'subsystem == "org.hackthegibson.TheGibson"'`
 * shows the text instead of <private>. */
static os_log_t gibson_os_log(void)
{
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("org.hackthegibson.TheGibson", "saver");
    });
    return log;
}

static void gibson_log(NSString *msg)
{
    os_log(gibson_os_log(), "The Gibson screensaver: %{public}@", msg);
}

/* Posted by the screensaver host (distributed notifications). The appex host
 * never calls -stopAnimation and keeps the extension process alive between
 * sessions, so these are the only reliable "stop rendering" signals besides
 * the view leaving its window. */
static NSString *const kSaverDidStart = @"com.apple.screensaver.didstart";
static NSString *const kSaverWillStop = @"com.apple.screensaver.willstop";
static NSString *const kSaverDidStop = @"com.apple.screensaver.didstop";

@implementation GibsonSaverView
{
    SCNView *_scnView;
    SCNNode *_viewCam;   // this display's slice of the shared view, once known
    BOOL _sessionActive;
    BOOL _musicActive;
}

/* Music only for a real full-screen session: System Settings' thumbnail
 * instance never gets a sized window, so it stays silent. */
static const CGFloat kMusicMinWidth = 400;

+ (BOOL)performGammaFade
{
    return NO;
}

- (NSURL *)mediaURL
{
    NSString *res = [[NSBundle bundleForClass:[self class]] resourcePath];
    return [NSURL fileURLWithPath:[res stringByAppendingPathComponent:@"media"]];
}

- (void)finishInit
{
    [self setAnimationTimeInterval:1.0 / 60.0];
    [self setWantsLayer:YES];
    self.layer.opaque = YES;
    CGColorRef bg = CGColorCreateGenericRGB(0.0, 0.0, 0.0, 1.0);
    self.layer.backgroundColor = bg;
    CGColorRelease(bg);

    NSDistributedNotificationCenter *dnc = [NSDistributedNotificationCenter defaultCenter];
    [dnc addObserver:self selector:@selector(saverDidStart:) name:kSaverDidStart object:nil];
    [dnc addObserver:self selector:@selector(saverWillStop:) name:kSaverWillStop object:nil];
    [dnc addObserver:self selector:@selector(saverWillStop:) name:kSaverDidStop object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(screensChanged:)
                                                 name:NSApplicationDidChangeScreenParametersNotification
                                               object:nil];
}

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview
{
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self)
    {
        [self finishInit];
        gibson_log([NSString stringWithFormat:@"init %@ %.0fx%.0f proc=%@",
                    isPreview ? @"preview" : @"full",
                    frame.size.width, frame.size.height,
                    [[NSProcessInfo processInfo] processName]]);
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self)
    {
        [self finishInit];
        gibson_log(@"init coder");
    }
    return self;
}

- (void)dealloc
{
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_viewCam removeFromParentNode];
    if (_musicActive)
        [[GibsonMusic shared] viewDidStop];
    gibson_log(@"dealloc");
}

- (BOOL)isOpaque { return YES; }
- (BOOL)hasConfigureSheet { return NO; }

- (void)attachSceneIfNeeded
{
    if (_scnView)
        return;

    NSURL *media = [self mediaURL];
    NSString *towers = [[media path] stringByAppendingPathComponent:@"towers.obj"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:towers])
    {
        gibson_log([NSString stringWithFormat:@"missing media at %@", [media path]]);
        return;
    }

    _scnView = [[SCNView alloc] initWithFrame:self.bounds];
    _scnView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _scnView.wantsLayer = YES;
    _scnView.layer.opaque = YES;
    /* Render below 1x and let it upscale: the film's CG was soft anyway, and
       fewer pixels keeps the bloom/blur/reflection passes cheap. */
    _scnView.layer.contentsScale = 0.75;
    [GibsonSCNScene configureView:_scnView preview:self.isPreview mediaURL:media];
    _scnView.preferredFramesPerSecond = self.isPreview ? 30 : 60;
    _scnView.antialiasingMode = SCNAntialiasingModeNone;
    _scnView.playing = NO;
    _scnView.rendersContinuously = NO;
    [self addSubview:_scnView];
    gibson_log(@"SCNView attached");
}

- (void)setPlaying:(BOOL)playing
{
    _scnView.playing = playing;
    _scnView.rendersContinuously = playing;
}

- (void)updateMusic
{
    const BOOL want = _sessionActive && !self.isPreview && self.window != nil
        && self.bounds.size.width >= kMusicMinWidth;
    if (want == _musicActive)
        return;
    _musicActive = want;
    if (want)
        [[GibsonMusic shared] viewDidStart];
    else
        [[GibsonMusic shared] viewDidStop];
}

/* The display this view covers, or nil if it can't be told. The view lives in
 * a remote-view window whose -screen is nil on secondary displays, but the
 * window's origin is the display's origin in top-left-origin global
 * coordinates (seen on macOS 27.2), so match that against the screen frames.
 * A unique size match is the fallback. */
- (NSScreen *)hostScreen
{
    NSArray<NSScreen *> *screens = [NSScreen screens];
    const NSSize size = self.bounds.size;
    if (!self.window || screens.count == 0 || size.width < 1 || size.height < 1)
        return nil;

    const NSPoint o = self.window.frame.origin;
    const CGFloat mainH = screens[0].frame.size.height;
    const NSRect flipped = NSMakeRect(o.x, mainH - o.y - size.height, size.width, size.height);
    const NSRect plain = NSMakeRect(o.x, o.y, size.width, size.height);
    auto near = [](NSRect a, NSRect b) {
        return fabs(a.origin.x - b.origin.x) < 1.5 && fabs(a.origin.y - b.origin.y) < 1.5
            && fabs(a.size.width - b.size.width) < 1.5 && fabs(a.size.height - b.size.height) < 1.5;
    };
    for (NSScreen *s in screens)
        if (near(s.frame, flipped))
            return s;
    for (NSScreen *s in screens)
        if (near(s.frame, plain))
            return s;

    NSScreen *bySize = nil;
    for (NSScreen *s in screens)
    {
        if (fabs(s.frame.size.width - size.width) >= 1.5
            || fabs(s.frame.size.height - size.height) >= 1.5)
            continue;
        if (bySize)
            return nil;   // two displays this size: ambiguous
        bySize = s;
    }
    return bySize;
}

/* With several displays, render this display's slice of one shared frustum
 * (GibsonWall.h). An unidentified view keeps whatever it had: the host
 * passes through transient sizes while attaching. */
- (void)updateProjection
{
    if (!_scnView || self.isPreview)
        return;
    GibsonSCNScene *world = [GibsonSCNScene sharedWorldForPreview:NO mediaURL:[self mediaURL]];
    if ([NSScreen screens].count < 2 || !gibson_span_displays())
    {
        _scnView.pointOfView = world.cameraNode;
        return;
    }
    NSScreen *screen = [self hostScreen];
    SCNMatrix4 projection;
    simd_quatf orientation;
    if (!screen || ![GibsonSCNScene wallProjection:&projection
                                       orientation:&orientation
                                         forScreen:screen])
        return;
    if (!_viewCam)
        _viewCam = [world makeViewCameraNode];
    _viewCam.camera.projectionTransform = projection;
    _viewCam.simdOrientation = orientation;
    if (_scnView.pointOfView != _viewCam)
    {
        _scnView.pointOfView = _viewCam;
        gibson_log([NSString stringWithFormat:@"spanning: view %.0fx%.0f is %@",
                    self.bounds.size.width, self.bounds.size.height, screen.localizedName]);
    }
}

- (void)screensChanged:(NSNotification *)note
{
    [self updateProjection];
}

/* Multi-monitor diagnostic: which process hosts this view, and can the view
 * tell which display it is on? Read with
 *   log show --last 10m --predicate 'subsystem == "org.hackthegibson.TheGibson"' | grep diag */
- (void)logDisplayDiagnostics:(NSString *)reason
{
    NSWindow *win = self.window;
    NSScreen *ws = win.screen;
    const NSRect onScreen = win ? [win convertRectToScreen:[self convertRect:self.bounds toView:nil]]
                                : NSZeroRect;
    gibson_log([NSString stringWithFormat:
        @"diag (%@) pid=%d view=%p bounds=%@ window=%@ winFrame=%@ viewOnScreen=%@ "
        @"winScreen=%@ id=%@ frame=%@",
        reason, getpid(), self, NSStringFromSize(self.bounds.size),
        win ? NSStringFromClass([win class]) : @"(none)",
        NSStringFromRect(win.frame), NSStringFromRect(onScreen),
        ws ? ws.localizedName : @"(none)",
        ws.deviceDescription[@"NSScreenNumber"] ?: @"-",
        NSStringFromRect(ws.frame)]);

    NSArray<NSScreen *> *screens = [NSScreen screens];
    for (NSUInteger i = 0; i < screens.count; i++)
    {
        NSScreen *s = screens[i];
        NSNumber *num = s.deviceDescription[@"NSScreenNumber"];
        const CGSize mm = CGDisplayScreenSize((CGDirectDisplayID)num.unsignedIntValue);
        gibson_log([NSString stringWithFormat:
            @"diag (%@) pid=%d screen[%lu/%lu] %@ id=%@ frame=%@ scale=%.1f mm=%.0fx%.0f",
            reason, getpid(), (unsigned long)i, (unsigned long)screens.count,
            s.localizedName, num ?: @"-", NSStringFromRect(s.frame),
            s.backingScaleFactor, mm.width, mm.height]);
    }
}

- (void)setFrameSize:(NSSize)newSize
{
    const NSSize old = self.frame.size;
    [super setFrameSize:newSize];
    [self updateMusic];   // the host sizes the view after attaching it
    [self updateProjection];
    if (_sessionActive && !NSEqualSizes(old, newSize))
        [self logDisplayDiagnostics:@"resize"];
}

/* Idempotent: called from -viewDidMoveToWindow, -startAnimation and didstart,
 * whichever the host happens to deliver. */
- (void)beginSession:(NSString *)reason
{
    if (_sessionActive || !self.window)
        return;
    _sessionActive = YES;

    NSString *res = [[NSBundle bundleForClass:[self class]] resourcePath];
    gibson_settings_reload(res.fileSystemRepresentation);
    gibson_log([NSString stringWithFormat:@"begin (%@) fly_speed=%.2f bank=%.2f from %s",
                reason, gibson_fly_speed(), gibson_bank_strength(),
                gibson_settings_path()[0] ? gibson_settings_path() : "(default)"]);

    [self logDisplayDiagnostics:reason];
    [self attachSceneIfNeeded];
    [self updateProjection];
    [[GibsonSCNScene sharedWorldForPreview:self.isPreview mediaURL:[self mediaURL]] resetClock];
    [self setPlaying:YES];
    [self updateMusic];
}

- (void)endSession:(NSString *)reason
{
    if (!_sessionActive)
        return;
    _sessionActive = NO;
    [self setPlaying:NO];
    [self updateMusic];
    gibson_log([NSString stringWithFormat:@"end (%@)", reason]);
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    gibson_log([NSString stringWithFormat:@"viewDidMoveToWindow hasWindow=%d win=%.0fx%.0f",
                self.window != nil,
                self.window.frame.size.width, self.window.frame.size.height]);
    if (self.window)
        [self beginSession:@"window"];
    else
        [self endSession:@"no window"];
}

- (void)saverDidStart:(NSNotification *)note
{
    [self beginSession:@"didstart"];
}

- (void)saverWillStop:(NSNotification *)note
{
    [self endSession:note.name];
}

- (void)startAnimation
{
    [super startAnimation];
    [self beginSession:@"startAnimation"];
    gibson_log([NSString stringWithFormat:@"startAnimation %.0fx%.0f win=%.0fx%.0f",
                self.bounds.size.width, self.bounds.size.height,
                self.window.frame.size.width, self.window.frame.size.height]);
}

- (void)stopAnimation
{
    [self endSession:@"stopAnimation"];
    [super stopAnimation];
}

- (void)animateOneFrame
{
    /* SCNView renders itself while playing. */
}

@end
