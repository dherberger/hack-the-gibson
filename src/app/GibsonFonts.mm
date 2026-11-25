#import "GibsonFonts.h"

#import <CoreText/CoreText.h>

#include "gibson_settings.h"

static NSString *const kMichroma = @"Michroma-Regular";
static NSURL *g_media;

void gibson_fonts_set_media(NSURL *media)
{
    g_media = media;
}

/* PostScript names, best match first; Michroma last before the system font. */
static NSArray<NSString *> *gibson_candidates(GibsonFontRole role)
{
    if (role == GibsonFontList)
        return @[ @"EurostileExtended-Black", @"EurostileLTStd-BoldEx2", @"MicrogrammaD-BoldExte",
                  @"MicrogrammaD-ExtdBold", kMichroma ];
    return @[ @"MicrogrammaD-BoldExte", @"MicrogrammaD-ExtdBold", @"EurostileExtended-Black",
              @"EurostileLTStd-BoldEx2", kMichroma ];
}

static void gibson_register_dir(NSString *dir)
{
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil])
    {
        NSString *ext = name.pathExtension.lowercaseString;
        if (![ext isEqualToString:@"ttf"] && ![ext isEqualToString:@"otf"])
            continue;
        NSURL *url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:name]];
        CFErrorRef err = nullptr;
        if (!CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, &err) && err)
            CFRelease(err);   // already registered, or not a font: either way, carry on
    }
}

static void gibson_register_fonts(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Development: GIBSON_BUNDLED_FONTS_ONLY=1 shows what you get without your own fonts.
        if (!getenv("GIBSON_BUNDLED_FONTS_ONLY"))
            gibson_register_dir([[NSString stringWithUTF8String:gibson_user_dir()] stringByAppendingPathComponent:@"fonts"]);
        if (g_media)
            gibson_register_dir([g_media.path stringByAppendingPathComponent:@"fonts"]);
    });
}

static NSString *gibson_found_name(GibsonFontRole role)
{
    gibson_register_fonts();
    for (NSString *name in gibson_candidates(role))
        if ([NSFont fontWithName:name size:12])
            return name;
    return nil;
}

NSFont *gibson_film_font(GibsonFontRole role, CGFloat size, NSFontWeight weight)
{
    NSString *name = gibson_found_name(role);
    NSFont *font = name ? [NSFont fontWithName:name size:size] : nil;
    return font ?: [NSFont systemFontOfSize:size weight:weight width:NSFontWidthExpanded];
}

NSDictionary<NSAttributedStringKey, id> *gibson_film_font_extras(GibsonFontRole role)
{
    NSString *name = gibson_found_name(role);
    if (!name)
        return @{};
    if ([name isEqualToString:kMichroma])
        // Already wide; heavier for the list than for the menus.
        return @{ NSStrokeWidthAttributeName : @(role == GibsonFontList ? -5.0 : -2.5) };
    return @{ NSExpansionAttributeName : @(role == GibsonFontList ? 0.12 : 0.08) };
}

NSDictionary<NSAttributedStringKey, id> *gibson_with_extras(NSDictionary<NSAttributedStringKey, id> *attrs,
                                                            GibsonFontRole role)
{
    NSMutableDictionary *all = [attrs mutableCopy];
    [all addEntriesFromDictionary:gibson_film_font_extras(role)];
    return all;
}
