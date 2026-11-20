#import "GibsonSCNScene.h"

#import <Cocoa/Cocoa.h>
#import <SceneKit/SceneKit.h>

#include "gibson_settings.h"
#include <cstdio>
#include <cstring>

static void gibson_register_appex(void)
{
    NSString *plugins = [NSBundle mainBundle].builtInPlugInsPath;
    if (!plugins.length)
        return;
    NSString *appex = [plugins stringByAppendingPathComponent:@"TheGibson.appex"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:appex])
        return;

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/pluginkit"];
    task.arguments = @[ @"-a", appex ];
    task.standardOutput = [NSPipe pipe];
    task.standardError = [NSPipe pipe];
    NSError *err = nil;
    if (![task launchAndReturnError:&err])
    {
        NSLog(@"The Gibson: pluginkit -a failed: %@", err);
        return;
    }
    [task waitUntilExit];
    NSLog(@"The Gibson: pluginkit -a %@ status=%d", appex, task.terminationStatus);
}

static BOOL gibson_is_installed_location(void)
{
    NSString *path = [NSBundle mainBundle].bundlePath;
    return [path hasPrefix:@"/Applications/"] ||
           [path containsString:@"/Applications/TheGibson.app"];
}

static NSURL *gibson_app_media(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSBundle *app = [NSBundle mainBundle];
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];

    NSString *res = [app.resourcePath stringByAppendingPathComponent:@"media"];
    if (res)
        [dirs addObject:res];

    NSString *appexMedia = [app.builtInPlugInsPath
        stringByAppendingPathComponent:@"TheGibson.appex/Contents/Resources/media"];
    if (appexMedia)
        [dirs addObject:appexMedia];

    NSString *cwd = fm.currentDirectoryPath;
    [dirs addObject:[cwd stringByAppendingPathComponent:@"media"]];
    [dirs addObject:[[cwd stringByAppendingPathComponent:@".."] stringByAppendingPathComponent:@"media"]];

    for (NSString *dir in dirs)
    {
        NSString *std = dir.stringByStandardizingPath;
        if ([fm fileExistsAtPath:[std stringByAppendingPathComponent:@"towers.obj"]])
            return [NSURL fileURLWithPath:std];
    }
    return nil;
}

static int gibson_run_preview(NSURL *media)
{
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    const NSRect frame = NSMakeRect(0, 0, 1280, 800);
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"The Gibson";
    window.releasedWhenClosed = NO;

    SCNView *view = [[SCNView alloc] initWithFrame:frame];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [GibsonSCNScene configureView:view preview:NO mediaURL:media];
    window.contentView = view;

    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                          handler:^NSEvent *(NSEvent *event) {
        if (event.keyCode == 53)
        {
            [NSApp terminate:nil];
            return nil;
        }
        NSEventModifierFlags mods =
            event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        NSString *chars = event.charactersIgnoringModifiers.lowercaseString;
        if ((mods & NSEventModifierFlagCommand) &&
            ([chars isEqualToString:@"q"] || [chars isEqualToString:@"w"]))
        {
            [NSApp terminate:nil];
            return nil;
        }
        if ([chars isEqualToString:@"q"])
        {
            [NSApp terminate:nil];
            return nil;
        }
        return event;
    }];

    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSWindowWillCloseNotification
                    object:window
                     queue:nil
                usingBlock:^(NSNotification *) {
                    [NSApp terminate:nil];
                }];

    [window center];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [NSApp run];
    return 0;
}

int main(int argc, char **argv)
{
    BOOL registerOnly = NO;
    for (int i = 1; i < argc; ++i)
    {
        if (std::strcmp(argv[i], "--register") == 0)
            registerOnly = YES;
        else if (std::strcmp(argv[i], "--help") == 0 || std::strcmp(argv[i], "-h") == 0)
        {
            std::fprintf(stderr,
                         "Usage: %s [--register]\n"
                         "  Host app for The Gibson screensaver. Opening the installed\n"
                         "  copy in /Applications registers the Screen Saver extension.\n",
                         argv[0]);
            return 0;
        }
    }

    @autoreleasepool
    {
        [NSApplication sharedApplication];

        if (registerOnly || gibson_is_installed_location())
            gibson_register_appex();
        if (registerOnly)
            return 0;

        NSURL *media = gibson_app_media();
        if (!media)
        {
            std::fprintf(stderr, "Could not find media/ inside the app bundle.\n");
            return 1;
        }
        NSString *res = [NSBundle mainBundle].resourcePath;
        gibson_settings_reload(res.fileSystemRepresentation);
        return gibson_run_preview(media);
    }
}
