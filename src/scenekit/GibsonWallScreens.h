#ifndef GIBSON_WALL_SCREENS_H_
#define GIBSON_WALL_SCREENS_H_

#import <AppKit/AppKit.h>

#include <vector>

#include "GibsonWall.h"

/* The config.txt key holding a display's hand-placed position
 * ("display_<UUID> = cx cy tilt": its centre on the wall in mm and how
 * far it leans back in degrees), or nil. The UUID
 * tells two monitors of the same model apart. */
NSString *gibson_display_key(NSScreen *screen);

/* The attached displays in [NSScreen screens] order, with their physical
 * sizes and any saved positions from the loaded settings. */
std::vector<GibsonWallScreen> gibson_wall_screens(void);

#endif
