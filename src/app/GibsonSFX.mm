#import "GibsonSFX.h"

#import <AVFoundation/AVFoundation.h>

#include <cmath>
#include <cstdlib>
#include <vector>

#include "gibson_settings.h"

static const double kRate = 48000;

struct GibsonPartial {
    double hz, amp;
};

static AVAudioPCMBuffer *gibson_buffer(AVAudioFormat *fmt, const std::vector<float> &samples)
{
    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt
                                                          frameCapacity:(AVAudioFrameCount)samples.size()];
    buf.frameLength = (AVAudioFrameCount)samples.size();
    std::copy(samples.begin(), samples.end(), buf.floatChannelData[0]);
    return buf;
}

static void gibson_normalize(std::vector<float> &s, float peak)
{
    float m = 0;
    for (float v : s)
        m = std::max(m, std::fabs(v));
    if (m > 0)
        for (float &v : s)
            v *= peak / m;
}

/* A burst gate with raised-cosine edges, so the bursts don't click or
   smear across the spectrum. */
static double gibson_gate(double t, double start, double length, double edge = 0.0025)
{
    const double u = t - start;
    if (u < 0 || u > length)
        return 0;
    if (u < edge)
        return 0.5 - 0.5 * std::cos(M_PI * u / edge);
    if (u > length - edge)
        return 0.5 - 0.5 * std::cos(M_PI * (length - u) / edge);
    return 1;
}

static std::vector<float> gibson_chord(double seconds, const std::vector<GibsonPartial> &partials,
                                       double (^gate)(double t, size_t partial))
{
    const int n = int(seconds * kRate);
    std::vector<float> s(n, 0.f);
    for (size_t p = 0; p < partials.size(); ++p)
    {
        const double phase = arc4random_uniform(1000) / 1000.0 * 2 * M_PI;
        for (int i = 0; i < n; ++i)
        {
            const double t = i / kRate;
            const double g = gate(t, p);
            if (g > 0)
                s[i] += float(partials[p].amp * g * std::sin(2 * M_PI * partials[p].hz * t + phase));
        }
    }
    return s;
}

/* Select: a 25 Hz trill between two square-ish beeps, 20 ms each: 1755 Hz
   (with its odd harmonics at 5.27, 8.86 and 12.3 kHz) and 4547 Hz (with its
   third, 13.6 kHz). 0.42 s, starting on the low beep. Measured from a clean
   capture of the film's sound. */
static std::vector<float> gibson_select(void)
{
    const std::vector<GibsonPartial> partials = {
        { 1755, 1.0 }, { 5265, 0.15 }, { 8859, 0.08 }, { 12285, 0.06 },   // low beep
        { 4547, 0.6 }, { 13641, 0.07 },                                  // high beep
    };
    const double length = 0.42, half = 0.020;
    std::vector<float> s = gibson_chord(length, partials, ^double(double t, size_t p) {
        const bool high = p >= 4;
        double g = 0;
        for (int k = 0; k * half < length; ++k)
            if ((k % 2 == 1) == high)
                g += gibson_gate(t, k * half, half, 0.001);
        // Each beep dips rather than stops while the other sounds.
        return gibson_gate(t, 0, length, 0.002) * (0.3 + 0.7 * std::min(1.0, g));
    });
    gibson_normalize(s, 0.45f);
    return s;
}

/* Pulse, one per lit half of the blink (~0.45 s), as measured:
     0-0.11 s     7934 Hz in bursts (20 ms on, every 34 ms) over a steady 4300
     0.05-0.32 s  a sustained 7043 Hz carrying it, fading out
     0.08-0.17 s  a short 3064 Hz
     0.11-0.42 s  6117 Hz bursts (18 ms on, every 34 ms) with 2432 Hz bursts
                  12 ms ahead of them */
static std::vector<float> gibson_pulse(void)
{
    const std::vector<GibsonPartial> partials = {
        { 7934, 0.74 }, { 4300, 0.16 }, { 7043, 1.0 }, { 3064, 0.16 }, { 6117, 0.3 }, { 2432, 0.16 },
    };
    const double length = 0.45, period = 0.034;
    std::vector<float> s = gibson_chord(length, partials, ^double(double t, size_t p) {
        double g = 0;
        switch (p)
        {
        case 0:
            for (int k = 0; k < 4; ++k)
                g += gibson_gate(t, k * period, 0.020, 0.0015);
            return gibson_gate(t, 0, 4 * period, 0.002) * (0.35 + 0.65 * std::min(1.0, g));
        case 1:
            return gibson_gate(t, 0, 0.11, 0.004);
        case 2:
            return gibson_gate(t, 0.05, 0.27, 0.006) * (1.0 - 0.5 * std::max(0.0, t - 0.05) / 0.27);
        case 3:
            return gibson_gate(t, 0.08, 0.09, 0.004);
        default:
        {
            const double lead = (p == 5) ? -0.012 : 0.0;
            for (int k = 0; 0.11 + k * period < 0.42; ++k)
                g += gibson_gate(t, 0.11 + k * period + lead, 0.018, 0.0015);
            return gibson_gate(t, 0.11 + lead, 0.31, 0.002) * (0.35 + 0.65 * std::min(1.0, g));
        }
        }
    });
    gibson_normalize(s, 0.4f);
    return s;
}

static void gibson_write_wav(NSString *path, const std::vector<float> &s)
{
    AVAudioFormat *fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kRate channels:1];
    NSDictionary *settings = @{ AVFormatIDKey : @(kAudioFormatLinearPCM), AVSampleRateKey : @(kRate),
                                AVNumberOfChannelsKey : @1, AVLinearPCMBitDepthKey : @16 };
    AVAudioFile *file = [[AVAudioFile alloc] initForWriting:[NSURL fileURLWithPath:path] settings:settings
                                               commonFormat:AVAudioPCMFormatFloat32 interleaved:NO error:nil];
    [file writeFromBuffer:gibson_buffer(fmt, s) error:nil];
}

@implementation GibsonSFX
{
    dispatch_queue_t _queue;
    AVAudioEngine *_engine;
    AVAudioFormat *_format;
    AVAudioPlayerNode *_selectNode, *_pulseNode;
    AVAudioPCMBuffer *_select, *_pulse;
    float _volume;
    BOOL _running;
}

+ (instancetype)shared
{
    static GibsonSFX *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[GibsonSFX alloc] init];
    });
    return shared;
}

+ (void)writeSoundsTo:(NSString *)dir
{
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    gibson_write_wav([dir stringByAppendingPathComponent:@"select.wav"], gibson_select());
    gibson_write_wav([dir stringByAppendingPathComponent:@"pulse.wav"], gibson_pulse());
}

- (instancetype)init
{
    self = [super init];
    if (!self)
        return nil;
    _queue = dispatch_queue_create("org.hackthegibson.sfx", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)start
{
    dispatch_async(_queue, ^{
        if (self->_running)
            return;
        NSString *v = [NSString stringWithUTF8String:gibson_settings_raw("sfx_volume")];
        self->_volume = v.length ? std::max(0.f, std::min(1.f, v.floatValue)) : 0.6f;
        if (self->_volume <= 0)
            return;
        if (!self->_engine)
        {
            self->_format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kRate channels:1];
            self->_select = gibson_buffer(self->_format, gibson_select());
            self->_pulse = gibson_buffer(self->_format, gibson_pulse());

            self->_engine = [[AVAudioEngine alloc] init];
            self->_selectNode = [[AVAudioPlayerNode alloc] init];
            self->_pulseNode = [[AVAudioPlayerNode alloc] init];
            for (AVAudioPlayerNode *node in @[ self->_selectNode, self->_pulseNode ])
            {
                [self->_engine attachNode:node];
                [self->_engine connect:node to:self->_engine.mainMixerNode format:self->_format];
            }
        }
        NSError *err = nil;
        if (![self->_engine startAndReturnError:&err])
        {
            NSLog(@"The Gibson: sound effects off (%@)", err.localizedDescription);
            return;
        }
        [self->_selectNode play];
        [self->_pulseNode play];
        self->_running = YES;
    });
}

- (void)stop
{
    dispatch_async(_queue, ^{
        if (!self->_running)
            return;
        [self->_selectNode stop];
        [self->_pulseNode stop];
        [self->_engine stop];
        self->_running = NO;
    });
}

- (void)select
{
    dispatch_async(_queue, ^{
        if (!self->_running)
            return;
        self->_selectNode.volume = self->_volume;
        [self->_selectNode scheduleBuffer:self->_select atTime:nil
                                  options:AVAudioPlayerNodeBufferInterrupts completionHandler:nil];
    });
}

- (void)pulse
{
    dispatch_async(_queue, ^{
        if (!self->_running)
            return;
        self->_pulseNode.volume = self->_volume * 0.8f;
        [self->_pulseNode scheduleBuffer:self->_pulse atTime:nil
                                 options:AVAudioPlayerNodeBufferInterrupts completionHandler:nil];
    });
}

@end
