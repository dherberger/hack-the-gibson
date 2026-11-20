#import "GibsonScreenSaverExtension.h"

#include <unistd.h>

@implementation GibsonScreenSaverExtension

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        NSLog(@"The Gibson ScreenSaverExtension init pid=%d proc=%@",
              getpid(), [[NSProcessInfo processInfo] processName]);
    }
    return self;
}

@end
