#ifndef GIBSON_SFX_H_
#define GIBSON_SFX_H_

#import <Foundation/Foundation.h>

/* The garbage file's sound effects, synthesized (nothing sampled), after
 * measurements of the film's:
 *   select  0.42 s: a harsh 25 Hz trill between ~1.8 and ~4.5 kHz beeps
 *   pulse   a higher gated chord (~2.4-7.9 kHz), ~0.83 s, on each lit half
 *           of the blink
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
