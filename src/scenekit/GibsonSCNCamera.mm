#import "GibsonSCNCamera.h"

#include "fly_path.h"
#include "gibson_settings.h"

#include <algorithm>
#include <cmath>
#include <vector>

#import <simd/simd.h>

@implementation GibsonSCNCamera
{
    float _bank;
    float _yawRate;
    float _lastElapsedMs;
}

static int gibson_clamp_wrap(int idx, int size)
{
    if (idx < 0)
        return size + idx;
    if (idx >= size)
        return idx - size;
    return idx;
}

/* Fly low like the film (camera ~1/6 of tower height): squash the authored
 * path height (6-30 units) down to ~4-11, but blend back to the original
 * height for the rooftop swoop (y > ~46), which crosses tower footprints. */
#define GIBSON_CAM_LOW_BASE 4.f
#define GIBSON_CAM_LOW_SCALE 0.3f
#define GIBSON_CAM_PATH_MIN_Y 6.4f

static float gibson_low_flight_y(float y)
{
    const float low = GIBSON_CAM_LOW_BASE + (y - GIBSON_CAM_PATH_MIN_Y) * GIBSON_CAM_LOW_SCALE;
    float t = std::max(0.f, std::min(1.f, (y - 28.f) / (46.f - 28.f)));
    t = t * t * (3.f - 2.f * t);
    return low + (y - low) * t;
}

static SCNVector3 gibson_spline_at_raw(float dt);

static SCNVector3 gibson_spline_at(float dt)
{
    SCNVector3 p = gibson_spline_at_raw(dt);
    p.y = gibson_low_flight_y((float)p.y);
    return p;
}

/* The authored path is a closed loop: its last two waypoints repeat the first.
 * Fly it round and round over the unique ones. (It used to ping-pong, which
 * turned the camera around end to end every pass: the look-at point reversed
 * before the camera did.) */
static const int kLoopPoints = GIBSON_FLY_PATH_COUNT - 2;

/* Rooftop swoop: where on the path (in waypoint units) the climb tops out
 * over the city. */
static const float kSwoopTopDt = 16.5f;

static SCNVector3 gibson_spline_at_raw(float dt)
{
    const int pSize = kLoopPoints;
    const float fl = std::floor(dt);
    int idx = (int)fl % pSize;
    if (idx < 0)
        idx += pSize;
    const float u = dt - fl;

    const int i0 = gibson_clamp_wrap(idx - 1, pSize);
    const int i1 = gibson_clamp_wrap(idx + 0, pSize);
    const int i2 = gibson_clamp_wrap(idx + 1, pSize);
    const int i3 = gibson_clamp_wrap(idx + 2, pSize);

    const float h1 = 2.f * u * u * u - 3.f * u * u + 1.f;
    const float h2 = -2.f * u * u * u + 3.f * u * u;
    const float h3 = u * u * u - 2.f * u * u + u;
    const float h4 = u * u * u - u * u;
    const float tightness = GIBSON_FLY_TIGHTNESS;

    auto pt = [](int i) {
        return SCNVector3Make(GIBSON_FLY_PATH[i][0], GIBSON_FLY_PATH[i][1], GIBSON_FLY_PATH[i][2]);
    };

    const SCNVector3 p0 = pt(i0);
    const SCNVector3 p1 = pt(i1);
    const SCNVector3 p2 = pt(i2);
    const SCNVector3 p3 = pt(i3);

    const SCNVector3 t1 = SCNVector3Make(
        (p2.x - p0.x) * tightness,
        (p2.y - p0.y) * tightness,
        (p2.z - p0.z) * tightness);
    const SCNVector3 t2 = SCNVector3Make(
        (p3.x - p1.x) * tightness,
        (p3.y - p1.y) * tightness,
        (p3.z - p1.z) * tightness);

    return SCNVector3Make(
        p1.x * h1 + p2.x * h2 + t1.x * h3 + t2.x * h4,
        p1.y * h1 + p2.y * h2 + t1.y * h3 + t2.y * h4,
        p1.z * h1 + p2.z * h2 + t1.z * h3 + t2.z * h4);
}

/* Where on the path the flight starts, so the rooftop swoop lands at
 * `swoop_at` seconds into the session (default 33 s, a cue in the Hackers
 * suite; the music starts with the session). `swoop_at = off` starts at the
 * first waypoint, as the original did. */
static float gibson_path_offset(float speed)
{
    NSString *v = [NSString stringWithUTF8String:gibson_settings_raw("swoop_at")].lowercaseString;
    if ([v isEqualToString:@"off"] || [v isEqualToString:@"no"] || [v isEqualToString:@"none"])
        return 0.f;
    const double at = v.length ? v.doubleValue : 33.0;
    return kSwoopTopDt - (float)(std::max(0.0, at) * speed);
}

static simd_float3 gibson_v(SCNVector3 p)
{
    return simd_make_float3((float)p.x, (float)p.y, (float)p.z);
}

static simd_float3 gibson_safe_norm(simd_float3 v, simd_float3 fallback)
{
    const float len = simd_length(v);
    if (len < 1e-5f)
        return fallback;
    return v / len;
}

- (instancetype)initWithRoot:(SCNNode *)root
{
    self = [super init];
    if (!self)
        return nil;

    _bank = 0.f;
    _yawRate = 0.f;
    _lastElapsedMs = -1.f;

    _lookAtNode = [SCNNode node];
    _lookAtNode.name = @"gibson-lookat";
    [root addChildNode:_lookAtNode];

    SCNCamera *cam = [SCNCamera camera];
    cam.fieldOfView = 72.0;
    cam.zNear = GIBSON_CAM_Z_NEAR;
    cam.zFar = GIBSON_CAM_Z_FAR;
    /* Movie grade: saturated cyan/violet with heavy glow and streaky motion.
       HDR lets materials push past 1.0 so only the bright traces, tower caps
       and pulses cross the bloom threshold. */
    cam.wantsHDR = YES;
    cam.wantsExposureAdaptation = NO;
    cam.exposureOffset = 0.0;
    cam.minimumExposure = 0.0;
    cam.maximumExposure = 0.0;
    cam.bloomThreshold = 0.9;
    cam.bloomIntensity = 1.3;
    cam.bloomBlurRadius = 18.0;
    cam.saturation = 1.35;
    cam.contrast = 0.12;
    /* Grainy in offscreen snapshots; trying it live. 0 turns it off. */
    cam.motionBlurIntensity = 0.4;

    _cameraNode = [SCNNode node];
    _cameraNode.name = @"gibson-camera";
    _cameraNode.camera = cam;
    [root addChildNode:_cameraNode];

    const SCNVector3 start = gibson_spline_at(0);
    _lookAtNode.position = start;
    _cameraNode.position = start;
    return self;
}

- (void)aimWithForward:(simd_float3)forward up:(simd_float3)up position:(simd_float3)pos
{
    simd_float3 z = gibson_safe_norm(-forward, simd_make_float3(0, 0, 1));
    simd_float3 x = simd_cross(up, z);
    if (simd_length(x) < 1e-5f)
        x = simd_cross(simd_make_float3(1, 0, 0), z);
    x = simd_normalize(x);
    simd_float3 y = simd_normalize(simd_cross(z, x));
    const simd_float3x3 rot = simd_matrix(x, y, z);
    _cameraNode.simdPosition = pos;
    _cameraNode.simdOrientation = simd_quaternion(rot);
}

- (void)updateAtTime:(NSTimeInterval)time startTime:(NSTimeInterval)startTime
{
    const float speed = gibson_fly_speed();
    const float elapsedMs = (float)((time - startTime) * 1000.0);
    if (_lastElapsedMs >= 0.f && elapsedMs + 50.f < _lastElapsedMs)
    {
        _bank = 0.f;
        _yawRate = 0.f;
    }
    const float frameDt = _lastElapsedMs < 0.f
        ? (1.f / 60.f)
        : std::max(1.f / 120.f, std::min(0.1f, (elapsedMs - _lastElapsedMs) * 0.001f));
    _lastElapsedMs = elapsedMs;

    const float offset = gibson_path_offset(speed);
    const float lookDt = std::max(0.f, elapsedMs) * speed * 0.001f + offset;
    const float camDt = std::max(0.f, elapsedMs - (float)GIBSON_FLY_LOOKAHEAD_MS) * speed * 0.001f + offset;
    const SCNVector3 lookPos = gibson_spline_at(lookDt);
    const SCNVector3 camPos = gibson_spline_at(camDt);
    _lookAtNode.position = lookPos;

    const simd_float3 pos = gibson_v(camPos);
    simd_float3 forward = gibson_v(lookPos) - pos;
    forward = gibson_safe_norm(forward, simd_make_float3(0, 0, 1));

    const float eps = 0.14f;
    const simd_float3 tPrev = gibson_v(gibson_spline_at(camDt - eps)) - gibson_v(gibson_spline_at(camDt - 2.f * eps));
    const simd_float3 tNext = gibson_v(gibson_spline_at(camDt + eps)) - gibson_v(gibson_spline_at(camDt));
    const simd_float3 a = gibson_safe_norm(tPrev, forward);
    const simd_float3 b = gibson_safe_norm(tNext, forward);
    float signedYaw = simd_dot(simd_cross(a, b), simd_make_float3(0, 1, 0));
    if (std::fabs(signedYaw) > 0.45f)
        signedYaw = 0.f;

    const float rawRate = signedYaw / eps;
    const float rateFollow = 1.f - std::exp(-frameDt / 0.28f);
    _yawRate += (rawRate - _yawRate) * rateFollow;

    const float maxBank = gibson_bank_max_degrees() * ((float)M_PI / 180.f);
    float target = -_yawRate * gibson_bank_strength();
    target = std::max(-maxBank, std::min(maxBank, target));

    const float tau = std::max(0.12f, gibson_bank_smoothing());
    const float bankFollow = 1.f - std::exp(-frameDt / tau);
    _bank += (target - _bank) * bankFollow;

    simd_float3 worldUp = simd_make_float3(0, 1, 0);
    if (std::fabs(_bank) > 1e-4f)
    {
        const simd_quatf roll = simd_quaternion(_bank, forward);
        worldUp = simd_normalize(simd_act(roll, worldUp));
        if (simd_dot(worldUp, simd_make_float3(0, 1, 0)) < 0.15f)
            worldUp = simd_make_float3(0, 1, 0);
    }

    [self aimWithForward:forward up:worldUp position:pos];
}

- (void)resetSmoothing
{
    _bank = 0.f;
    _yawRate = 0.f;
    _lastElapsedMs = -1.f;
}

+ (NSTimeInterval)loopDuration
{
    const float speed = std::max(0.01f, gibson_fly_speed());
    return kLoopPoints / speed;
}

+ (NSArray<NSDictionary *> *)flightMoments
{
    const float speed = std::max(0.01f, gibson_fly_speed());
    const double loop = [self loopDuration];
    const float offset = gibson_path_offset(speed);
    const double step = 0.25;
    const int n = (int)(loop / step);
    const float eps = 0.14f;

    /* Per sample: 0 straight, 1 turning left, 2 turning right, 3 up high. */
    std::vector<int> kind(n);
    std::vector<float> turn(n);
    float maxTurn = 0.f;
    for (int i = 0; i < n; ++i)
    {
        const float dt = (float)(i * step) * speed + offset;
        const simd_float3 a = gibson_safe_norm(
            gibson_v(gibson_spline_at(dt)) - gibson_v(gibson_spline_at(dt - eps)), simd_make_float3(0, 0, 1));
        const simd_float3 b = gibson_safe_norm(
            gibson_v(gibson_spline_at(dt + eps)) - gibson_v(gibson_spline_at(dt)), simd_make_float3(0, 0, 1));
        turn[i] = simd_dot(simd_cross(a, b), simd_make_float3(0, 1, 0));
        maxTurn = std::max(maxTurn, std::fabs(turn[i]));
    }
    for (int i = 0; i < n; ++i)
    {
        const float y = (float)gibson_spline_at((float)(i * step) * speed + offset).y;
        if (y > 30.f)
            kind[i] = 3;
        else if (std::fabs(turn[i]) > maxTurn * 0.35f)
            kind[i] = turn[i] > 0 ? 1 : 2;
        else
            kind[i] = 0;
    }

    /* One moment per stretch long enough to look at: the sharpest point of a
       turn, otherwise the middle. */
    NSArray<NSString *> *names = @[ @"Straight run", @"Turning left", @"Turning right", @"Rooftop swoop" ];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    int start = 0;
    for (int i = 1; i <= n; ++i)
    {
        if (i < n && kind[i] == kind[start])
            continue;
        if ((i - start) * step >= 1.5)
        {
            int pick = (start + i) / 2;
            if (kind[start] == 1 || kind[start] == 2)
                for (int k = start; k < i; ++k)
                    if (std::fabs(turn[k]) > std::fabs(turn[pick]))
                        pick = k;
            /* The camera trails the look-at point; show it once it's in the stretch. */
            const double t = pick * step + GIBSON_FLY_LOOKAHEAD_MS * 0.001;
            [out addObject:@{ @"time" : @(t), @"name" : names[kind[start]] }];
        }
        start = i;
    }
    return out;
}

@end
