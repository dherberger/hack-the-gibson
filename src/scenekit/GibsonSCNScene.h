#ifndef GIBSON_SCN_SCENE_H_
#define GIBSON_SCN_SCENE_H_

#import <SceneKit/SceneKit.h>

/* Takes over the camera from the flythrough (game mode). Called once per
 * frame on SceneKit's render thread, with the camera in the city's own
 * (Irrlicht, left-handed) coordinates: the same space as the flight path and
 * the tower grid. Return NO to let the flythrough move the camera this frame. */
@protocol GibsonCameraDriver <NSObject>
- (BOOL)driveCamera:(SCNNode *)camera atTime:(NSTimeInterval)time delta:(float)delta;
@end

@interface GibsonSCNScene : NSObject <SCNSceneRendererDelegate>

@property (nonatomic, readonly) SCNScene *scene;
@property (nonatomic, readonly) SCNNode *cameraNode;
@property (nonatomic, readonly) BOOL preview;
/* Parent of the towers and the camera, in city coordinates. Nodes added here
 * line up with the tower grid (see GibsonCity.h). */
@property (nonatomic, readonly) SCNNode *worldRoot;
@property (nonatomic, weak) id<GibsonCameraDriver> cameraDriver;
/* The tower standing at (x, z), city coordinates (not its reflection), or nil. */
- (SCNNode *)towerNodeAtX:(float)x z:(float)z;

+ (instancetype)sharedWorldForPreview:(BOOL)preview mediaURL:(NSURL *)mediaURL;
+ (void)configureView:(SCNView *)view preview:(BOOL)preview mediaURL:(NSURL *)mediaURL;
- (void)tickAtTime:(NSTimeInterval)time;
/* Frames drawn by all views showing this world, for benchmarking. */
@property (nonatomic, readonly) NSUInteger renderedFrames;

/* Multi-monitor spanning (see GibsonWall.h). A view camera rides the shared
 * fly camera; give it the projection and orientation for the display it is
 * shown on (the orientation is identity unless the display is tilted). */
- (SCNNode *)makeViewCameraNode;
+ (BOOL)wallProjection:(SCNMatrix4 *)outProjection
           orientation:(simd_quatf *)outOrientation
             forScreen:(NSScreen *)screen;
/* For offscreen checks: the screen's rect within the wall's bounding box
 * (0..1, y up), and a projection covering that whole box. */
+ (NSRect)wallUnitRectForScreen:(NSScreen *)screen;
+ (BOOL)wallBoundsProjection:(SCNMatrix4 *)outProjection aspect:(CGFloat *)outAspect;
- (void)resetClock;
/* Puts the flight at `time` seconds in, on a clock that starts at zero; carry
 * on with tickAtTime: from there. */
- (void)seekToTime:(NSTimeInterval)time;

@end

#endif
