#ifndef GIBSON_SETTINGS_H_
#define GIBSON_SETTINGS_H_

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GibsonSettings {
    float fly_speed;
    float bank_strength;
    float bank_max_degrees;
    float bank_smoothing;
    float music_volume;
    int music_enabled;
    int span_displays;
} GibsonSettings;

/* extra_dir is searched for config.txt (saver Resources, project root, …). */
void gibson_settings_reload(const char *extra_dir);
GibsonSettings gibson_settings(void);
float gibson_fly_speed(void);
float gibson_bank_strength(void);
float gibson_bank_max_degrees(void);
float gibson_bank_smoothing(void);
/* With several displays: 1 to treat them as windows onto one shared view. */
int gibson_span_displays(void);
/* Any `key = value` line from the loaded config.txt as written, or "" when
 * absent. Used for per-display keys that aren't known ahead of time. */
const char *gibson_settings_raw(const char *key);
const char *gibson_settings_path(void);
/* Music played on a loop while the screensaver runs: an absolute path, or ""
 * when disabled (`music_enabled = no` or `music = off`). The file may be
 * missing; callers check. */
const char *gibson_music_path(void);
float gibson_music_volume(void);
int gibson_music_enabled(void);
/* The `music` value as written in config.txt (usually a bare file name). */
const char *gibson_music_setting(void);
/* ~/Library/Application Support/TheGibson: config.txt and the music file. */
const char *gibson_user_dir(void);
/* Writes `key = value` into the user's config.txt, replacing the key's line
 * or appending it, and keeping comments. Returns 1 on success. Call
 * gibson_settings_reload() afterwards to read it back. */
int gibson_settings_set(const char *key, const char *value);

#ifdef __cplusplus
}
#endif

#endif
