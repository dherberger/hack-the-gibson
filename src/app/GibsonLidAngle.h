#ifndef GIBSON_LID_ANGLE_H_
#define GIBSON_LID_ANGLE_H_

#import <Foundation/Foundation.h>

/* The MacBook's hinge angle in degrees (0 closed, 90 square to the keyboard),
 * from the lid angle sensor recent MacBooks expose over HID. NO when this Mac
 * has no such sensor or it can't be read. */
BOOL gibson_lid_angle(double *degrees);

#endif
