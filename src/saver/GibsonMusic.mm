#import "GibsonMusic.h"

#import <AVFoundation/AVFoundation.h>
#include <os/log.h>

#include "gibson_settings.h"

static const NSTimeInterval kFadeIn = 2.0;
static const NSTimeInterval kFadeOut = 1.2;

static os_log_t gibson_music_log(void)
{
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("org.hackthegibson.TheGibson", "music");
    });
    return log;
}

@implementation GibsonMusic
{
    AVAudioPlayer *_player;
    NSString *_loadedPath;
    NSInteger _activeViews;
    NSUInteger _generation;   // bumps on every start/stop, so a stale fade-out
                              // can't stop a session that started since
}

+ (instancetype)shared
{
    static GibsonMusic *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[GibsonMusic alloc] init];
    });
    return shared;
}

- (BOOL)loadPlayer
{
    const char *cpath = gibson_music_path();
    if (!cpath || !cpath[0])
    {
        os_log(gibson_music_log(), "The Gibson music: off");
        _player = nil;
        _loadedPath = nil;
        return NO;
    }
    NSString *path = [NSString stringWithUTF8String:cpath];
    if (_player && [path isEqualToString:_loadedPath])
        return YES;

    if (![[NSFileManager defaultManager] isReadableFileAtPath:path])
    {
        os_log(gibson_music_log(), "The Gibson music: no readable file at %{public}@", path);
        _player = nil;
        _loadedPath = nil;
        return NO;
    }
    NSError *err = nil;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path]
                                                                   error:&err];
    if (!player)
    {
        os_log(gibson_music_log(), "The Gibson music: can't play %{public}@: %{public}@",
               path, err.localizedDescription);
        _player = nil;
        _loadedPath = nil;
        return NO;
    }
    player.numberOfLoops = -1;   // loop forever
    [player prepareToPlay];
    _player = player;
    _loadedPath = path;
    os_log(gibson_music_log(), "The Gibson music: loaded %{public}@ (%.0f s)", path, player.duration);
    return YES;
}

- (void)viewDidStart
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_activeViews += 1;
        if (self->_activeViews != 1)
            return;
        self->_generation += 1;
        if (![self loadPlayer])
            return;
        // Each session starts the track from the top.
        AVAudioPlayer *p = self->_player;
        [p stop];
        p.currentTime = 0;
        p.volume = 0;
        [p play];
        [p setVolume:gibson_music_volume() fadeDuration:kFadeIn];
        os_log(gibson_music_log(), "The Gibson music: play (volume %.2f)", gibson_music_volume());
    });
}

- (void)viewDidStop
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_activeViews == 0)
            return;
        self->_activeViews -= 1;
        if (self->_activeViews != 0)
            return;
        self->_generation += 1;
        AVAudioPlayer *p = self->_player;
        if (!p.playing)
            return;
        const NSUInteger gen = self->_generation;
        [p setVolume:0 fadeDuration:kFadeOut];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFadeOut * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (self->_generation == gen && self->_activeViews == 0)
            {
                [p stop];
                os_log(gibson_music_log(), "The Gibson music: stopped");
            }
        });
    });
}

@end
