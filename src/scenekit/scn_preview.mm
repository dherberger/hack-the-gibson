#import "GibsonSCNScene.h"
#import "GibsonGarbage.h"
#import "GibsonFonts.h"

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <SceneKit/SceneKit.h>

#include "gibson_settings.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <unistd.h>
#import <simd/simd.h>

static NSURL *gibson_find_media(const char *argv0)
{
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
    [dirs addObject:cwd];
    [dirs addObject:[cwd stringByAppendingPathComponent:@".."]];
    if (argv0 && argv0[0])
    {
        NSString *exe = [[NSString stringWithUTF8String:argv0] stringByStandardizingPath];
        NSString *dir = [exe stringByDeletingLastPathComponent];
        [dirs addObject:dir];
        [dirs addObject:[dir stringByAppendingPathComponent:@".."]];
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in dirs)
    {
        NSString *media = [[dir stringByAppendingPathComponent:@"media"] stringByStandardizingPath];
        if ([fm fileExistsAtPath:[media stringByAppendingPathComponent:@"towers.obj"]])
            return [NSURL fileURLWithPath:media];
    }
    return nil;
}

static int gibson_write_snapshot(NSURL *media, const char *outPath)
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device)
    {
        std::fprintf(stderr, "No Metal device.\n");
        return 1;
    }
    GibsonSCNScene *world = [GibsonSCNScene sharedWorldForPreview:NO mediaURL:media];
    SCNRenderer *renderer = [SCNRenderer rendererWithDevice:device options:nil];
    renderer.scene = world.scene;
    renderer.pointOfView = world.cameraNode;
    renderer.autoenablesDefaultLighting = NO;
    const NSTimeInterval time = CACurrentMediaTime();
    [world tickAtTime:time];
    NSImage *image = [renderer snapshotAtTime:time
                                     withSize:NSMakeSize(1280, 800)
                             antialiasingMode:SCNAntialiasingModeNone];
    if (!image)
    {
        std::fprintf(stderr, "SCNRenderer snapshot failed.\n");
        return 1;
    }
    NSData *tiff = [image TIFFRepresentation];
    NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:tiff];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (![png writeToFile:[NSString stringWithUTF8String:outPath] atomically:YES])
    {
        std::fprintf(stderr, "Could not write %s\n", outPath);
        return 1;
    }
    std::fprintf(stderr, "Wrote %s\n", outPath);
    return 0;
}

static BOOL gibson_write_png(NSImage *image, NSString *path)
{
    NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:[image TIFFRepresentation]];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES];
}

/* Multi-monitor check: render each attached display's slice of the wall and
 * paste them together (wall.png), next to one render of the wall's whole
 * bounding box (wall_ref.png). Where there are screens, the two should match
 * (tilted displays are pasted flat, so those only match roughly). */
static int gibson_write_wall(NSURL *media, const char *dir, double atTime)
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device)
    {
        std::fprintf(stderr, "No Metal device.\n");
        return 1;
    }
    NSString *outDir = [NSString stringWithUTF8String:dir];
    [[NSFileManager defaultManager] createDirectoryAtPath:outDir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    GibsonSCNScene *world = [GibsonSCNScene sharedWorldForPreview:NO mediaURL:media];
    SCNRenderer *renderer = [SCNRenderer rendererWithDevice:device options:nil];
    renderer.scene = world.scene;
    renderer.autoenablesDefaultLighting = NO;

    const double step = 1.0 / 60.0;
    double t = 0.0;
    [world tickAtTime:t];
    while (t + step <= atTime)
    {
        t += step;
        [world tickAtTime:t];
    }

    SCNMatrix4 boundsProj;
    CGFloat aspect = 1;
    if (![GibsonSCNScene wallBoundsProjection:&boundsProj aspect:&aspect])
    {
        std::fprintf(stderr, "No screens.\n");
        return 1;
    }
    const CGFloat canvasW = 1600;
    const CGFloat canvasH = std::round(canvasW / aspect);

    SCNNode *cam = [world makeViewCameraNode];
    cam.camera.motionBlurIntensity = 0.0;
    renderer.pointOfView = cam;

    cam.camera.projectionTransform = boundsProj;
    cam.simdOrientation = simd_quaternion(0.f, 0.f, 0.f, 1.f);
    NSImage *ref = [renderer snapshotAtTime:t withSize:NSMakeSize(canvasW, canvasH)
                           antialiasingMode:SCNAntialiasingModeMultisampling4X];
    gibson_write_png(ref, [outDir stringByAppendingPathComponent:@"wall_ref.png"]);

    NSImage *canvas = [[NSImage alloc] initWithSize:NSMakeSize(canvasW, canvasH)];
    [canvas lockFocus];
    [[NSColor colorWithCalibratedRed:0.25 green:0.0 blue:0.0 alpha:1.0] setFill];
    NSRectFill(NSMakeRect(0, 0, canvasW, canvasH));
    [canvas unlockFocus];
    for (NSScreen *screen in [NSScreen screens])
    {
        SCNMatrix4 proj;
        simd_quatf orient;
        if (![GibsonSCNScene wallProjection:&proj orientation:&orient forScreen:screen])
            continue;
        cam.simdOrientation = orient;
        const NSRect u = [GibsonSCNScene wallUnitRectForScreen:screen];
        const NSRect dst = NSMakeRect(u.origin.x * canvasW, u.origin.y * canvasH,
                                      u.size.width * canvasW, u.size.height * canvasH);
        cam.camera.projectionTransform = proj;
        NSImage *img = [renderer snapshotAtTime:t withSize:dst.size
                               antialiasingMode:SCNAntialiasingModeMultisampling4X];
        [canvas lockFocus];
        [img drawInRect:dst fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1.0];
        [canvas unlockFocus];
        std::fprintf(stderr, "%s: slice %.3f,%.3f %.3fx%.3f of the wall\n",
                     screen.localizedName.UTF8String, u.origin.x, u.origin.y,
                     u.size.width, u.size.height);
    }
    gibson_write_png(canvas, [outDir stringByAppendingPathComponent:@"wall.png"]);
    std::fprintf(stderr, "Wrote wall.png and wall_ref.png to %s\n", dir);
    return 0;
}

/* Step simulated time at 60 Hz from t=0 and write a PNG every `interval` s,
 * for frame-by-frame comparison with reference footage. */
/* Development: the game's garbage-file column on a tower, camera squared up
 * as the game leaves it, rendered at a few moments of the sequence. */
@interface GibsonFixedCamera : NSObject <GibsonCameraDriver>
@property (nonatomic) simd_float3 pos;
@property (nonatomic) float yaw;
@property (nonatomic, strong) GibsonGarbageColumn *column;
@end
@implementation GibsonFixedCamera
- (BOOL)driveCamera:(SCNNode *)camera atTime:(NSTimeInterval)time delta:(float)delta
{
    const simd_float3 f = simd_make_float3(std::sin(_yaw), 0, std::cos(_yaw));
    const simd_float3 z = -f;
    const simd_float3 x = simd_normalize(simd_cross(simd_make_float3(0, 1, 0), z));
    const simd_float3 y = simd_cross(z, x);
    camera.simdPosition = _pos;
    camera.simdOrientation = simd_quaternion(simd_matrix(x, y, z));
    [_column updateAtTime:time];
    return YES;
}
@end

static int gibson_write_garbage(NSURL *media, const char *dir)
{
    gibson_fonts_set_media(media);
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    [[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithUTF8String:dir]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    GibsonSCNScene *world = [GibsonSCNScene sharedWorldForPreview:NO mediaURL:media];
    SCNRenderer *renderer = [SCNRenderer rendererWithDevice:device options:nil];
    renderer.scene = world.scene;
    renderer.pointOfView = world.cameraNode;
    renderer.autoenablesDefaultLighting = NO;
    world.cameraNode.camera.motionBlurIntensity = 0.0;

    // Street x = 0, tower to its +x side centred at (15, y, 30).
    const float width = 13.f;
    const float h = [GibsonGarbageColumn heightForWidth:width];
    const float dist = h / (0.85f * 2.f * std::tan(36.f * (float)M_PI / 180.f));
    const simd_float3 normal = simd_make_float3(-1, 0, 0);
    const simd_float3 face = simd_make_float3(15.f - 7.3f, 18.f, 30.f);
    GibsonFixedCamera *driver = [[GibsonFixedCamera alloc] init];
    driver.pos = face + normal * dist;
    driver.yaw = (float)M_PI / 2;
    world.cameraDriver = driver;
    driver.column = [[GibsonGarbageColumn alloc] initWithParent:world.worldRoot
                                                         center:face + normal * 0.15f
                                                         normal:normal
                                                          width:width
                                                           time:0];
    SCNNode *plate = [GibsonGarbageColumn facePlateWithWidth:14.7f height:43.5f];
    plate.simdPosition = simd_make_float3(15.f - 7.3f - 0.08f, 43.5f / 2, 30.f);
    plate.simdOrientation = simd_quaternion(-(float)M_PI / 2, simd_make_float3(0, 1, 0));
    [world.worldRoot addChildNode:plate];
    [driver.column revealAtTime:0];
    [world towerNodeAtX:15 z:30].opacity = 0.3;
    const double shots[] = { 1.0, 6.0, 7.2, 8.0 };
    const double step = 1.0 / 60.0;
    double t = 0;
    for (double shot : shots)
    {
        while (t + step <= shot)
        {
            t += step;
            if (std::fabs(t - 1.5) < step / 2)
                [driver.column stopAtTime:t];
            [world tickAtTime:t];
            if (t > 1.5 && t < 1.6)
                usleep(300000);   // let the frames render off-thread
        }
        @autoreleasepool
        {
            NSImage *image = [renderer snapshotAtTime:t withSize:NSMakeSize(1440, 900)
                                     antialiasingMode:SCNAntialiasingModeMultisampling4X];
            NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:[image TIFFRepresentation]];
            NSString *out = [NSString stringWithFormat:@"%s/garbage_%.1f.png", dir, shot];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:out atomically:YES];
        }
    }
    return 0;
}

static int gibson_write_sequence(NSURL *media, const char *dir, int count, double interval,
                                 NSSize size)
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device)
    {
        std::fprintf(stderr, "No Metal device.\n");
        return 1;
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithUTF8String:dir]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    GibsonSCNScene *world = [GibsonSCNScene sharedWorldForPreview:NO mediaURL:media];
    SCNRenderer *renderer = [SCNRenderer rendererWithDevice:device options:nil];
    renderer.scene = world.scene;
    renderer.pointOfView = world.cameraNode;
    renderer.autoenablesDefaultLighting = NO;
    /* Offscreen snapshots turn motion blur into heavy grain; the live view
       is fine, so only the comparison frames drop it. */
    world.cameraNode.camera.motionBlurIntensity = 0.0;

    const double step = 1.0 / 60.0;
    double t = 0.0;
    [world tickAtTime:t];
    for (int i = 0; i < count; ++i)
    {
        const double target = i * interval;
        while (t + step <= target + 1e-9)
        {
            t += step;
            [world tickAtTime:t];
        }
        @autoreleasepool
        {
            NSImage *image = [renderer snapshotAtTime:t withSize:size
                                     antialiasingMode:SCNAntialiasingModeMultisampling4X];
            NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:[image TIFFRepresentation]];
            NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            NSString *out = [NSString stringWithFormat:@"%s/g_%03d.png", dir, i + 1];
            if (![png writeToFile:out atomically:YES])
            {
                std::fprintf(stderr, "Could not write %s\n", out.UTF8String);
                return 1;
            }
        }
    }
    std::fprintf(stderr, "Wrote %d frames to %s\n", count, dir);
    return 0;
}

int main(int argc, char **argv)
{
    const char *sequenceDir = nullptr;
    int sequenceCount = 18;
    double sequenceInterval = 0.5;
    NSSize sequenceSize = NSMakeSize(1185, 510);
    BOOL preview = NO;
    const char *snapshotPath = nullptr;
    const char *wallDir = nullptr;
    double wallTime = 6.0;
    for (int i = 1; i < argc; ++i)
    {
        if (std::strcmp(argv[i], "--preview") == 0)
            preview = YES;
        else if (std::strcmp(argv[i], "--snapshot") == 0 && i + 1 < argc)
            snapshotPath = argv[++i];
        else if (std::strcmp(argv[i], "--wall") == 0 && i + 1 < argc)
            wallDir = argv[++i];
        else if (std::strcmp(argv[i], "--at") == 0 && i + 1 < argc)
            wallTime = std::atof(argv[++i]);
        else if (std::strcmp(argv[i], "--garbage") == 0 && i + 1 < argc)
            return gibson_write_garbage(gibson_find_media(argv[0]), argv[++i]);
        else if (std::strcmp(argv[i], "--sequence") == 0 && i + 1 < argc)
            sequenceDir = argv[++i];
        else if (std::strcmp(argv[i], "--count") == 0 && i + 1 < argc)
            sequenceCount = std::atoi(argv[++i]);
        else if (std::strcmp(argv[i], "--interval") == 0 && i + 1 < argc)
            sequenceInterval = std::atof(argv[++i]);
        else if (std::strcmp(argv[i], "--size") == 0 && i + 2 < argc)
        {
            sequenceSize.width = std::atof(argv[++i]);
            sequenceSize.height = std::atof(argv[++i]);
        }
        else if (std::strcmp(argv[i], "--help") == 0 || std::strcmp(argv[i], "-h") == 0)
        {
            std::fprintf(stderr,
                         "Usage: %s [--preview] [--snapshot out.png] [--garbage dir]\n"
                         "       %s --sequence DIR [--count 18] [--interval 0.5] [--size 1185 510]\n"
                         "       %s --wall DIR [--at 6.0]   (multi-monitor slices vs. reference)\n",
                         argv[0], argv[0], argv[0]);
            return 0;
        }
    }

    @autoreleasepool
    {
        NSURL *media = gibson_find_media(argv[0]);
        if (!media)
        {
            std::fprintf(stderr, "Could not find media/. Run from the project root or src/.\n");
            return 1;
        }
        NSString *root = [[media path] stringByDeletingLastPathComponent];
        gibson_settings_reload(root.fileSystemRepresentation);

        [NSApplication sharedApplication];
        if (snapshotPath)
            return gibson_write_snapshot(media, snapshotPath);
        if (wallDir)
            return gibson_write_wall(media, wallDir, wallTime);
        if (sequenceDir)
            return gibson_write_sequence(media, sequenceDir, sequenceCount, sequenceInterval,
                                         sequenceSize);

        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        const NSRect frame = NSMakeRect(0, 0, 1280, 800);
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:frame
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                 NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        window.title = preview ? @"The Gibson (SceneKit preview)" : @"The Gibson (SceneKit)";
        window.releasedWhenClosed = NO;

        SCNView *view = [[SCNView alloc] initWithFrame:frame];
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [GibsonSCNScene configureView:view preview:preview mediaURL:media];
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
    }
    return 0;
}
