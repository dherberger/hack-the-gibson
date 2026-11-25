#ifndef GIBSON_SFX_H_
#define GIBSON_SFX_H_

#import <Foundation/Foundation.h>

/* The garbage file's sound effects, synthesized (nothing sampled), after
 * measurements of the film's:
 *   select  0.42 s: 11 gated bursts (17 ms on, every 40 ms) of an inharmonic
 *           chord at ~1.8 / 4.4 / 4.6 / 5.3 / 5.9 / 8.9 kHz
 *   pulse   a higher gated chord (~4.1 / 6.2 / 7.0 / 7.9 kHz) on each lit
 *           half of the blink
 * Safe to call from any thread. Volume: `sfx_volume` in config.txt (0-1,
 * default 0.6). */
@interface GibsonSFX : NSObject

+ (instancetype)shared;
- (void)start;
- (void)stop;
- (void)select;
- (void)pulse;
/* Development: write each sound as a WAV file into dir. */
+ (void)writeSoundsTo:(NSString *)dir;

@end

#endif
