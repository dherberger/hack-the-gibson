#ifndef GIBSON_GAME_H_
#define GIBSON_GAME_H_

#import <Cocoa/Cocoa.h>

/* "Hack The Gibson": the flythrough as a game, full screen on the primary
 * display. A small title menu sits in the lower right (Start Game, Options,
 * Exit); once started the player steers the camera through the street grid
 * and can type a word (default "garbage") to show the garbage file.
 * Key bindings live in config.txt (key_left, key_right, ..., garbage_word). */
@interface GibsonGameController : NSObject

- (instancetype)initWithMediaURL:(NSURL *)media;
- (void)start;
/* Called after the game window closes (Exit, Escape). */
@property (nonatomic, copy) void (^onExit)(void);

@end

#endif
