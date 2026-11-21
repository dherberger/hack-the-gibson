#ifndef GIBSON_SCN_CAMERA_H_
#define GIBSON_SCN_CAMERA_H_

#import <SceneKit/SceneKit.h>

#define GIBSON_CAM_Z_NEAR 0.5
#define GIBSON_CAM_Z_FAR 900.0

@interface GibsonSCNCamera : NSObject

@property (nonatomic, readonly) SCNNode *cameraNode;
@property (nonatomic, readonly) SCNNode *lookAtNode;

- (instancetype)initWithRoot:(SCNNode *)root;
- (void)updateAtTime:(NSTimeInterval)time startTime:(NSTimeInterval)startTime;
/* Forget the banking history, before jumping to another point in the flight. */
- (void)resetSmoothing;

/* Seconds for one full pass over the flythrough, out and back. */
+ (NSTimeInterval)loopDuration;
/* Distinct stretches of the flight (rooftop swoop, turns, straight runs), as
 * @{@"time": seconds into the flight, @"name": description}, in time order. */
+ (NSArray<NSDictionary *> *)flightMoments;

@end

#endif
