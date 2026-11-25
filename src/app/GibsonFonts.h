#ifndef GIBSON_FONTS_H_
#define GIBSON_FONTS_H_

#import <AppKit/AppKit.h>

/* The film's lettering is a stretched Eurostile / Microgramma Extended.
 * Both are commercial fonts and don't ship with The Gibson. In order:
 *   1. your own copies (.ttf / .otf) in
 *      ~/Library/Application Support/TheGibson/fonts/
 *   2. Michroma, a free (SIL OFL) Microgramma lookalike in media/fonts/
 *   3. the system font, expanded.
 * Fonts are registered for this process only, never installed. */
typedef NS_ENUM(int, GibsonFontRole) {
    GibsonFontList,   // directory list and file panel: Eurostile Extended Black
    GibsonFontUI,     // title and options menus: Microgramma D Bold Extended
};

/* Where the bundled fonts live (the app's media folder); call before the
 * first gibson_film_font. */
void gibson_fonts_set_media(NSURL *media);
/* weight only matters for the system-font fallback. */
NSFont *gibson_film_font(GibsonFontRole role, CGFloat size, NSFontWeight weight);
/* Attributes that go with the font: extra stretch (the film's lettering is
 * wider still than the extended cuts) and, for Michroma's single regular
 * weight, a fill-and-stroke to thicken it. */
NSDictionary<NSAttributedStringKey, id> *gibson_film_font_extras(GibsonFontRole role);
/* attrs plus gibson_film_font_extras(role). */
NSDictionary<NSAttributedStringKey, id> *gibson_with_extras(NSDictionary<NSAttributedStringKey, id> *attrs,
                                                            GibsonFontRole role);

#endif
