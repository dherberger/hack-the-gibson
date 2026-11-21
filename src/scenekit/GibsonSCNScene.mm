#import "GibsonSCNScene.h"
#import "GibsonSCNCamera.h"
#import "GibsonWallScreens.h"

#import <AppKit/AppKit.h>

#import <ModelIO/ModelIO.h>
#import <SceneKit/ModelIO.h>
#import <CoreImage/CoreImage.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <ctime>
#include <vector>

#define TOWER_DIST 30.f
#define TOWER_XSIZE 60
#define TOWER_YSIZE 60
#define TOWER_TEXTURE_COUNT 8
#define TEXT_ANIM_WAIT 0.200
#define MAX_PULSE_SPEED 200.f
#define MIN_PULSE_SPEED 120.f
#define MAX_PULSE_HEIGHT 15.f
/* Tower footprint scale (base mesh is 9.125 units wide on a 30-unit grid).
   The flight path keeps >= 1.5 units of clearance up to 1.9. */
#define TOWER_FOOTPRINT 1.6f
#define TOWER_HEIGHT 1.265f       /* 15% taller than the original 1.1 */
/* towers.obj spans y -12.69..21.69; keep the base on the floor (y ~0.04). */
#define TOWER_MESH_BOTTOM (-12.6916f)
#define TOWER_BASE_Y 0.04f

static float gibson_tower_footprint(void)
{
    const char *env = std::getenv("GIBSON_TOWER_SCALE");  /* dev override */
    const float v = env ? (float)std::atof(env) : 0.f;
    return (v > 0.5f && v < 2.5f) ? v : TOWER_FOOTPRINT;
}

static float gibson_rand(float low, float high)
{
    return ((float)std::rand() / (float)RAND_MAX) * (high - low) + low;
}

static SCNGeometry *gibson_geometry_from_obj(NSURL *url)
{
    if (!url)
        return nil;
    NSError *err = nil;
    MDLAsset *asset = [[MDLAsset alloc] initWithURL:url
                                   vertexDescriptor:nil
                                    bufferAllocator:nil
                                  preserveTopology:YES
                                              error:&err];
    if (asset.count < 1)
        return nil;
    SCNNode *tmp = [SCNNode nodeWithMDLObject:[asset objectAtIndex:0]];
    if (tmp.geometry)
        return tmp.geometry;
    for (SCNNode *child in tmp.childNodes)
    {
        if (child.geometry)
            return child.geometry;
        for (SCNNode *grand in child.childNodes)
        {
            if (grand.geometry)
                return grand.geometry;
        }
    }
    return nil;
}

static SCNMaterial *gibson_unlit_material(id contents, BOOL alpha)
{
    SCNMaterial *mat = [SCNMaterial material];
    mat.lightingModelName = SCNLightingModelConstant;
    mat.diffuse.contents = contents;
    mat.diffuse.wrapS = SCNWrapModeRepeat;
    mat.diffuse.wrapT = SCNWrapModeRepeat;
    mat.diffuse.magnificationFilter = SCNFilterModeLinear;
    mat.diffuse.minificationFilter = SCNFilterModeLinear;
    mat.diffuse.mipFilter = SCNFilterModeLinear;
    mat.doubleSided = YES;
    mat.writesToDepthBuffer = YES;
    if (alpha)
    {
        mat.transparent.contents = contents;
        mat.transparencyMode = SCNTransparencyModeAOne;
        mat.blendMode = SCNBlendModeAlpha;
    }
    return mat;
}

/* Movie grade (phase 1). Constant-lit materials output diffuse * multiply *
 * intensity, so these set the hue and how hard each element hits the bloom. */
static NSColor *gibson_rgb(CGFloat r, CGFloat g, CGFloat b)
{
    return [NSColor colorWithCalibratedRed:r green:g blue:b alpha:1.0];
}

static void gibson_tint(SCNMaterial *mat, NSColor *color, CGFloat intensity)
{
    mat.multiply.contents = color;
    mat.diffuse.intensity = intensity;
}

/* Towers shift between electric blue and cyan instead of one static tint:
 *  - viewing angle: faces seen edge-on go cyan, head-on faces lean blue;
 *  - a slow color wave drifting through the city over time;
 *  - world position, so neighboring towers aren't in lockstep.
 * `phase` offsets the wave so dark and light towers differ slightly. */
static NSString *gibson_tower_hue_shader(float phase)
{
    return [NSString stringWithFormat:@
        "#pragma body\n"
        "float3 gWorld = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;\n"
        "float gFacing = abs(dot(normalize(_surface.normal), normalize(_surface.view)));\n"
        "float gEdgeOn = pow(1.0 - gFacing, 1.5);\n"
        "float gWave = 0.5 + 0.5 * sin(scn_frame.time * 0.5 + %.3f\n"
        "                               + gWorld.x * 0.035 + gWorld.z * 0.045);\n"
        "float gMix = smoothstep(0.15, 0.85, 0.75 * gWave + 0.55 * gEdgeOn);\n"
        "float3 gBlue = float3(0.10, 0.32, 1.0);\n"
        "float3 gCyan = float3(0.38, 0.88, 1.0);\n"
        "float3 gTint = mix(gBlue, gCyan, gMix);\n"
        /* The brightest texels (text cores, outlines) go pale cyan-white like
           the movie's electric highlights; dim glass keeps the hue shift. */
        "float gLum = max(_output.color.r, max(_output.color.g, _output.color.b));\n"
        "float gHot = smoothstep(0.75, 1.4, gLum);\n"
        "gTint = mix(gTint, float3(0.70, 0.97, 1.0), gHot * 0.75);\n"
        "_output.color.rgb *= gTint;\n",
        phase];
}

@implementation GibsonSCNScene
{
    NSURL *_mediaURL;
    GibsonSCNCamera *_flyCam;
    SCNNode *_worldRoot;
    /* Every tower node of a type shares one geometry. The text animation
       swaps that geometry's material between one prebuilt material per frame:
       assigning a new image to a live material instead makes SceneKit
       re-process the bitmap on every swap. */
    SCNGeometry *_darkTowers;
    SCNGeometry *_lightTowers;
    SCNGeometry *_darkMirror;    // the same, for the reflection under the floor
    SCNGeometry *_lightMirror;
    NSArray<SCNMaterial *> *_darkTowerMats;
    NSArray<SCNMaterial *> *_lightTowerMats;
    NSInteger _towerFrame;
    NSTimeInterval _lastTowerSwap;
    NSTimeInterval _startTime;
    NSTimeInterval _lastTime;
    BOOL _started;
    std::vector<SCNNode *> _pulses;
    std::vector<float> _pulseSpeed;
    int _gridX;
    int _gridY;
}

static GibsonSCNScene *g_previewWorld;
static GibsonSCNScene *g_fullWorld;

+ (instancetype)sharedWorldForPreview:(BOOL)preview mediaURL:(NSURL *)mediaURL
{
    GibsonSCNScene *__strong *slot = preview ? &g_previewWorld : &g_fullWorld;
    if (*slot)
        return *slot;
    GibsonSCNScene *world = [[GibsonSCNScene alloc] initWithPreview:preview mediaURL:mediaURL];
    *slot = world;
    return world;
}

+ (void)configureView:(SCNView *)view preview:(BOOL)preview mediaURL:(NSURL *)mediaURL
{
    GibsonSCNScene *world = [self sharedWorldForPreview:preview mediaURL:mediaURL];
    view.scene = world.scene;
    view.pointOfView = world.cameraNode;
    view.delegate = world;
    view.playing = YES;
    view.loops = YES;
    view.rendersContinuously = YES;
    view.allowsCameraControl = NO;
    view.autoenablesDefaultLighting = NO;
    view.backgroundColor = [NSColor blackColor];
    view.antialiasingMode = SCNAntialiasingModeNone;
    view.preferredFramesPerSecond = preview ? 30 : 60;
    view.jitteringEnabled = NO;
    if (@available(macOS 10.15, *))
        view.temporalAntialiasingEnabled = NO;
}

- (SCNNode *)cameraNode
{
    return _flyCam.cameraNode;
}

- (SCNNode *)makeViewCameraNode
{
    SCNNode *rig = _flyCam.cameraNode;
    SCNNode *node = [SCNNode node];
    node.name = @"gibson-view-camera";
    node.camera = [rig.camera copy];
    [rig addChildNode:node];
    return node;
}

+ (BOOL)wallProjection:(SCNMatrix4 *)outProjection
           orientation:(simd_quatf *)outOrientation
             forScreen:(NSScreen *)screen
{
    const NSUInteger index = [[NSScreen screens] indexOfObject:screen];
    if (index == NSNotFound)
        return NO;
    const std::vector<GibsonWallScreen> screens = gibson_wall_screens();
    GibsonWallView view;
    if (!gibson_wall_view(screens.data(), (int)screens.size(), (int)index, &view))
        return NO;
    *outProjection = SCNMatrix4FromMat4(
        gibson_wall_projection(view.slice, GIBSON_CAM_Z_NEAR, GIBSON_CAM_Z_FAR));
    *outOrientation = simd_quaternion(view.basis);
    return YES;
}

+ (NSRect)wallUnitRectForScreen:(NSScreen *)screen
{
    const NSUInteger index = [[NSScreen screens] indexOfObject:screen];
    const std::vector<GibsonWallScreen> screens = gibson_wall_screens();
    if (index == NSNotFound || index >= screens.size())
        return NSZeroRect;
    const GibsonWallRect u = gibson_wall_bounds(screens.data(), (int)screens.size());
    const GibsonWallRect r = gibson_wall_rect(screens.data(), (int)screens.size(), (int)index);
    const double w = u.x1 - u.x0, h = u.y1 - u.y0;
    if (w <= 0 || h <= 0)
        return NSZeroRect;
    return NSMakeRect((r.x0 - u.x0) / w, (r.y0 - u.y0) / h, (r.x1 - r.x0) / w, (r.y1 - r.y0) / h);
}

+ (BOOL)wallBoundsProjection:(SCNMatrix4 *)outProjection aspect:(CGFloat *)outAspect
{
    const std::vector<GibsonWallScreen> screens = gibson_wall_screens();
    if (screens.empty())
        return NO;
    const GibsonWallRect u = gibson_wall_bounds(screens.data(), (int)screens.size());
    if (u.x1 - u.x0 <= 0 || u.y1 - u.y0 <= 0)
        return NO;
    const GibsonWallSlice slice =
        gibson_wall_view_for(gibson_wall_eye(u), gibson_wall_plane(u, 0.0, 0.0)).slice;
    *outProjection = SCNMatrix4FromMat4(
        gibson_wall_projection(slice, GIBSON_CAM_Z_NEAR, GIBSON_CAM_Z_FAR));
    *outAspect = (u.x1 - u.x0) / (u.y1 - u.y0);
    return YES;
}

- (instancetype)initWithPreview:(BOOL)preview mediaURL:(NSURL *)mediaURL
{
    self = [super init];
    if (!self)
        return nil;

    _preview = preview;
    _mediaURL = mediaURL;
    /* Always build the full 60x60 city. A 10x10 preview grid is smaller than
       the flythrough, so the towers look like a finite clump. */
    _gridX = TOWER_XSIZE;
    _gridY = TOWER_YSIZE;
    _towerFrame = 0;
    _started = NO;
    std::srand((unsigned)std::time(nullptr));

    _scene = [SCNScene scene];
    _scene.background.contents = [NSColor blackColor];
    /* City edge is ~900 units out. Fade to the clear color before that so the
       grid never shows a hard wall of towers. */
    _scene.fogStartDistance = 480;
    _scene.fogEndDistance = 820;
    _scene.fogDensityExponent = 2.0;
    _scene.fogColor = [NSColor blackColor];
    _scene.fogDensityExponent = 1.0;

    /* Irrlicht is left-handed; SceneKit is right-handed. Flip Z so authored
       waypoints and placements match the windowed app. */
    _worldRoot = [SCNNode node];
    _worldRoot.name = @"gibson-world";
    _worldRoot.scale = SCNVector3Make(1, 1, -1);
    [_scene.rootNode addChildNode:_worldRoot];

    [self addLights];
    [self addRoom];
    [self addTowers];
    [self addPulses];

    _flyCam = [[GibsonSCNCamera alloc] initWithRoot:_worldRoot];
    return self;
}

- (NSURL *)mediaItem:(NSString *)name
{
    return [_mediaURL URLByAppendingPathComponent:name];
}

- (NSImage *)imageNamed:(NSString *)name
{
    return [[NSImage alloc] initWithContentsOfURL:[self mediaItem:name]];
}

- (void)addLights
{
    SCNLight *ambient = [SCNLight light];
    ambient.type = SCNLightTypeAmbient;
    ambient.color = [NSColor colorWithCalibratedWhite:0.4 alpha:1.0];
    SCNNode *ambientNode = [SCNNode node];
    ambientNode.light = ambient;
    [_worldRoot addChildNode:ambientNode];

    SCNLight *dir = [SCNLight light];
    dir.type = SCNLightTypeDirectional;
    dir.color = [NSColor colorWithCalibratedWhite:0.8 alpha:1.0];
    SCNNode *dirNode = [SCNNode node];
    dirNode.light = dir;
    dirNode.eulerAngles = SCNVector3Make(-45.f * (float)M_PI / 180.f,
                                         45.f * (float)M_PI / 180.f,
                                         0);
    [_worldRoot addChildNode:dirNode];
}

/* Floor: an SCNFloor with the
 * circuit texture repeated FLOOR_REPEAT times per SCNFloor texture unit
 * (1 is about the original room mesh's scale: one tile per ~9 towers).
 * GIBSON_FLOOR_REPEAT overrides it for test renders. */
#define FLOOR_REPEAT 1.f  /* media/room.png is a 2016 px tile (tools/gen_textures.py --floor pcb) */
/* In the film the floor stays opaque and dark; only the glossy traces mirror
 * the towers. SceneKit's SCNFloor reflection can't be masked per pixel, so:
 *  - an upside-down copy of the towers sits under the floor (see addTowers);
 *  - the floor's dark gaps are opaque, and its traces are partly see-through
 *    (thresholded trace texture as an RGBZero transparency mask), so the
 *    mirrored towers show only inside the traces.
 * Drawing the towers twice roughly doubles their draw calls, like a
 * reflection pass. */
#define GIBSON_ORDER_MIRROR (-10)
/* Mirrored towers further than this from the camera aren't drawn (units; the
   towers are 30 apart). GIBSON_MIRROR_DIST overrides it for tests; 0 = all. */
#define MIRROR_DISTANCE 300.f
#define GIBSON_ORDER_FLOOR (-5)

static float gibson_env_float(const char *name, float fallback, float lo, float hi)
{
    const char *env = std::getenv(name);
    if (!env)
        return fallback;
    const float v = (float)std::atof(env);
    return (v >= lo && v <= hi) ? v : fallback;
}

/* The floor's transparency mask: the trace texture thresholded so the dark
 * gaps (and the soft halo) are exactly 0 = opaque and the trace cores are
 * bright = see-through to the mirrored towers below (RGBZero mode). Trace
 * cores are at most 27.5% see-through (the last points of the curve). */
static NSImage *gibson_trace_mask_image(NSImage *src)
{
    CGImageRef cg = [src CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cg)
        return src;
    CIImage *ci = [CIImage imageWithCGImage:cg];
    CIFilter *curve = [CIFilter filterWithName:@"CIToneCurve"];
    [curve setValue:ci forKey:kCIInputImageKey];
    [curve setValue:[CIVector vectorWithX:0.0 Y:0.0] forKey:@"inputPoint0"];
    [curve setValue:[CIVector vectorWithX:0.35 Y:0.0] forKey:@"inputPoint1"];
    [curve setValue:[CIVector vectorWithX:0.55 Y:0.14] forKey:@"inputPoint2"];
    [curve setValue:[CIVector vectorWithX:0.75 Y:0.275] forKey:@"inputPoint3"];
    [curve setValue:[CIVector vectorWithX:1.0 Y:0.275] forKey:@"inputPoint4"];
    CIContext *ctx = [CIContext contextWithOptions:nil];
    CGImageRef out = [ctx createCGImage:curve.outputImage fromRect:ci.extent];
    if (!out)
        return src;
    NSImage *img = [[NSImage alloc] initWithCGImage:out size:src.size];
    CGImageRelease(out);
    return img;
}

- (void)addRoom
{
    NSImage *tex = [self imageNamed:@"room.png"];
    if (!tex)
        return;
    const float repeat = gibson_env_float("GIBSON_FLOOR_REPEAT", FLOOR_REPEAT, 0.1f, 20.f);
    const SCNMatrix4 tiling = SCNMatrix4MakeScale(repeat, repeat, 1.f);

    SCNMaterial *mat = gibson_unlit_material(tex, NO);
    /* Pale traces -> dark royal-blue circuit lines. */
    gibson_tint(mat, gibson_rgb(0.22, 0.30, 1.0), 0.8);
    mat.diffuse.contentsTransform = tiling;
    mat.multiply.contentsTransform = tiling;

    /* Traces partly see-through to the mirrored towers; gaps opaque. */
    mat.transparent.contents = gibson_trace_mask_image(tex);
    mat.transparent.contentsTransform = tiling;
    mat.transparent.wrapS = SCNWrapModeRepeat;
    mat.transparent.wrapT = SCNWrapModeRepeat;
    mat.transparencyMode = SCNTransparencyModeRGBZero;
    mat.blendMode = SCNBlendModeAlpha;
    mat.writesToDepthBuffer = NO;

    SCNFloor *floor = [SCNFloor floor];
    floor.reflectivity = 0.f;  /* no SceneKit reflection pass */
    floor.materials = @[ mat ];

    SCNNode *room = [SCNNode nodeWithGeometry:floor];
    room.name = @"room";
    room.renderingOrder = GIBSON_ORDER_FLOOR;
    [_scene.rootNode addChildNode:room];
}

- (SCNMaterial *)towerMaterialNamed:(NSString *)name intensity:(CGFloat)intensity phase:(float)phase
{
    SCNMaterial *mat = gibson_unlit_material([self imageNamed:name], YES);
    /* Grey-teal glass -> saturated electric cyan. Hue comes from the shader
       modifier; multiply stays white. */
    gibson_tint(mat, [NSColor whiteColor], intensity);
    mat.shaderModifiers = @{ SCNShaderModifierEntryPointFragment : gibson_tower_hue_shader(phase) };
    return mat;
}

- (void)addTowers
{
    SCNGeometry *geom = gibson_geometry_from_obj([self mediaItem:@"towers.obj"]);
    if (!geom)
        return;

    NSMutableArray<SCNMaterial *> *dark = [NSMutableArray arrayWithCapacity:TOWER_TEXTURE_COUNT];
    NSMutableArray<SCNMaterial *> *light = [NSMutableArray arrayWithCapacity:TOWER_TEXTURE_COUNT];
    for (int i = 1; i <= TOWER_TEXTURE_COUNT; ++i)
    {
        [dark addObject:[self towerMaterialNamed:[NSString stringWithFormat:@"towers1-%d.png", i]
                                       intensity:1.45 phase:0.0f]];
        [light addObject:[self towerMaterialNamed:[NSString stringWithFormat:@"towers2-%d.png", i]
                                        intensity:1.6 phase:1.7f]];
    }
    _darkTowerMats = dark;
    _lightTowerMats = light;

    SCNGeometry *darkGeom = [geom copy];
    darkGeom.materials = @[ dark[0] ];
    SCNGeometry *lightGeom = [geom copy];
    lightGeom.materials = @[ light[0] ];
    _darkTowers = darkGeom;
    _lightTowers = lightGeom;

    SCNNode *darkGroup = [SCNNode node];
    SCNNode *lightGroup = [SCNNode node];
    const int live = _gridX * _gridY;
    float x = -((_gridX / 2) * TOWER_DIST);
    float z = ((_gridY / 2) * TOWER_DIST);

    const float footprint = gibson_tower_footprint();
    auto place = ^(SCNGeometry *g, SCNNode *parent, float px, float pz) {
        SCNNode *tower = [SCNNode nodeWithGeometry:g];
        tower.scale = SCNVector3Make(footprint, TOWER_HEIGHT, footprint);
        tower.position = SCNVector3Make(px, TOWER_BASE_Y - TOWER_MESH_BOTTOM * TOWER_HEIGHT, pz);
        [parent addChildNode:tower];
    };

    place(darkGeom, darkGroup, x + 9.125f, z);

    for (int i = 1; i < live; ++i)
    {
        x += TOWER_DIST;
        if ((i + 1) % _gridX == 0)
        {
            z -= TOWER_DIST;
            x = -((_gridX / 2) * TOWER_DIST);
        }
        const BOOL lightType = ((int)gibson_rand(0.f, 2.f) > 0);
        place(lightType ? lightGeom : darkGeom, lightType ? lightGroup : darkGroup,
              x + TOWER_DIST / 2.f, z);
    }

    /* One node per tower, not -flattenedClone. The glass only looks right
       drawn back to front, tower by tower, and SceneKit sorts a flattened
       clone that way too, but it draws all 3600 towers every frame. Separate
       nodes get the same sort plus frustum culling, at about half the CPU.
       (A single merged mesh is far cheaper still, but draws in a fixed order,
       so near glass hides the towers behind it.) */
    [_worldRoot addChildNode:darkGroup];
    [_worldRoot addChildNode:lightGroup];

    /* Fake reflection: the same towers flipped under the floor, showing only
       through the floor's see-through traces (see addRoom). Shares materials,
       so the text animation and hue shader apply too. The mirror is drawn in
       full and then mostly covered by the floor; through the thin traces only
       nearby reflections are noticeable, so beyond MIRROR_DISTANCE its towers
       turn into nothing (a nil level of detail). That halves the GPU's work. */
    const float mirrorDist = gibson_env_float("GIBSON_MIRROR_DIST", MIRROR_DISTANCE, 0.f, 2000.f);
    auto mirrorGeometry = [&](SCNGeometry *g) {
        SCNGeometry *m = [g copy];
        m.materials = g.materials;
        if (mirrorDist > 0)
            m.levelsOfDetail = @[ [SCNLevelOfDetail levelOfDetailWithGeometry:nil
                                                            worldSpaceDistance:mirrorDist] ];
        return m;
    };
    _darkMirror = mirrorGeometry(darkGeom);
    _lightMirror = mirrorGeometry(lightGeom);

    SCNNode *mirror = [SCNNode node];
    mirror.name = @"tower-mirror";
    mirror.scale = SCNVector3Make(1, -1, 1);
    for (SCNNode *group in @[ darkGroup, lightGroup ])
    {
        SCNNode *copy = [group clone];
        SCNGeometry *g = (group == darkGroup) ? _darkMirror : _lightMirror;
        /* Fixed draw order: mirror, then the floor over it, then the real
           towers. Left to SceneKit's distance sort, the mirror sometimes
           lands on top of the floor when the camera turns. */
        for (SCNNode *tower in copy.childNodes)
        {
            tower.geometry = g;
            tower.renderingOrder = GIBSON_ORDER_MIRROR;
        }
        [mirror addChildNode:copy];
    }
    [_worldRoot addChildNode:mirror];
}

- (void)addPulses
{
    SCNGeometry *geom = gibson_geometry_from_obj([self mediaItem:@"pulse.obj"]);
    if (!geom)
        return;
    NSImage *tex = [self imageNamed:@"pulse.png"];
    SCNMaterial *mat = gibson_unlit_material(tex, YES);
    /* Purple blobs -> long cyan-white streaks that bloom. */
    gibson_tint(mat, gibson_rgb(0.55, 0.95, 1.0), 4.0);
    mat.blendMode = SCNBlendModeAdd;
    mat.writesToDepthBuffer = NO;
    geom.materials = @[ mat ];

    const int count = _preview ? 80 : 280;
    _pulses.reserve((size_t)count);
    _pulseSpeed.reserve((size_t)count);
    for (int i = 0; i < count; ++i)
    {
        SCNNode *pulse = [SCNNode nodeWithGeometry:geom];
        pulse.scale = SCNVector3Make(1.6f, 1.6f, 10.f);
        [self respawnPulse:pulse];
        [_worldRoot addChildNode:pulse];
        _pulses.push_back(pulse);
        _pulseSpeed.push_back(gibson_rand(MIN_PULSE_SPEED, MAX_PULSE_SPEED));
    }
}

- (void)respawnPulse:(SCNNode *)pulse
{
    const float px = TOWER_DIST * (int)gibson_rand(-_gridX, _gridX);
    const float py = gibson_rand(1.f, MAX_PULSE_HEIGHT);
    const float pz = TOWER_DIST * (int)gibson_rand(-_gridY, _gridY) + TOWER_DIST / 2.f;
    pulse.position = SCNVector3Make(
        px + gibson_rand(-TOWER_DIST / 4.f, TOWER_DIST / 4.f),
        py,
        pz + gibson_rand(-TOWER_DIST / 4.f, TOWER_DIST / 4.f));
    const int yawSteps = (int)gibson_rand(0.f, 4.f);
    pulse.eulerAngles = SCNVector3Make(0, yawSteps * (float)M_PI / 2.f, 0);
}

- (void)renderer:(id<SCNSceneRenderer>)renderer updateAtTime:(NSTimeInterval)time
{
    (void)renderer;
    [self tickAtTime:time];
}

- (void)renderer:(id<SCNSceneRenderer>)renderer didRenderScene:(SCNScene *)scene atTime:(NSTimeInterval)time
{
    (void)renderer;
    (void)scene;
    (void)time;
    ++_renderedFrames;   // render-thread only; a torn read in the bench is harmless
}

- (void)resetClock
{
    _started = NO;
}

- (void)seekToTime:(NSTimeInterval)time
{
    time = std::max(0.0, time);
    _started = YES;
    _startTime = 0;
    /* Banking follows the recent path, so fly the last few seconds in. */
    [_flyCam resetSmoothing];
    for (NSTimeInterval t = std::max(0.0, time - 3.0); t < time; t += 1.0 / 60.0)
        [_flyCam updateAtTime:t startTime:0];
    [_flyCam updateAtTime:time startTime:0];
    _lastTime = time;
    _lastTowerSwap = time;
}

- (void)tickAtTime:(NSTimeInterval)time
{
    if (!_started)
    {
        _started = YES;
        _startTime = time;
        _lastTime = time;
        _lastTowerSwap = time;
    }

    /* Every view showing the world calls this once per frame; the first one
       in a frame moves everything, the rest have nothing to do. */
    if (time < _lastTime + 1.0 / 240.0 && time != _startTime)
        return;

    const float delta = (float)std::min(0.1, std::max(0.0, (double)(time - _lastTime)));
    _lastTime = time;

    [_flyCam updateAtTime:time startTime:_startTime];
    [self updateTowersAtTime:time];
    [self updatePulses:delta];
}

- (void)updateTowersAtTime:(NSTimeInterval)time
{
    if (time - _lastTowerSwap < TEXT_ANIM_WAIT)
        return;
    _lastTowerSwap = time;
    _towerFrame = (_towerFrame + 1) % TOWER_TEXTURE_COUNT;
    _darkTowers.materials = @[ _darkTowerMats[_towerFrame] ];
    _lightTowers.materials = @[ _lightTowerMats[_towerFrame] ];
    _darkMirror.materials = _darkTowers.materials;
    _lightMirror.materials = _lightTowers.materials;
}

- (void)updatePulses:(float)delta
{
    const float maxX = ((_gridX / 2) * TOWER_DIST);
    const float maxZ = ((_gridY / 2) * TOWER_DIST);
    for (size_t i = 0; i < _pulses.size(); ++i)
    {
        SCNNode *pulse = _pulses[i];
        const float dist = delta * _pulseSpeed[i];
        simd_float3 step = simd_act(pulse.simdOrientation, simd_make_float3(0, 0, -dist));
        pulse.simdPosition += step;
        const SCNVector3 p = pulse.position;
        if (p.x >= maxX || p.z >= maxZ || p.x <= -maxX || p.z <= -maxZ)
        {
            [self respawnPulse:pulse];
            _pulseSpeed[i] = gibson_rand(MIN_PULSE_SPEED, MAX_PULSE_SPEED);
        }
    }
}

@end
