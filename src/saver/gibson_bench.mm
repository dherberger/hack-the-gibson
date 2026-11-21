/* gibson_bench: runs the real screensaver view full screen on every display
 * for a while, then prints what it cost. Development only; `make bench`.
 *
 *   ./gibson_bench [--seconds 20] [--warmup 5]
 *
 * Settings come from config.txt as usual, so set render_scale etc. there.
 * Other switches: --bloom N, --mblur N, --hdr 0, --towers FRACTION,
 * --no-mirror, --no-pulses, --no-floor, --window-scale K; GIBSON_MIRROR_DIST
 * in the environment changes how far the floor reflection reaches.
 *
 * The GPU figure is the whole GPU's utilisation relative to its current clock,
 * which hides savings; for power, run alongside
 *   sudo powermetrics --samplers gpu_power -i 1000 */

#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>

#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <cstring>
#include <mach/mach.h>
#include <sys/resource.h>
#include <vector>

#import "GibsonSCNScene.h"
#import "GibsonSaverView.h"

static int gibson_gpu_utilisation(void)
{
    int result = -1;
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it)
        != KERN_SUCCESS)
        return -1;
    for (io_object_t svc; result < 0 && (svc = IOIteratorNext(it));)
    {
        CFDictionaryRef stats = (CFDictionaryRef)IORegistryEntryCreateCFProperty(
            svc, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
        if (stats)
        {
            CFNumberRef n = (CFNumberRef)CFDictionaryGetValue(stats, CFSTR("Device Utilization %"));
            if (n)
                CFNumberGetValue(n, kCFNumberIntType, &result);
            CFRelease(stats);
        }
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    return result;
}

static double gibson_cpu_seconds(void)
{
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    return ru.ru_utime.tv_sec + ru.ru_stime.tv_sec
        + (ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6;
}

static double gibson_footprint_mb(void)
{
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
        return 0;
    return info.phys_footprint / (1024.0 * 1024.0);
}

int main(int argc, char **argv)
{
    @autoreleasepool
    {
        double seconds = 20, warmup = 5, bloom = -1, mblur = -1, hdr = -1, towerFraction = 1;
        double windowScale = 1;
        bool noMirror = false, noPulses = false, noFloor = false;
        for (int i = 1; i < argc; ++i)
        {
            if (std::strcmp(argv[i], "--seconds") == 0 && i + 1 < argc)
                seconds = std::atof(argv[++i]);
            else if (std::strcmp(argv[i], "--warmup") == 0 && i + 1 < argc)
                warmup = std::atof(argv[++i]);
            else if (std::strcmp(argv[i], "--bloom") == 0 && i + 1 < argc)
                bloom = std::atof(argv[++i]);
            else if (std::strcmp(argv[i], "--mblur") == 0 && i + 1 < argc)
                mblur = std::atof(argv[++i]);
            else if (std::strcmp(argv[i], "--hdr") == 0 && i + 1 < argc)
                hdr = std::atof(argv[++i]);
            else if (std::strcmp(argv[i], "--towers") == 0 && i + 1 < argc)
                towerFraction = std::atof(argv[++i]);   // keep this fraction of towers
            else if (std::strcmp(argv[i], "--window-scale") == 0 && i + 1 < argc)
                windowScale = std::atof(argv[++i]);   // experiment: smaller windows
            else if (std::strcmp(argv[i], "--no-mirror") == 0)
                noMirror = true;
            else if (std::strcmp(argv[i], "--no-pulses") == 0)
                noPulses = true;
            else if (std::strcmp(argv[i], "--no-floor") == 0)
                noFloor = true;
        }
        setenv("GIBSON_NO_MUSIC", "1", 1);
        if (!std::getenv("GIBSON_MEDIA"))
        {
            NSString *exe = [[NSString stringWithUTF8String:argv[0]] stringByStandardizingPath];
            NSString *media = [[[exe stringByDeletingLastPathComponent]
                stringByAppendingPathComponent:@"../media"] stringByStandardizingPath];
            setenv("GIBSON_MEDIA", media.fileSystemRepresentation, 1);
        }

        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyAccessory;

        const int idleGPU = gibson_gpu_utilisation();
        NSMutableArray<NSWindow *> *windows = [NSMutableArray array];
        for (NSScreen *screen in [NSScreen screens])
        {
            NSWindow *w = [[NSWindow alloc] initWithContentRect:screen.frame
                                                      styleMask:NSWindowStyleMaskBorderless
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO
                                                         screen:screen];
            w.level = NSScreenSaverWindowLevel;
            w.releasedWhenClosed = NO;
            NSRect frame = screen.frame;
            frame.size.width = std::round(frame.size.width * windowScale);
            frame.size.height = std::round(frame.size.height * windowScale);
            [w setFrame:frame display:NO];
            GibsonSaverView *view = [[GibsonSaverView alloc] initWithFrame:NSMakeRect(0, 0,
                                                                                     frame.size.width,
                                                                                     frame.size.height)
                                                                 isPreview:NO];
            view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            w.contentView = view;
            [w orderFrontRegardless];
            [view startAnimation];
            [windows addObject:w];
        }

        __block double cpu0 = 0, t0 = 0;
        __block NSUInteger frames0 = 0;
        __block std::vector<int> gpu;
        GibsonSCNScene *world = [GibsonSCNScene sharedWorldForPreview:NO mediaURL:nil];
        /* Effect overrides, on every camera (each display has its own copy). */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            __block unsigned counter = 0;
            [world.scene.rootNode enumerateHierarchyUsingBlock:^(SCNNode *node, BOOL *stop) {
                if (noMirror && [node.name isEqualToString:@"tower-mirror"])
                    node.hidden = YES;
                if (noFloor && [node.name isEqualToString:@"room"])
                    node.hidden = YES;
                if (node.geometry && node.geometry.materials.count
                    && node.geometry.materials[0].blendMode == SCNBlendModeAdd && noPulses)
                    node.hidden = YES;
                /* Towers share two geometries; thin them evenly. */
                if (towerFraction < 1 && node.geometry && node.geometry.materials.count
                    && node.geometry.materials[0].shaderModifiers.count)
                {
                    const unsigned n = counter++;
                    if ((n * 7919u % 1000u) >= towerFraction * 1000)
                        node.hidden = YES;
                }
                SCNCamera *cam = node.camera;
                if (!cam)
                    return;
                if (bloom >= 0)
                    cam.bloomIntensity = bloom;
                if (mblur >= 0)
                    cam.motionBlurIntensity = mblur;
                if (hdr >= 0)
                    cam.wantsHDR = hdr != 0;
            }];
        });

        /* What SceneKit thinks each display can see. */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(warmup * NSEC_PER_SEC / 2)),
                       dispatch_get_main_queue(), ^{
            for (NSWindow *w in windows)
            {
                SCNView *scn = nil;
                for (NSView *sub in w.contentView.subviews)
                    if ([sub isKindOfClass:[SCNView class]])
                        scn = (SCNView *)sub;
                if (!scn)
                    continue;
                NSArray<SCNNode *> *in = [scn nodesInsideFrustumWithPointOfView:scn.pointOfView];
                int real = 0, mirror = 0, other = 0;
                for (SCNNode *n in in)
                {
                    BOOL isMirror = NO;
                    for (SCNNode *p = n.parentNode; p; p = p.parentNode)
                        if ([p.name isEqualToString:@"tower-mirror"])
                            isMirror = YES;
                    if (n.geometry.materials.firstObject.shaderModifiers.count && n.renderingOrder == 0)
                        ++real;
                    else if (isMirror)
                        ++mirror;
                    else
                        ++other;
                }
                std::printf("frustum %.0fx%.0f: %d towers, %d mirror towers, %d other\n",
                            w.frame.size.width, w.frame.size.height, real, mirror, other);
            }
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(warmup * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            cpu0 = gibson_cpu_seconds();
            t0 = CACurrentMediaTime();
            frames0 = world.renderedFrames;
        });
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            if (t0 > 0)
                gpu.push_back(gibson_gpu_utilisation());
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((warmup + seconds) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            const double dt = CACurrentMediaTime() - t0;
            const double cpu = (gibson_cpu_seconds() - cpu0) / dt * 100.0;
            const double fps = (world.renderedFrames - frames0) / dt;
            double g = 0;
            for (int v : gpu)
                g += v;
            g = gpu.empty() ? -1 : g / gpu.size();
            std::printf("CPU %.0f%% of a core  frames %.0f/s over %lu displays  "
                        "footprint %.0f MB  (system GPU %.0f%%, %d%% before)\n",
                        cpu, fps, (unsigned long)windows.count, gibson_footprint_mb(), g, idleGPU);
            std::fflush(stdout);
            for (NSWindow *w in windows)
                [(GibsonSaverView *)w.contentView stopAnimation];
            std::exit(0);
        });
        [app run];
    }
    return 0;
}
