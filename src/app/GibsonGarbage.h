#ifndef GIBSON_GARBAGE_H_
#define GIBSON_GARBAGE_H_

#import <SceneKit/SceneKit.h>
#import <simd/simd.h>

/* "Show the garbage file": a column of directory names on a tower face, as in
 * the film. It scrolls (names moving down, about 8 lines a second), slows to a
 * stop with a GARBAGE entry on the ninth line, then GARBAGE turns blue, the
 * CONFIDENTIAL FILES panel opens beside it box by box, and the selection and
 * panel blink together.
 *
 * Everything but -init runs on SceneKit's render thread (from the game's
 * camera driver). */
@interface GibsonGarbageColumn : NSObject

/* Width of the column in city units; its height follows the texture. */
+ (float)heightForWidth:(float)width;

@property (nonatomic, readonly) SCNNode *node;
/* True once a fade-out has finished; the node has left the scene. */
@property (nonatomic, readonly) BOOL finished;
/* True once the file is open (panel shown): the sequence has played out. */
@property (nonatomic, readonly) BOOL fileOpen;

/* center: middle of the column, just off the tower face. normal: the face's
 * outward direction (horizontal). City coordinates. */
- (instancetype)initWithParent:(SCNNode *)parent
                        center:(simd_float3)center
                        normal:(simd_float3)normal
                         width:(float)width
                          time:(NSTimeInterval)time;
/* Darken the tower face behind the column: a plate `width` x `height`,
 * centred `offsetY` above the column's centre. */
- (void)darkenFaceWidth:(float)width height:(float)height offsetY:(float)offsetY;
/* The column starts hidden (it scrolls all the same); show it, fading in. */
@property (nonatomic, readonly) BOOL revealed;
- (void)revealAtTime:(NSTimeInterval)time;
/* Begin slowing down; the column settles on GARBAGE shortly after. */
- (void)stopAtTime:(NSTimeInterval)time;
- (void)fadeOutAtTime:(NSTimeInterval)time;
- (void)updateAtTime:(NSTimeInterval)time;

@end

#endif
