#import "GibsonScreenSaverViewController.h"
#import "GibsonSaverView.h"

#include <os/log.h>

static os_log_t gibson_vc_log(void)
{
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("org.hackthegibson.TheGibson", "controller");
    });
    return log;
}

@implementation GibsonScreenSaverViewController
{
    /* Strong reference so the framework can't drop the view while this
       controller still owns it (as AppexSaverMinimal does). */
    GibsonSaverView *_saverView;
}

- (instancetype)initWithNibName:(NSNibName)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    os_log(gibson_vc_log(), "The Gibson controller: init");
    return [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    os_log(gibson_vc_log(), "The Gibson controller: initWithCoder");
    return [super initWithCoder:coder];
}

- (void)dealloc
{
    os_log(gibson_vc_log(), "The Gibson controller: dealloc");
}

/* The framework only calls -loadView here. No preview flag is passed: the host
 * attaches the view to a 0x0 window and then resizes it, so size by
 * autoresizing (Apple's own screensavers do the same). */
- (void)loadView
{
    os_log(gibson_vc_log(), "The Gibson controller: loadView");
    GibsonSaverView *view = [[GibsonSaverView alloc] initWithFrame:NSZeroRect isPreview:NO];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _saverView = view;
    self.view = view ?: [[NSView alloc] initWithFrame:NSZeroRect];
}

- (BOOL)remoteViewSizeChanged:(NSSize)size transaction:(id)transaction
{
    /* Selector verified on macOS 27.2 only; don't crash if 26.x lacks it. */
    BOOL result = YES;
    if ([ScreenSaverViewController instancesRespondToSelector:_cmd])
        result = [super remoteViewSizeChanged:size transaction:transaction];
    os_log(gibson_vc_log(), "The Gibson controller: remoteViewSizeChanged %{public}@ -> %d",
           NSStringFromSize(size), result);
    return result;
}

- (void)viewWillAppear
{
    [super viewWillAppear];
    os_log(gibson_vc_log(), "The Gibson controller: viewWillAppear");
}

- (void)viewDidDisappear
{
    [super viewDidDisappear];
    os_log(gibson_vc_log(), "The Gibson controller: viewDidDisappear");
}

@end
