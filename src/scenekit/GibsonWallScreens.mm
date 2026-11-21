#import "GibsonWallScreens.h"

#import <ColorSync/ColorSync.h>

#include <cstdio>

#include "gibson_settings.h"

NSString *gibson_display_key(NSScreen *screen)
{
    NSNumber *num = screen.deviceDescription[@"NSScreenNumber"];
    if (!num)
        return nil;
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID((CGDirectDisplayID)num.unsignedIntValue);
    if (!uuid)
        return nil;
    NSString *text = CFBridgingRelease(CFUUIDCreateString(kCFAllocatorDefault, uuid));
    CFRelease(uuid);
    return [@"display_" stringByAppendingString:text];
}

std::vector<GibsonWallScreen> gibson_wall_screens(void)
{
    std::vector<GibsonWallScreen> out;
    for (NSScreen *s in [NSScreen screens])
    {
        const NSRect f = s.frame;
        NSNumber *num = s.deviceDescription[@"NSScreenNumber"];
        const CGSize mm = num ? CGDisplayScreenSize((CGDirectDisplayID)num.unsignedIntValue)
                              : CGSizeZero;
        GibsonWallScreen w{f.origin.x, f.origin.y, f.size.width, f.size.height,
                           mm.width, mm.height, false, 0, 0, 0, 0};
        /* display_<UUID> = centre x, centre y (mm), tilt, swivel (degrees) */
        NSString *key = gibson_display_key(s);
        double cx = 0, cy = 0, tilt = 0, swivel = 0;
        const int got = key ? std::sscanf(gibson_settings_raw(key.UTF8String), "%lf %lf %lf %lf",
                                          &cx, &cy, &tilt, &swivel)
                            : 0;
        if (got >= 2)
        {
            w.placed = true;
            w.cx = cx;
            w.cy = cy;
            if (got >= 3 && tilt > -80 && tilt < 80)
                w.tiltDeg = tilt;
            if (got >= 4 && swivel > -80 && swivel < 80)
                w.swivelDeg = swivel;
        }
        out.push_back(w);
    }
    return out;
}
