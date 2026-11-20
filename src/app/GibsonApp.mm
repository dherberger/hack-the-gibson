#import "GibsonSCNScene.h"

#import <AVFoundation/AVFoundation.h>
#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
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

// ---------------------------------------------------------------------------
// Flythrough preview window

static NSWindow *gibson_make_preview_window(NSURL *media)
{
    const NSRect frame = NSMakeRect(0, 0, 1280, 800);
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"The Gibson — Preview";
    window.releasedWhenClosed = NO;

    SCNView *view = [[SCNView alloc] initWithFrame:frame];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [GibsonSCNScene configureView:view preview:NO mediaURL:media];
    window.contentView = view;
    [window center];
    return window;
}

// ---------------------------------------------------------------------------
// Settings window: edits ~/Library/Application Support/TheGibson/config.txt,
// which the screensaver re-reads each time it starts.

struct GibsonSlider {
    const char *key;
    NSString *label;
    double min, max;
    NSString *format;
};

static const GibsonSlider kSliders[] = {
    {"fly_speed", @"Flight speed", 0.2, 1.2, @"%.2f"},
    {"bank_strength", @"Banking", 0.0, 1.5, @"%.2f"},
    {"bank_max_degrees", @"Max bank", 0.0, 60.0, @"%.0f°"},
    {"bank_smoothing", @"Bank smoothing", 0.1, 1.5, @"%.2f s"},
};
static const int kSliderCount = sizeof(kSliders) / sizeof(kSliders[0]);

static double gibson_setting_value(const char *key)
{
    const GibsonSettings s = gibson_settings();
    if (!strcmp(key, "fly_speed")) return s.fly_speed;
    if (!strcmp(key, "bank_strength")) return s.bank_strength;
    if (!strcmp(key, "bank_max_degrees")) return s.bank_max_degrees;
    if (!strcmp(key, "bank_smoothing")) return s.bank_smoothing;
    if (!strcmp(key, "music_volume")) return s.music_volume;
    return 0;
}

@interface GibsonAppController : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSURL *media;
@end

@implementation GibsonAppController
{
    NSWindow *_settings;
    NSWindow *_preview;
    NSButton *_musicEnabled;
    NSTextField *_musicFile;
    NSButton *_chooseButton;
    NSButton *_testButton;
    NSSlider *_volume;
    NSTextField *_volumeLabel;
    NSSlider *_sliders[kSliderCount];
    NSTextField *_sliderLabels[kSliderCount];
    AVAudioPlayer *_testPlayer;
}

- (void)reloadSettings
{
    gibson_settings_reload([NSBundle mainBundle].resourcePath.fileSystemRepresentation);
}

- (void)write:(const char *)key value:(NSString *)value
{
    if (!gibson_settings_set(key, value.UTF8String))
        NSLog(@"The Gibson: couldn't write %s to config.txt", key);
    [self reloadSettings];
}

static NSTextField *gibson_label(NSString *text)
{
    NSTextField *f = [NSTextField labelWithString:text];
    f.alignment = NSTextAlignmentRight;
    return f;
}

static NSTextField *gibson_note(NSString *text)
{
    NSTextField *f = [NSTextField wrappingLabelWithString:text];
    f.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    f.textColor = NSColor.secondaryLabelColor;
    f.preferredMaxLayoutWidth = 380;
    return f;
}

static NSTextField *gibson_header(NSString *text)
{
    NSTextField *f = [NSTextField labelWithString:text];
    f.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
    return f;
}

- (NSSlider *)sliderMin:(double)min max:(double)max tag:(NSInteger)tag
{
    NSSlider *s = [NSSlider sliderWithValue:min minValue:min maxValue:max
                                     target:self action:@selector(sliderMoved:)];
    s.tag = tag;
    s.continuous = YES;
    [s.widthAnchor constraintGreaterThanOrEqualToConstant:220].active = YES;
    return s;
}

- (void)buildSettingsWindow
{
    _musicEnabled = [NSButton checkboxWithTitle:@"Play music while the screensaver runs"
                                         target:self action:@selector(toggleMusic:)];
    _musicFile = [NSTextField labelWithString:@""];
    _musicFile.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_musicFile setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];
    _chooseButton = [NSButton buttonWithTitle:@"Choose…" target:self action:@selector(chooseMusic:)];
    _testButton = [NSButton buttonWithTitle:@"Play" target:self action:@selector(testMusic:)];
    NSStackView *fileRow = [NSStackView stackViewWithViews:@[ _musicFile, _chooseButton, _testButton ]];
    fileRow.spacing = 8;

    _volume = [self sliderMin:0 max:1 tag:-1];
    _volumeLabel = [NSTextField labelWithString:@""];
    _volumeLabel.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize
                                                         weight:NSFontWeightRegular];
    NSStackView *volRow = [NSStackView stackViewWithViews:@[ _volume, _volumeLabel ]];

    NSMutableArray<NSArray<NSView *> *> *rows = [NSMutableArray array];
    [rows addObject:@[ gibson_label(@""), gibson_header(@"Music") ]];
    [rows addObject:@[ gibson_label(@""), _musicEnabled ]];
    [rows addObject:@[ gibson_label(@"File:"), fileRow ]];
    [rows addObject:@[ gibson_label(@"Volume:"), volRow ]];
    [rows addObject:@[ gibson_label(@""),
                       gibson_note(@"No music ships with The Gibson. Choose any audio file "
                                   @"(MP3, M4A, WAV…); it's copied next to config.txt, the "
                                   @"one folder the sandboxed screensaver can read.") ]];
    [rows addObject:@[ gibson_label(@""), gibson_header(@"Flight") ]];
    for (int i = 0; i < kSliderCount; ++i)
    {
        _sliders[i] = [self sliderMin:kSliders[i].min max:kSliders[i].max tag:i];
        _sliderLabels[i] = [NSTextField labelWithString:@""];
        _sliderLabels[i].font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize
                                                                 weight:NSFontWeightRegular];
        NSStackView *row = [NSStackView stackViewWithViews:@[ _sliders[i], _sliderLabels[i] ]];
        [rows addObject:@[ gibson_label([kSliders[i].label stringByAppendingString:@":"]), row ]];
    }
    [rows addObject:@[ gibson_label(@""),
                       gibson_note(@"Changes are saved right away and apply the next time "
                                   @"the screensaver starts.") ]];

    NSGridView *grid = [NSGridView gridViewWithViews:rows];
    grid.rowSpacing = 8;
    grid.columnSpacing = 10;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    for (NSInteger r = 0; r < grid.numberOfRows; ++r)
        [grid rowAtIndex:r].yPlacement = NSGridCellPlacementCenter;
    [grid rowAtIndex:5].topPadding = 10;   // "Flight" header

    NSButton *preview = [NSButton buttonWithTitle:@"Preview" target:self action:@selector(showPreview:)];
    preview.keyEquivalent = @"\r";
    NSButton *folder = [NSButton buttonWithTitle:@"Show Config File" target:self
                                          action:@selector(revealConfig:)];
    NSStackView *buttons = [NSStackView stackViewWithViews:@[ folder, preview ]];
    buttons.spacing = 8;

    NSStackView *content = [NSStackView stackViewWithViews:@[ grid, buttons ]];
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.alignment = NSLayoutAttributeTrailing;
    content.spacing = 18;
    content.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
    content.translatesAutoresizingMaskIntoConstraints = NO;

    _settings = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 420)
                                            styleMask:(NSWindowStyleMaskTitled |
                                                       NSWindowStyleMaskClosable |
                                                       NSWindowStyleMaskMiniaturizable)
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
    _settings.title = @"The Gibson";
    _settings.releasedWhenClosed = NO;
    _settings.delegate = self;
    NSView *host = [[NSView alloc] init];
    [host addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:host.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
    ]];
    _settings.contentView = host;
    [self refreshControls];
    [_settings center];
}

- (void)refreshControls
{
    const BOOL on = gibson_music_enabled() != 0;
    _musicEnabled.state = on ? NSControlStateValueOn : NSControlStateValueOff;

    NSString *name = [NSString stringWithUTF8String:gibson_music_setting()];
    NSString *path = [self musicPathForName:name];
    const BOOL exists = path && [[NSFileManager defaultManager] isReadableFileAtPath:path];
    if (!name.length || !path)
        _musicFile.stringValue = @"(none)";
    else
        _musicFile.stringValue = exists ? name.lastPathComponent
                                        : [name.lastPathComponent stringByAppendingString:@" — not found"];
    _musicFile.textColor = exists ? NSColor.labelColor : NSColor.secondaryLabelColor;
    _testButton.enabled = exists;
    _volume.enabled = on;
    _volume.doubleValue = gibson_setting_value("music_volume");
    _volumeLabel.stringValue = [NSString stringWithFormat:@"%3.0f%%", _volume.doubleValue * 100];

    for (int i = 0; i < kSliderCount; ++i)
    {
        _sliders[i].doubleValue = gibson_setting_value(kSliders[i].key);
        _sliderLabels[i].stringValue = [NSString stringWithFormat:kSliders[i].format,
                                                                  _sliders[i].doubleValue];
    }
}

// Mirrors gibson_music_path() without the enabled check, so the file row
// shows what will play once music is switched on.
- (NSString *)musicPathForName:(NSString *)name
{
    NSString *lower = name.lowercaseString;
    if (!name.length || [lower isEqualToString:@"off"] || [lower isEqualToString:@"none"] ||
        [lower isEqualToString:@"0"] || [lower isEqualToString:@"false"])
        return nil;
    if ([name hasPrefix:@"/"] || [name hasPrefix:@"~/"])
        return name.stringByExpandingTildeInPath;
    return [[NSString stringWithUTF8String:gibson_user_dir()] stringByAppendingPathComponent:name];
}

- (void)toggleMusic:(NSButton *)sender
{
    const BOOL on = sender.state == NSControlStateValueOn;
    [self write:"music_enabled" value:on ? @"yes" : @"no"];
    if (on && ![self musicPathForName:[NSString stringWithUTF8String:gibson_music_setting()]])
        [self write:"music" value:@"music.mp3"];   // was `off`
    [self refreshControls];
}

- (void)sliderMoved:(NSSlider *)sender
{
    const char *key = sender.tag < 0 ? "music_volume" : kSliders[sender.tag].key;
    NSString *fmt = sender.tag < 0 ? @"%.2f" : @"%.3g";
    double v = sender.doubleValue;
    if (sender.tag >= 0 && !strcmp(key, "bank_max_degrees"))
        v = round(v);
    [self write:key value:[NSString stringWithFormat:fmt, v]];
    if (sender.tag < 0)
        _testPlayer.volume = (float)v;
    [self refreshControls];
}

- (void)chooseMusic:(id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[ UTTypeAudio ];
    panel.allowsMultipleSelection = NO;
    panel.prompt = @"Use This Track";
    panel.message = @"The file is copied into the screensaver's folder.";
    [panel beginSheetModalForWindow:_settings completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK || !panel.URL)
            return;
        [self useMusicFile:panel.URL];
    }];
}

- (void)useMusicFile:(NSURL *)src
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [NSString stringWithUTF8String:gibson_user_dir()];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *name = src.lastPathComponent;
    NSString *dest = [dir stringByAppendingPathComponent:name];
    NSError *err = nil;
    if (![src.path.stringByStandardizingPath isEqualToString:dest.stringByStandardizingPath])
    {
        NSString *tmp = [dest stringByAppendingString:@".copying"];
        [fm removeItemAtPath:tmp error:nil];
        if (![fm copyItemAtPath:src.path toPath:tmp error:&err] ||
            ([fm fileExistsAtPath:dest] && ![fm removeItemAtPath:dest error:&err]) ||
            ![fm moveItemAtPath:tmp toPath:dest error:&err])
        {
            [fm removeItemAtPath:tmp error:nil];
            [[NSAlert alertWithError:err] beginSheetModalForWindow:_settings completionHandler:nil];
            return;
        }
    }
    [self stopTest];
    [self write:"music" value:name];
    [self write:"music_enabled" value:@"yes"];
    [self refreshControls];
}

- (void)stopTest
{
    [_testPlayer stop];
    _testPlayer = nil;
    _testButton.title = @"Play";
}

- (void)testMusic:(id)sender
{
    if (_testPlayer.playing)
    {
        [self stopTest];
        return;
    }
    NSString *path = [self musicPathForName:[NSString stringWithUTF8String:gibson_music_setting()]];
    if (!path)
        return;
    NSError *err = nil;
    _testPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&err];
    if (!_testPlayer)
    {
        [[NSAlert alertWithError:err] beginSheetModalForWindow:_settings completionHandler:nil];
        return;
    }
    _testPlayer.numberOfLoops = -1;
    _testPlayer.volume = (float)gibson_music_volume();
    [_testPlayer play];
    _testButton.title = @"Stop";
}

- (void)revealConfig:(id)sender
{
    NSString *path = [NSString stringWithUTF8String:gibson_settings_path()];
    if (!path.length)
        path = [[NSString stringWithUTF8String:gibson_user_dir()] stringByAppendingPathComponent:@"config.txt"];
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:path] ]];
}

- (void)showSettings:(id)sender
{
    [self reloadSettings];   // pick up hand edits to config.txt
    [self refreshControls];
    [_settings makeKeyAndOrderFront:nil];
}

- (void)showPreview:(id)sender
{
    if (!_media)
        return;
    if (!_preview)
    {
        _preview = gibson_make_preview_window(_media);
        _preview.delegate = self;
    }
    [_preview makeKeyAndOrderFront:nil];
}

- (void)windowWillClose:(NSNotification *)note
{
    if (note.object == _preview)
    {
        // Drop the SceneKit view so the flythrough stops rendering.
        _preview.delegate = nil;
        _preview = nil;
    }
    else if (note.object == _settings)
        [self stopTest];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
    return YES;
}

- (void)applicationDidBecomeActive:(NSNotification *)note
{
    if (_settings.visible)
    {
        [self reloadSettings];
        [self refreshControls];
    }
}

- (void)buildMenu
{
    NSMenu *main = [[NSMenu alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"The Gibson"];
    [appMenu addItemWithTitle:@"About The Gibson"
                       action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Settings…" action:@selector(showSettings:) keyEquivalent:@","].target = self;
    [appMenu addItemWithTitle:@"Preview" action:@selector(showPreview:) keyEquivalent:@"p"].target = self;
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide The Gibson" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit The Gibson" action:@selector(terminate:) keyEquivalent:@"q"];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    appItem.submenu = appMenu;
    [main addItem:appItem];

    NSMenu *winMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [winMenu addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
    [winMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    NSMenuItem *winItem = [[NSMenuItem alloc] init];
    winItem.submenu = winMenu;
    [main addItem:winItem];
    NSApp.mainMenu = main;
    NSApp.windowsMenu = winMenu;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    [self buildMenu];
    [self buildSettingsWindow];
    [_settings makeKeyAndOrderFront:nil];

    // Escape or Q closes the preview (not the app).
    __weak GibsonAppController *weakSelf = self;
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                          handler:^NSEvent *(NSEvent *event) {
        GibsonAppController *s = weakSelf;
        if (!s || !s->_preview || NSApp.keyWindow != s->_preview)
            return event;
        NSEventModifierFlags mods =
            event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        NSString *chars = event.charactersIgnoringModifiers.lowercaseString;
        if (event.keyCode == 53 || (!mods && [chars isEqualToString:@"q"]))
        {
            [s->_preview performClose:nil];
            return nil;
        }
        return event;
    }];
    [NSApp activateIgnoringOtherApps:YES];
}

@end

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
                         "  Host app for The Gibson screensaver: a settings window and a\n"
                         "  flythrough preview. Opening the installed copy in /Applications\n"
                         "  also registers the Screen Saver extension.\n",
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

        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        GibsonAppController *controller = [[GibsonAppController alloc] init];
        controller.media = media;
        NSApp.delegate = controller;
        [NSApp run];
        return 0;
    }
}
