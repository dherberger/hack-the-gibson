#ifndef SCREEN_SAVER_PRIVATE_H_
#define SCREEN_SAVER_PRIVATE_H_

#import <AppKit/AppKit.h>
#import <ScreenSaver/ScreenSaver.h>

NS_ASSUME_NONNULL_BEGIN

/* These classes exist in ScreenSaver.framework but are not in the public
   headers. Declared from Apple's own screensaver appexes and
   AerialScreensaver/AppexSaverMinimal. */

@interface ScreenSaverExtension : NSObject
- (instancetype)init;
@end

/* Override only -loadView. The host forwards start/stopAnimation to the view
   (stopAnimation is not sent at session end) and reports resizes through
   -remoteViewSizeChanged:transaction:. */
@interface ScreenSaverViewController : NSViewController
- (void)startAnimation;
- (void)stopAnimation;
- (BOOL)remoteViewSizeChanged:(NSSize)size transaction:(nullable id)transaction;
@end

@interface ScreenSaverConfigurationViewController : NSViewController
@end

NS_ASSUME_NONNULL_END

#endif
