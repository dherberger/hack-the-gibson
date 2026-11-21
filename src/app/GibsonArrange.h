#ifndef GIBSON_ARRANGE_H_
#define GIBSON_ARRANGE_H_

#import <Cocoa/Cocoa.h>

/* "Arrange Displays" for the multi-monitor view: drag each display to where
 * its panel physically sits (in millimetres, bezels and gaps included) and set
 * how far it leans back, with an optional alignment pattern on the real
 * screens to judge the seams.
 * Positions are saved to config.txt as display_<UUID> lines. */
@interface GibsonArrangeController : NSObject <NSWindowDelegate>
/* The app's media folder. With it, the alignment pattern is drawn over a still
 * of the city rendered the way the screensaver would for the current layout. */
@property(nonatomic, strong) NSURL *media;
- (void)show;
- (void)close;
@end

#endif
