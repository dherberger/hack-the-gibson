#import "GibsonLidAngle.h"

#import <IOKit/hid/IOHIDManager.h>

/* The sensor is a HID device on the Sensor usage page (0x20) with usage 0x8A.
 * Feature report 1 is three bytes: the report ID, then the angle as a
 * little-endian 16-bit count of degrees. (Read on a MacBook Pro, macOS 27.2;
 * undocumented, so anything unexpected is treated as "no sensor".) */
BOOL gibson_lid_angle(double *degrees)
{
    IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!manager)
        return NO;
    NSDictionary *match = @{ @kIOHIDPrimaryUsagePageKey : @0x20, @kIOHIDPrimaryUsageKey : @0x8A };
    IOHIDManagerSetDeviceMatching(manager, (__bridge CFDictionaryRef)match);
    BOOL found = NO;
    if (IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone) == kIOReturnSuccess)
    {
        NSSet *devices = CFBridgingRelease(IOHIDManagerCopyDevices(manager));
        for (id object in devices)
        {
            IOHIDDeviceRef device = (__bridge IOHIDDeviceRef)object;
            if (IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone) != kIOReturnSuccess)
                continue;
            uint8_t report[8] = {0};
            CFIndex length = sizeof(report);
            const IOReturn result =
                IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, report, &length);
            IOHIDDeviceClose(device, kIOHIDOptionsTypeNone);
            if (result != kIOReturnSuccess || length < 3)
                continue;
            const int angle = report[1] | (report[2] << 8);
            if (angle < 1 || angle > 200)
                continue;
            *degrees = angle;
            found = YES;
            break;
        }
        IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
    }
    CFRelease(manager);
    return found;
}
