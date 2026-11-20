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
} GibsonSettings;

/* extra_dir is searched for config.txt (saver Resources, project root, …). */
void gibson_settings_reload(const char *extra_dir);
GibsonSettings gibson_settings(void);
float gibson_fly_speed(void);
float gibson_bank_strength(void);
float gibson_bank_max_degrees(void);
float gibson_bank_smoothing(void);
const char *gibson_settings_path(void);
/* Music played on a loop while the screensaver runs: an absolute path, or ""
 * when disabled (`music = off`). The file may be missing; callers check. */
const char *gibson_music_path(void);
float gibson_music_volume(void);

#ifdef __cplusplus
}
#endif

#endif
