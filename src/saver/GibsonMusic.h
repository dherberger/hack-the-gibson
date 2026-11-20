#ifndef GIBSON_MUSIC_H_
#define GIBSON_MUSIC_H_

#import <Foundation/Foundation.h>

/* One looping music player per process, shared by every screensaver view
 * (one per display). Views call -viewDidStart / -viewDidStop; the track fades
 * in when the first view starts and fades out when the last one stops. The
 * file and volume come from config.txt (`music`, `music_volume`). */
@interface GibsonMusic : NSObject

+ (instancetype)shared;
- (void)viewDidStart;
- (void)viewDidStop;

@end

#endif
