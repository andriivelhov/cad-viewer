#import "CADView.h"
#import "ShaderTypes.h"
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UTCoreTypes.h>

#include "cadcore/CadDocument.h"

#include <algorithm>
#include <memory>
#include <vector>
#include <vector>
#include <simd/simd.h>

// Used from inside a completion block before its definition appears below.
@interface CADView ()
@property(nonatomic, readonly) void *pickBufferContents;
@property(nonatomic, readonly) void *hoverBufferContents;
- (void)uploadMeshBuffers;
- (void)applyStoredSettings;
- (NSString *)formatLength:(double)millimetres;
- (void)updateSnapPreviewForEntity:(uint32_t)entityId atPixel:(simd_float2)pixel;
- (void)updateCursorWorldAtPixel:(simd_float2)pixel depth:(float)depth;
- (void)clearHoverInFlight;
- (void)setHoverEntity:(uint32_t)faceId;
- (void)updateCursor;
@end

// The measurement chip must never eat a click meant for the model.
@interface CADPassthroughView : NSView
@end
@implementation CADPassthroughView
- (NSView *)hitTest:(NSPoint)point { return nil; }
@end

namespace {

// 4x MSAA by default: enough to clean up CAD silhouettes and 2 px feature edges
// without the memory cost of 8x on a Retina drawable. Adjustable in Settings.
constexpr NSUInteger kDefaultSampleCount = 4;

// Shared by the projection and the pan scale; they must agree or panning
// cannot track the pointer.
constexpr float kFovYDegrees = 35.0f;

// The window uses a full-size content view, so this view extends under the
// titlebar where AppKit owns the cursor for the traffic lights. Overriding it
// there makes the cursor flicker as the pointer crosses the boundary.
constexpr CGFloat kTitlebarBand = 32.0;

// Faces and edges share the identity buffer; the top bit says which.
bool isEdgeId(uint32_t entityId) {
  return entityId != FACE_ID_NONE && (entityId & ENTITY_EDGE_FLAG) != 0;
}
uint32_t entityIndex(uint32_t entityId) { return entityId & ENTITY_INDEX_MASK; }

simd_float4x4 makePerspective(float fovyRadians, float aspect, float near, float far) {
  const float ys = 1.0f / std::tan(fovyRadians * 0.5f);
  const float xs = ys / aspect;
  const float zs = far / (near - far);
  return simd_matrix_from_rows(simd_make_float4(xs, 0, 0, 0),
                               simd_make_float4(0, ys, 0, 0),
                               simd_make_float4(0, 0, zs, near * zs),
                               simd_make_float4(0, 0, -1, 0));
}

simd_float4x4 makeLookAt(simd_float3 eye, simd_float3 center, simd_float3 up) {
  const simd_float3 f = simd_normalize(center - eye);
  const simd_float3 s = simd_normalize(simd_cross(f, up));
  const simd_float3 u = simd_cross(s, f);
  return simd_matrix_from_rows(
      simd_make_float4(s.x, s.y, s.z, -simd_dot(s, eye)),
      simd_make_float4(u.x, u.y, u.z, -simd_dot(u, eye)),
      simd_make_float4(-f.x, -f.y, -f.z, simd_dot(f, eye)),
      simd_make_float4(0, 0, 0, 1));
}

}  // namespace

@implementation CADView {
  id<MTLCommandQueue> _queue;
  id<MTLRenderPipelineState> _backgroundPipeline;
  id<MTLRenderPipelineState> _shadedPipeline;
  id<MTLRenderPipelineState> _edgePipeline;
  id<MTLRenderPipelineState> _markerPipeline;
  id<MTLRenderPipelineState> _cubePipeline;
  id<MTLBuffer> _cubeBuffer;
  id<MTLTexture> _cubeLabels;
  id<MTLSamplerState> _cubeSampler;
  id<MTLRenderPipelineState> _pickResolvePipeline;
  id<MTLDepthStencilState> _depthAlways;
  id<MTLDepthStencilState> _depthLess;
  id<MTLDepthStencilState> _depthLessEqual;

  id<MTLBuffer> _vertexBuffer;
  id<MTLBuffer> _indexBuffer;
  id<MTLBuffer> _edgeVertexBuffer;
  id<MTLBuffer> _edgeIndexBuffer;
  id<MTLBuffer> _edgeIdBuffer;
  id<MTLBuffer> _faceSelectedBuffer;
  id<MTLBuffer> _edgeSelectedBuffer;
  NSUInteger _faceCount;
  NSUInteger _edgeCount;
  std::vector<uint32_t> _selection;  // entity ids, multi-select
  NSUInteger _indexCount;
  NSUInteger _edgeIndexCount;

  id<MTLTexture> _faceIdTexture;   // multisampled
  id<MTLTexture> _depthTexture;    // owned so the resolve can sample it
  id<MTLTexture> _pickTexture;     // 1x1 resolve target
  id<MTLTexture> _pickDepthTexture;
  id<MTLBuffer> _pickBuffer;
  id<MTLBuffer> _hoverBuffer;      // separate, so a hover cannot race a click
  BOOL _hoverResolveInFlight;
  uint32_t _hoverEntity;

  // Where the pointer is in the world, refreshed by the hover resolve. Drives
  // orbit pivot and zoom target so the grabbed point stays under the cursor.
  simd_float3 _cursorWorld;
  BOOL _cursorWorldValid;
  simd_float4x4 _lastViewProjection;
  BOOL _pickPending;
  BOOL _pickIsShift;
  CGPoint _pickPoint;

  std::unique_ptr<cadcore::Document> _doc;

  // Orbit camera around the model centre.
  simd_float3 _target;
  float _distance;
  float _azimuth;
  float _elevation;
  float _modelRadius;
  simd_float3 _modelCenter;

  NSSegmentedControl *_modeControl;
  NSSegmentedControl *_frameControl;
  NSSegmentedControl *_orientationControl;
  CADPassthroughView *_measureChip;
  NSTextField *_measureChipLabel;

  cadcore::MeasureRef _refs[2];
  int _refCount;
  simd_float3 _measurePoints[2];
  double _lastMeasuredDistance;  // where the measurement is actually taken
  BOOL _hasMeasureLine;
  simd_float3 _snapPreview;
  BOOL _hasSnapPreview;
  NSString *_lastRefDescription;
  simd_float2 _pickPointPixel;
  BOOL _pickForcedPoint;
  CGSize _pickSizeOverride;   // headless renders pick at their own size
  CGSize _renderSizeOverride;  // and rasterise at their own size
  BOOL _headless;
  NSUInteger _sampleCount;
  NSPoint _lastGestureTranslation;
  BOOL _orbitPivotFromGesture;
  id<MTLBuffer> _markerBuffer;
  id<MTLRenderPipelineState> _measureLinePipeline;

  NSPoint _lastDrag;
  NSPoint _lastMousePoint;
  BOOL _isDragging;
  BOOL _isPanning;
  BOOL _userNavigated;  // suppresses refit-on-resize once you take control
}

// The QuickLook extension renders with no window and no UI. Building the
// toolbar there would construct AppKit controls in a process that has no
// business doing so, and off the main thread it simply hangs.
- (instancetype)initHeadlessWithFrame:(CGRect)frame device:(id<MTLDevice>)device {
  _headless = YES;
  return [self initWithFrame:frame device:device];
}

- (instancetype)initWithFrame:(CGRect)frame device:(id<MTLDevice>)device {
  if ((self = [super initWithFrame:frame device:device])) {
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    self.clearDepth = 1.0;
    self.clearColor = MTLClearColorMake(0, 0, 0, 0);
    NSInteger stored =
        [NSUserDefaults.standardUserDefaults integerForKey:@"AntialiasingSamples"];
    if (stored != 1 && stored != 2 && stored != 4 && stored != 8)
      stored = kDefaultSampleCount;
    _sampleCount = [CADView supportedSampleCountAtMost:(NSUInteger)stored
                                             forDevice:device];
    self.sampleCount = _sampleCount;
    self.enableSetNeedsDisplay = YES;
    self.paused = YES;
    _hoverEntity = FACE_ID_NONE;
    _backgroundStyle =
        [NSUserDefaults.standardUserDefaults integerForKey:@"BackgroundStyle"];
    [self applyStoredSettings];
    _azimuth = -0.9f;
    _elevation = 0.5f;
    _distance = 300.0f;
    [self buildPipelines];
    if (!_headless) {
      [self registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
      [self buildToolbar];
    } else {
      // Inside a QuickLook preview the host claims raw drag events (normally
      // to drag the file out), so mouseDragged: never arrives. A gesture
      // recogniser participates in gesture arbitration and wins the drag.
      [self addGestureRecognizer:
          [[NSPanGestureRecognizer alloc] initWithTarget:self
                                                  action:@selector(handlePan:)]];
      [self addGestureRecognizer:
          [[NSMagnificationGestureRecognizer alloc]
              initWithTarget:self
                      action:@selector(handleMagnify:)]];
    }
  }
  return self;
}

- (void)buildPipelines {
  _queue = [self.device newCommandQueue];

  NSError *error = nil;
  NSURL *libURL = [[NSBundle mainBundle] URLForResource:@"default"
                                          withExtension:@"metallib"];
  id<MTLLibrary> library =
      libURL ? [self.device newLibraryWithURL:libURL error:&error] : nil;

  // Falls back to compiling the shader source at launch, so a machine without
  // the Xcode Metal toolchain installed can still build and run this.
  if (!library) {
    NSURL *srcURL = [[NSBundle mainBundle] URLForResource:@"Shaders"
                                            withExtension:@"metal"];
    NSString *source = srcURL
        ? [NSString stringWithContentsOfURL:srcURL
                                   encoding:NSUTF8StringEncoding
                                      error:nil]
        : nil;
    if (source) {
      // ShaderTypes.h is not on the runtime include path; inline the one
      // constant the shaders need from it.
      source = [@"#define FACE_ID_NONE 0xFFFFFFFFu\n"
                 "#define __RUNTIME_COMPILE__ 1\n" stringByAppendingString:source];
      source = [source stringByReplacingOccurrencesOfString:@"#include \"ShaderTypes.h\""
                                                 withString:@""];
      library = [self.device newLibraryWithSource:source
                                          options:nil
                                            error:&error];
    }
  }
  NSAssert(library, @"shader library missing: %@", error);

  MTLRenderPipelineDescriptor *(^base)(NSString *, NSString *) =
      ^(NSString *vs, NSString *fs) {
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [library newFunctionWithName:vs];
        d.fragmentFunction = [library newFunctionWithName:fs];
        d.colorAttachments[0].pixelFormat = self.colorPixelFormat;
        d.colorAttachments[1].pixelFormat = MTLPixelFormatR32Uint;
        d.depthAttachmentPixelFormat = self.depthStencilPixelFormat;
        d.rasterSampleCount = _sampleCount;
        return d;
      };

  _backgroundPipeline = [self.device
      newRenderPipelineStateWithDescriptor:base(@"vsBackground", @"fsBackground")
                                     error:&error];
  _shadedPipeline = [self.device
      newRenderPipelineStateWithDescriptor:base(@"vsShaded", @"fsShaded")
                                     error:&error];
  _edgePipeline = [self.device
      newRenderPipelineStateWithDescriptor:base(@"vsEdge", @"fsEdge")
                                     error:&error];
  _markerPipeline = [self.device
      newRenderPipelineStateWithDescriptor:base(@"vsMarker", @"fsMarker")
                                     error:&error];
  _cubePipeline = [self.device
      newRenderPipelineStateWithDescriptor:base(@"vsCube", @"fsCube")
                                     error:&error];
  [self buildViewCube];

  _measureLinePipeline = [self.device
      newRenderPipelineStateWithDescriptor:base(@"vsMeasureLine", @"fsMarker")
                                     error:&error];
  _markerBuffer = [self.device newBufferWithLength:sizeof(float) * 3 * 4
                                           options:MTLResourceStorageModeShared];
  NSAssert(_shadedPipeline, @"pipeline failed: %@", error);

  MTLRenderPipelineDescriptor *pickDesc = [MTLRenderPipelineDescriptor new];
  pickDesc.vertexFunction = [library newFunctionWithName:@"vsPickResolve"];
  pickDesc.fragmentFunction = [library
      newFunctionWithName:_sampleCount > 1 ? @"fsPickResolve"
                                           : @"fsPickResolveSingle"];
  pickDesc.colorAttachments[0].pixelFormat = MTLPixelFormatR32Uint;
  pickDesc.colorAttachments[1].pixelFormat = MTLPixelFormatR32Float;
  pickDesc.rasterSampleCount = 1;
  _pickResolvePipeline =
      [self.device newRenderPipelineStateWithDescriptor:pickDesc error:&error];
  NSAssert(_pickResolvePipeline, @"pick resolve pipeline failed: %@", error);

  MTLTextureDescriptor *pt = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint
                                   width:1 height:1 mipmapped:NO];
  pt.usage = MTLTextureUsageRenderTarget;
  pt.storageMode = MTLStorageModePrivate;
  _pickTexture = [self.device newTextureWithDescriptor:pt];
  pt.pixelFormat = MTLPixelFormatR32Float;
  _pickDepthTexture = [self.device newTextureWithDescriptor:pt];

  MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
  dd.depthCompareFunction = MTLCompareFunctionAlways;
  dd.depthWriteEnabled = NO;
  _depthAlways = [self.device newDepthStencilStateWithDescriptor:dd];
  dd.depthCompareFunction = MTLCompareFunctionLess;
  dd.depthWriteEnabled = YES;
  _depthLess = [self.device newDepthStencilStateWithDescriptor:dd];
  dd.depthCompareFunction = MTLCompareFunctionLessEqual;
  _depthLessEqual = [self.device newDepthStencilStateWithDescriptor:dd];

  // 8 bytes: face id at 0, NDC depth at 4.
  _pickBuffer = [self.device newBufferWithLength:8
                                         options:MTLResourceStorageModeShared];
  _hoverBuffer = [self.device newBufferWithLength:8
                                          options:MTLResourceStorageModeShared];
}

#pragma mark - View cube

// Face order matches applyStandardView: 0 iso is not on the cube, so the six
// faces map to named viewpoints directly.
typedef struct {
  simd_float3 normal;
  simd_float3 right;
  simd_float3 up;
  int view;  // index into applyStandardView
} CubeFace;

- (void)buildViewCube {
  static const CubeFace faces[6] = {
      {{ 1, 0, 0}, { 0, 1, 0}, {0, 0, 1}, 4},  // +X  right
      {{-1, 0, 0}, { 0,-1, 0}, {0, 0, 1}, 5},  // -X  left
      {{ 0, 1, 0}, {-1, 0, 0}, {0, 0, 1}, 6},  // +Y  back
      {{ 0,-1, 0}, { 1, 0, 0}, {0, 0, 1}, 1},  // -Y  front
      // The label reads upright when `up` points the way the viewer's up does
      // when facing that side, which is +Y from above and -Y from below.
      {{ 0, 0, 1}, { 1, 0, 0}, {0, 1, 0}, 2},  // +Z  top
      {{ 0, 0,-1}, { 1, 0, 0}, {0,-1, 0}, 7},  // -Z  bottom
  };

  struct CubeVertex {
    float position[3];
    float normal[3];
    float uv[2];
    uint32_t face;
  };
  std::vector<CubeVertex> vertices;
  vertices.reserve(36);

  // Labels are a 3x2 atlas; each face samples its own tile.
  for (uint32_t f = 0; f < 6; ++f) {
    const CubeFace &cf = faces[f];
    const float u0 = (f % 3) / 3.0f, v0 = (f / 3) / 2.0f;
    const float du = 1.0f / 3.0f, dv = 1.0f / 2.0f;
    const simd_float2 corners[4] = {{-1, -1}, {1, -1}, {1, 1}, {-1, 1}};
    const simd_float2 uvs[4] = {{0, 1}, {1, 1}, {1, 0}, {0, 0}};
    CubeVertex quad[4];
    for (int i = 0; i < 4; ++i) {
      const simd_float3 p =
          cf.normal + cf.right * corners[i].x + cf.up * corners[i].y;
      quad[i] = {{p.x * 0.5f, p.y * 0.5f, p.z * 0.5f},
                 {cf.normal.x, cf.normal.y, cf.normal.z},
                 {u0 + uvs[i].x * du, v0 + uvs[i].y * dv},
                 f};
    }
    for (int i : {0, 1, 2, 0, 2, 3}) vertices.push_back(quad[i]);
  }

  _cubeBuffer = [self.device newBufferWithBytes:vertices.data()
                                         length:vertices.size() * sizeof(CubeVertex)
                                        options:MTLResourceStorageModeShared];
  _cubeLabels = [self buildCubeLabelAtlas];

  MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
  sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
  sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
  _cubeSampler = [self.device newSamplerStateWithDescriptor:sd];
}

// Draws the six labels into one texture with CoreGraphics. Rendering text in
// Metal would need a glyph atlas for no benefit at this size.
- (id<MTLTexture>)buildCubeLabelAtlas {
  const NSInteger tile = 128, cols = 3, rows = 2;
  const NSInteger w = tile * cols, h = tile * rows;
  NSArray<NSString *> *names = @[ @"RIGHT", @"LEFT", @"BACK",
                                  @"FRONT", @"TOP", @"BOTTOM" ];

  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs,
                                           kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(cs);
  if (!ctx) return nil;

  NSGraphicsContext *previous = NSGraphicsContext.currentContext;
  NSGraphicsContext.currentContext =
      [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
  for (NSInteger i = 0; i < 6; ++i) {
    NSDictionary *attrs = @{
      NSFontAttributeName : [NSFont systemFontOfSize:26 weight:NSFontWeightSemibold],
      NSForegroundColorAttributeName : NSColor.whiteColor,
    };
    NSSize size = [names[i] sizeWithAttributes:attrs];
    const NSInteger col = i % cols, row = i / cols;
    [names[i] drawAtPoint:NSMakePoint(col * tile + (tile - size.width) / 2,
                                      h - (row + 1) * tile + (tile - size.height) / 2)
           withAttributes:attrs];
  }
  NSGraphicsContext.currentContext = previous;

  MTLTextureDescriptor *td = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                   width:w height:h mipmapped:NO];
  td.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> texture = [self.device newTextureWithDescriptor:td];
  [texture replaceRegion:MTLRegionMake2D(0, 0, w, h)
             mipmapLevel:0
               withBytes:CGBitmapContextGetData(ctx)
             bytesPerRow:w * 4];
  CGContextRelease(ctx);
  return texture;
}

+ (int)standardViewForCubeFace:(uint32_t)face {
  static const int views[6] = {4, 5, 6, 1, 2, 7};
  return face < 6 ? views[face] : 0;
}

#pragma mark - Toolbar

// Floating controls straight on the viewport rather than a chrome bar, so the
// window stays full-bleed. NSSegmentedControl draws its own native bezel and
// picks up the system appearance, so no background container is needed.
- (void)buildToolbar {
  _modeControl = [NSSegmentedControl
      segmentedControlWithLabels:@[ @"View", @"Measure" ]
                    trackingMode:NSSegmentSwitchTrackingSelectOne
                          target:self
                          action:@selector(modeControlChanged:)];
  _modeControl.selectedSegment = 0;
  [_modeControl setToolTip:@"V inspect · M measure (⌥-click for a free point)"];

  _frameControl = [NSSegmentedControl
      segmentedControlWithLabels:@[ @"Frame" ]
                    trackingMode:NSSegmentSwitchTrackingMomentary
                          target:self
                          action:@selector(frameControlPressed:)];
  [_frameControl setToolTip:@"Fit the model to the window (F)"];

  _orientationControl = [NSSegmentedControl
      segmentedControlWithLabels:@[ @"Iso" ]
                    trackingMode:NSSegmentSwitchTrackingMomentary
                          target:self
                          action:@selector(orientationControlPressed:)];
  [_orientationControl setToolTip:@"Isometric view — or click a face of the cube"];

  for (NSSegmentedControl *control in
       @[ _modeControl, _frameControl, _orientationControl ]) {
    control.controlSize = NSControlSizeRegular;
    control.segmentStyle = NSSegmentStyleRounded;
    // Pinned to the top-left; a flexible bottom margin keeps it there.
    control.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;
    [self addSubview:control];
  }
  [self buildMeasureChip];
  [self layoutToolbar];
  [self applyChromeAppearance];
}

// A floating chip above the measurement line. Native text stays crisp at any
// zoom, which rendering glyphs into the Metal pass would not.
- (void)buildMeasureChip {
  _measureChip = [[CADPassthroughView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
  _measureChip.wantsLayer = YES;
  _measureChip.layer.cornerRadius = 5.0;
  _measureChip.layer.borderWidth = 1.0;
  _measureChip.hidden = YES;

  _measureChipLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
  _measureChipLabel.bezeled = NO;
  _measureChipLabel.drawsBackground = NO;
  _measureChipLabel.editable = NO;
  _measureChipLabel.selectable = NO;
  _measureChipLabel.alignment = NSTextAlignmentCenter;
  // Monospaced digits so the value does not jitter while you drag.
  _measureChipLabel.font = [NSFont monospacedDigitSystemFontOfSize:12
                                                            weight:NSFontWeightMedium];
  [_measureChip addSubview:_measureChipLabel];
  [self addSubview:_measureChip];
  [self applyChipAppearance];
}

- (void)applyChipAppearance {
  if (!_measureChip) return;
  const BOOL dark = [self groundIsDarkNearTop];
  _measureChip.layer.backgroundColor =
      (dark ? [NSColor colorWithWhite:0.10 alpha:0.92]
            : [NSColor colorWithWhite:1.00 alpha:0.94]).CGColor;
  _measureChip.layer.borderColor =
      [NSColor colorWithSRGBRed:1.00 green:0.58 blue:0.16 alpha:0.9].CGColor;
  _measureChipLabel.textColor =
      dark ? [NSColor colorWithWhite:0.97 alpha:1.0]
           : [NSColor colorWithWhite:0.12 alpha:1.0];
}

- (void)setMeasureChipText:(NSString *)text {
  if (_headless || !_measureChip) return;
  if (!text) {
    _measureChip.hidden = YES;
    return;
  }
  _measureChipLabel.stringValue = text;
  [_measureChipLabel sizeToFit];
  const NSSize textSize = _measureChipLabel.frame.size;
  const CGFloat padX = 9, padY = 4;
  _measureChip.frame = NSMakeRect(0, 0, textSize.width + padX * 2,
                                  textSize.height + padY * 2);
  _measureChipLabel.frame = NSMakeRect(padX, padY, textSize.width, textSize.height);
  [self positionMeasureChip];
}

// Places the chip just above the midpoint of the measurement, in view points.
- (void)positionMeasureChip {
  if (_headless || !_measureChip) return;
  if (!_hasMeasureLine || _measureChipLabel.stringValue.length == 0) {
    _measureChip.hidden = YES;
    return;
  }
  const simd_float3 midpoint = (_measurePoints[0] + _measurePoints[1]) * 0.5f;
  const simd_float4 clip =
      simd_mul(_lastViewProjection, simd_make_float4(midpoint, 1.0f));
  if (clip.w <= 1e-6f) {  // behind the camera
    _measureChip.hidden = YES;
    return;
  }

  const CGSize drawable = self.drawableSize;
  if (drawable.width < 1 || drawable.height < 1) return;
  const simd_float2 pixel = [self projectWorldPoint:midpoint inSize:drawable];
  const CGFloat scaleX = drawable.width / std::max(self.bounds.size.width, CGFloat(1));
  const CGFloat scaleY = drawable.height / std::max(self.bounds.size.height, CGFloat(1));

  NSRect frame = _measureChip.frame;
  frame.origin.x = pixel.x / scaleX - frame.size.width * 0.5;
  // Metal texture space is top-left origin; AppKit is bottom-left.
  frame.origin.y = self.bounds.size.height - pixel.y / scaleY + 12.0;

  frame.origin.x = std::clamp(frame.origin.x, CGFloat(4),
                              self.bounds.size.width - frame.size.width - 4);
  frame.origin.y = std::clamp(frame.origin.y, CGFloat(4),
                              self.bounds.size.height - frame.size.height - 4);
  _measureChip.frame = frame;
  _measureChip.hidden = NO;
}

- (void)layoutToolbar {
  if (_headless || !_modeControl) return;

  // Align to the real window buttons rather than guessing an inset: this puts
  // the controls on the same baseline as the traffic lights and follows them
  // if macOS ever moves them.
  CGFloat left = 92, centreY = self.bounds.size.height - 26;
  NSButton *zoom = [self.window standardWindowButton:NSWindowZoomButton];
  if (zoom && zoom.superview) {
    const NSRect z = [self convertRect:zoom.bounds fromView:zoom];
    left = NSMaxX(z) + 18;
    centreY = NSMidY(z);
  }

  const CGFloat gap = 10;
  CGFloat x = left;
  for (NSSegmentedControl *control in
       @[ _modeControl, _frameControl, _orientationControl ]) {
    [control sizeToFit];
    NSRect f = control.frame;
    f.origin.x = x;
    f.origin.y = centreY - f.size.height * 0.5;
    control.frame = f;
    x += f.size.width + gap;
  }
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [self layoutToolbar];
  // Resizing changes the aspect, which can push a framed model out of view.
  // Refit only while the camera is still the one we chose, so this never
  // fights a camera the user has moved themselves.
  if (_doc && !_userNavigated) {
    [self fitToCurrentOrientation];
    [self setNeedsDisplay:YES];
  }
}

- (void)modeControlChanged:(NSSegmentedControl *)sender {
  self.mode = (CADInteractionMode)sender.selectedSegment;
}

- (void)frameControlPressed:(id)sender { [self frameModel]; }

- (void)orientationControlPressed:(NSSegmentedControl *)sender {
  [self applyStandardView:0];  // the cube covers the six named faces
}

// eye = target + d*(cos(el)cos(az), cos(el)sin(az), sin(el)), so each viewpoint
// is just the azimuth/elevation that puts the eye on the wanted axis.
- (void)applyStandardView:(NSInteger)index {
  static const char *names[] = {"iso",  "front", "top",   "back",
                                "right", "left",  "back",  "bottom"};
  switch (index) {
    case 1: _azimuth = -float(M_PI_2); _elevation = 0.0f; break;   // front, -Y
    case 2: _azimuth = -float(M_PI_2); _elevation = 1.55f; break;  // top, +Z
    case 3: _azimuth = 0.0f; _elevation = 0.0f; break;             // right, +X
    case 4: _azimuth = 0.0f; _elevation = 0.0f; break;             // right, +X
    case 5: _azimuth = float(M_PI); _elevation = 0.0f; break;      // left, -X
    case 6: _azimuth = float(M_PI_2); _elevation = 0.0f; break;    // back, +Y
    case 7: _azimuth = -float(M_PI_2); _elevation = -1.55f; break; // bottom, -Z
    default: _azimuth = -0.9f; _elevation = 0.5f; break;           // iso
  }
  [self fitToCurrentOrientation];
  _userNavigated = NO;
  [self setNeedsDisplay:YES];
  const NSInteger clamped = std::clamp<NSInteger>(index, 0, 7);
  [self report:[NSString stringWithFormat:@"%s view", names[clamped]]];
}

// The pointer is over a control, not the model.
- (BOOL)pointIsOverToolbar:(NSPoint)point {
  if (_headless || !_modeControl) return NO;
  for (NSSegmentedControl *control in
       @[ _modeControl, _frameControl, _orientationControl ])
    if (NSPointInRect(point, control.frame)) return YES;
  return NO;  // the chip passes clicks through, so it is not listed
}

#pragma mark - Loading

- (BOOL)loadDocumentAtPath:(NSString *)path error:(NSString **)outError {
  std::string err;
  auto doc = cadcore::Document::load(path.UTF8String, err);
  if (!doc) {
    if (outError) *outError = [NSString stringWithUTF8String:err.c_str()];
    return NO;
  }

  const cadcore::RenderMesh &mesh = doc->renderMesh();
  if (mesh.empty()) {
    if (outError) *outError = @"file loaded but produced no geometry";
    return NO;
  }

  // Assign before uploading: uploadMeshBuffers reads _doc.
  _doc = std::move(doc);
  [self uploadMeshBuffers];

  _selection.clear();
  [self uploadSelectionFlags];

  [self frameModel];

  const auto &s = _doc->stats();
  [self report:[NSString stringWithFormat:
      @"%s  ·  %d faces  ·  %zu triangles  ·  %s",
      _doc->format().id.c_str(), s.faces, mesh.indices.size() / 3,
      _doc->caps().exactGeometry ? "exact measurement"
                                 : "mesh only — measurements approximate"]];
  [self setNeedsDisplay:YES];
  return YES;
}

- (void)uploadMeshBuffers {
  if (!_doc) return;
  const cadcore::RenderMesh &mesh = _doc->renderMesh();
  _vertexBuffer = [self.device
      newBufferWithBytes:mesh.vertices.data()
                  length:mesh.vertices.size() * sizeof(cadcore::RenderVertex)
                 options:MTLResourceStorageModeShared];
  _indexBuffer = [self.device
      newBufferWithBytes:mesh.indices.data()
                  length:mesh.indices.size() * sizeof(uint32_t)
                 options:MTLResourceStorageModeShared];
  _indexCount = mesh.indices.size();

  _edgeIndexCount = mesh.edgeIndices.size();
  if (_edgeIndexCount > 0) {
    _edgeVertexBuffer = [self.device
        newBufferWithBytes:mesh.edgePositions.data()
                    length:mesh.edgePositions.size() * sizeof(float)
                   options:MTLResourceStorageModeShared];
    _edgeIndexBuffer = [self.device
        newBufferWithBytes:mesh.edgeIndices.data()
                    length:mesh.edgeIndices.size() * sizeof(uint32_t)
                   options:MTLResourceStorageModeShared];
    _edgeIdBuffer = [self.device
        newBufferWithBytes:mesh.edgeIds.data()
                    length:mesh.edgeIds.size() * sizeof(uint32_t)
                   options:MTLResourceStorageModeShared];
  }

  // One flag per entity, so a multi-selection of any size highlights without
  // the shader needing to know how many things are selected.
  _faceCount = std::max<NSUInteger>(mesh.faces.size(), 1);
  _edgeCount = std::max<NSUInteger>(mesh.edgeCount, 1);
  _faceSelectedBuffer = [self.device newBufferWithLength:_faceCount * sizeof(uint32_t)
                                                 options:MTLResourceStorageModeShared];
  _edgeSelectedBuffer = [self.device newBufferWithLength:_edgeCount * sizeof(uint32_t)
                                                 options:MTLResourceStorageModeShared];
}

- (void)frameModel {
  if (!_doc) return;
  const auto &b = _doc->bounds();
  if (!b.valid) return;

  _modelCenter = simd_make_float3((b.min[0] + b.max[0]) * 0.5f,
                                  (b.min[1] + b.max[1]) * 0.5f,
                                  (b.min[2] + b.max[2]) * 0.5f);
  const auto extent = b.size();
  _modelRadius = 0.5f * std::sqrt(float(extent[0] * extent[0] +
                                        extent[1] * extent[1] +
                                        extent[2] * extent[2]));
  if (_modelRadius <= 0) _modelRadius = 1.0f;

  [self fitToCurrentOrientation];
  _userNavigated = NO;
  [self setNeedsDisplay:YES];
}

// Fits the bounding box as it actually projects, rather than the bounding
// sphere. A sphere fit both overflows (it needs R/sin(fov/2), not an arbitrary
// multiple of R) and wastes the whole width on a long thin part, which is
// exactly the case that looks broken.
- (void)fitToCurrentOrientation {
  const CGFloat h = std::max(self.bounds.size.height, CGFloat(1));
  [self fitToCurrentOrientationWithAspect:float(self.bounds.size.width / h)];
}

- (void)fitToCurrentOrientationWithAspect:(float)aspect {
  if (!_doc) return;
  const auto &b = _doc->bounds();
  if (!b.valid) return;

  const float cosE = std::cos(_elevation), sinE = std::sin(_elevation);
  const simd_float3 toEye =
      simd_make_float3(cosE * std::cos(_azimuth), cosE * std::sin(_azimuth), sinE);
  const simd_float3 forward = -toEye;
  simd_float3 right = simd_cross(forward, simd_make_float3(0, 0, 1));
  right = simd_length(right) < 1e-5f ? simd_make_float3(1, 0, 0)
                                     : simd_normalize(right);
  const simd_float3 up = simd_cross(right, forward);

  float minX = INFINITY, maxX = -INFINITY;
  float minY = INFINITY, maxY = -INFINITY;
  float minZ = INFINITY, maxZ = -INFINITY;
  for (int corner = 0; corner < 8; ++corner) {
    const simd_float3 point = simd_make_float3(
        float((corner & 1) ? b.max[0] : b.min[0]),
        float((corner & 2) ? b.max[1] : b.min[1]),
        float((corner & 4) ? b.max[2] : b.min[2]));
    const simd_float3 v = point - _modelCenter;
    const float x = simd_dot(v, right), y = simd_dot(v, up),
                z = simd_dot(v, forward);
    minX = std::min(minX, x); maxX = std::max(maxX, x);
    minY = std::min(minY, y); maxY = std::max(maxY, y);
    minZ = std::min(minZ, z); maxZ = std::max(maxZ, z);
  }

  // Aim at the centre of the projected extents so the part sits centred even
  // when the box is lopsided about its own centre.
  _target = _modelCenter + right * ((minX + maxX) * 0.5f) +
            up * ((minY + maxY) * 0.5f) + forward * ((minZ + maxZ) * 0.5f);

  const float halfWidth = (maxX - minX) * 0.5f;
  const float halfHeight = (maxY - minY) * 0.5f;
  const float halfDepth = (maxZ - minZ) * 0.5f;

  aspect = std::max(aspect, 0.1f);
  const float tanY = std::tan(kFovYDegrees * 0.5f * float(M_PI) / 180.0f);
  const float tanX = tanY * aspect;

  // Distance to the *near* face, so the closest part of the model still fits
  // inside the frustum angle; then a little breathing room.
  constexpr float kFitMargin = 1.08f;
  _distance = std::max(halfHeight / tanY, halfWidth / tanX) * kFitMargin +
              halfDepth;
  _distance = std::max(_distance, 1e-4f);
}

- (void)report:(NSString *)text {
  if (self.statusHandler) self.statusHandler(text);
}

#pragma mark - Settings

+ (NSArray<NSString *> *)unitNames {
  return @[ @"Millimetres", @"Centimetres", @"Metres", @"Inches" ];
}
+ (NSArray<NSString *> *)shadingNames {
  return @[ @"Shaded with edges", @"Shaded", @"Wireframe" ];
}
+ (NSArray<NSString *> *)qualityNames {
  return @[ @"Draft", @"Normal", @"Fine" ];
}

- (cadcore::Unit)unit {
  switch (_unitStyle) {
    case 1: return cadcore::Unit::Centimetres;
    case 2: return cadcore::Unit::Metres;
    case 3: return cadcore::Unit::Inches;
    default: return cadcore::Unit::Millimetres;
  }
}

- (NSString *)formatLength:(double)millimetres {
  return @(cadcore::formatLength(millimetres, [self unit]).c_str());
}

- (void)setUnitStyle:(NSInteger)style {
  _unitStyle = style;
  [NSUserDefaults.standardUserDefaults setInteger:style forKey:@"UnitStyle"];
  // Re-state whatever is on screen in the new unit.
  if (_hasMeasureLine)
    [self setMeasureChipText:[self formatLength:_lastMeasuredDistance]];
  [self setNeedsDisplay:YES];
}

- (void)setShowViewCube:(BOOL)show {
  _showViewCube = show;
  [NSUserDefaults.standardUserDefaults setBool:show forKey:@"ShowViewCube"];
  [self setNeedsDisplay:YES];
}

- (void)setShadingMode:(NSInteger)mode {
  _shadingMode = mode;
  [NSUserDefaults.standardUserDefaults setInteger:mode forKey:@"ShadingMode"];
  [self setNeedsDisplay:YES];
}

- (void)setTessellationQuality:(NSInteger)quality {
  _tessellationQuality = quality;
  [NSUserDefaults.standardUserDefaults setInteger:quality forKey:@"TessellationQuality"];
  if (!_doc) return;
  // Draft is coarser and faster; fine is denser and slower. The mesh has to be
  // rebuilt and re-uploaded, so this is the one setting that costs real time.
  static const double multipliers[] = {3.0, 1.0, 0.35};
  _doc->retessellate(multipliers[std::clamp<NSInteger>(quality, 0, 2)]);
  [self uploadMeshBuffers];
  [self setNeedsDisplay:YES];
}

// Not every GPU offers every level - Apple silicon tops out at 4x, and asking
// for 8x there does not fail gracefully, it trips a Metal validation assertion
// and takes the process with it. So the choice is always filtered through what
// the device reports.
+ (NSArray<NSNumber *> *)supportedSampleCountsForDevice:(id<MTLDevice>)device {
  NSMutableArray<NSNumber *> *out = [NSMutableArray array];
  for (NSNumber *n in @[ @1, @2, @4, @8 ])
    if ([device supportsTextureSampleCount:n.unsignedIntegerValue])
      [out addObject:n];
  return out;
}

+ (NSUInteger)supportedSampleCountAtMost:(NSUInteger)wanted
                               forDevice:(id<MTLDevice>)device {
  NSUInteger best = 1;
  for (NSNumber *n in [self supportedSampleCountsForDevice:device]) {
    const NSUInteger value = n.unsignedIntegerValue;
    if (value <= wanted && value > best) best = value;
  }
  return best;
}

- (NSArray<NSNumber *> *)supportedAntialiasingSamples {
  return [CADView supportedSampleCountsForDevice:self.device];
}

- (void)setAntialiasingSamples:(NSInteger)samples {
  if (samples != 1 && samples != 2 && samples != 4 && samples != 8) samples = 4;
  samples = (NSInteger)[CADView supportedSampleCountAtMost:(NSUInteger)samples
                                                 forDevice:self.device];
  _antialiasingSamples = samples;
  [NSUserDefaults.standardUserDefaults setInteger:samples forKey:@"AntialiasingSamples"];
  if ((NSUInteger)samples == _sampleCount) return;

  // Sample count is baked into every pipeline and every multisampled texture,
  // so both have to be rebuilt.
  _sampleCount = (NSUInteger)samples;
  self.sampleCount = _sampleCount;
  _faceIdTexture = nil;
  _depthTexture = nil;
  [self buildPipelines];
  [self setNeedsDisplay:YES];
}

- (void)applyStoredSettings {
  NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
  _unitStyle = [d integerForKey:@"UnitStyle"];
  _shadingMode = [d integerForKey:@"ShadingMode"];
  _tessellationQuality = [d objectForKey:@"TessellationQuality"]
                             ? [d integerForKey:@"TessellationQuality"]
                             : 1;  // Normal
  _showViewCube = [d objectForKey:@"ShowViewCube"] ? [d boolForKey:@"ShowViewCube"]
                                                   : YES;
  _antialiasingSamples = (NSInteger)_sampleCount;
}

#pragma mark - Background

+ (NSArray<NSString *> *)backgroundNames {
  return @[ @"Automatic", @"Studio Dark", @"Studio Light", @"Midnight",
            @"Blueprint", @"Sunset" ];
}

- (void)previewBackgroundStyle:(NSInteger)style {
  _backgroundStyle = style;
  [self applyChromeAppearance];
  [self setNeedsDisplay:YES];
}

- (void)setBackgroundStyle:(NSInteger)style {
  _backgroundStyle = style;
  [NSUserDefaults.standardUserDefaults setInteger:style forKey:@"BackgroundStyle"];
  [self applyChromeAppearance];
  [self setNeedsDisplay:YES];
}

// Returns the gradient and the tone the model is shaded against. The part has
// to stay readable on every one of these, so the base colour moves with the
// ground rather than staying fixed.
- (void)backgroundTop:(simd_float4 *)top
               bottom:(simd_float4 *)bottom
                model:(simd_float4 *)model {
  NSInteger style = _backgroundStyle;
  if (style == 0) style = [self isDarkMode] ? 1 : 2;

  switch (style) {
    case 2:  // Studio Light
      *top = simd_make_float4(0.925f, 0.937f, 0.953f, 1);
      *bottom = simd_make_float4(0.784f, 0.804f, 0.835f, 1);
      *model = simd_make_float4(0.700f, 0.722f, 0.760f, 1);
      break;
    case 3:  // Midnight
      *top = simd_make_float4(0.055f, 0.059f, 0.070f, 1);
      *bottom = simd_make_float4(0.016f, 0.018f, 0.024f, 1);
      *model = simd_make_float4(0.780f, 0.800f, 0.830f, 1);
      break;
    case 4:  // Blueprint
      *top = simd_make_float4(0.055f, 0.180f, 0.400f, 1);
      *bottom = simd_make_float4(0.020f, 0.078f, 0.200f, 1);
      *model = simd_make_float4(0.870f, 0.910f, 0.980f, 1);
      break;
    case 5:  // Sunset
      *top = simd_make_float4(0.980f, 0.560f, 0.520f, 1);
      *bottom = simd_make_float4(0.420f, 0.240f, 0.520f, 1);
      *model = simd_make_float4(0.930f, 0.900f, 0.900f, 1);
      break;
    default:  // Studio Dark
      *top = simd_make_float4(0.180f, 0.196f, 0.223f, 1);
      *bottom = simd_make_float4(0.094f, 0.102f, 0.118f, 1);
      *model = simd_make_float4(0.780f, 0.800f, 0.830f, 1);
      break;
  }
}

#pragma mark - Appearance

// Rec. 601 luma of the gradient at one end. The toolbar sits against the top of
// the gradient and the status line against the bottom, and on a background like
// Sunset those two ends disagree, so they are asked separately.
- (BOOL)groundIsDarkNearTop {
  simd_float4 top, bottom, model;
  [self backgroundTop:&top bottom:&bottom model:&model];
  return (0.299f * top.x + 0.587f * top.y + 0.114f * top.z) < 0.5f;
}

- (BOOL)groundIsDarkNearBottom {
  simd_float4 top, bottom, model;
  [self backgroundTop:&top bottom:&bottom model:&model];
  return (0.299f * bottom.x + 0.587f * bottom.y + 0.114f * bottom.z) < 0.5f;
}

// The floating controls draw a native bezel, which by default follows the
// system theme. That is the wrong signal here: the background is a scene the
// user picks independently, so a light scene under a dark system theme left
// white labels on a near-white ground, invisible. Force the appearance that
// contrasts with what is actually behind them.
- (void)applyChromeAppearance {
  NSAppearance *forTop = [NSAppearance
      appearanceNamed:[self groundIsDarkNearTop] ? NSAppearanceNameDarkAqua
                                                 : NSAppearanceNameAqua];
  for (NSSegmentedControl *control in
       @[ _modeControl ?: (id)NSNull.null, _frameControl ?: (id)NSNull.null,
          _orientationControl ?: (id)NSNull.null ]) {
    if ([control isKindOfClass:NSSegmentedControl.class]) control.appearance = forTop;
  }
  [self applyChipAppearance];
  if (self.appearanceHandler) self.appearanceHandler();
}

- (BOOL)isDarkMode {
  NSAppearanceName name = [self.effectiveAppearance
      bestMatchFromAppearancesWithNames:@[
        NSAppearanceNameAqua, NSAppearanceNameDarkAqua
      ]];
  return [name isEqualToString:NSAppearanceNameDarkAqua];
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [self layoutToolbar];  // the window buttons only exist once we have a window
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  [self applyChromeAppearance];
  [self setNeedsDisplay:YES];
}

#pragma mark - Camera

- (simd_float3)eyePosition {
  const float ce = std::cos(_elevation), se = std::sin(_elevation);
  return _target + simd_make_float3(_distance * ce * std::cos(_azimuth),
                                    _distance * ce * std::sin(_azimuth),
                                    _distance * se);
}

- (Uniforms)uniformsForAspect:(float)aspect {
  const simd_float3 eye = [self eyePosition];
  // Fit near/far to the model's bounding sphere as seen from the eye. Deriving
  // them from _distance assumes the pivot sits on the model, which stops being
  // true the moment you pan (or zoom toward the cursor) - and then the near
  // plane slices through the geometry. Keep the ratio tight for depth
  // precision, but never at the cost of clipping the part.
  const simd_float3 viewDirection = simd_normalize(_target - eye);
  const float centreDepth = simd_dot(_modelCenter - eye, viewDirection);
  const float margin = std::max(_modelRadius * 1.05f, 1e-4f);
  float far = centreDepth + margin;
  if (far <= 1e-4f) far = 1e-4f;  // model entirely behind the camera
  const float near = std::max(centreDepth - margin, far * 5e-4f);
  const simd_float4x4 proj =
      makePerspective(kFovYDegrees * float(M_PI) / 180.0f, aspect, near, far);
  const simd_float4x4 view = makeLookAt(eye, _target, simd_make_float3(0, 0, 1));

  Uniforms u{};
  u.modelViewProjection = simd_mul(proj, view);
  // Screen-space edge and marker sizes must be relative to the surface being
  // drawn. Using the window's drawable for an offscreen render of a different
  // size gives the wrong line weight.
  const CGSize ds = _renderSizeOverride.width > 0 ? _renderSizeOverride
                                                  : self.drawableSize;
  u.viewport = simd_make_float4(float(ds.width), float(ds.height), 1.1f, 4.5f);

  // The cube shows the camera's orientation, so it takes the view matrix with
  // translation dropped. Placed by pixels so it stays square at any aspect.
  simd_float4x4 orientation = view;
  orientation.columns[3] = simd_make_float4(0, 0, 0, 1);
  u.cubeOrientation = orientation;
  const float cubePixels = 78.0f * float(ds.height) / 950.0f;
  const float marginPixels = 30.0f * float(ds.height) / 950.0f;
  const float halfW = cubePixels / (float(ds.width) * 0.5f);
  const float halfH = cubePixels / (float(ds.height) * 0.5f);
  u.cubePlacement = simd_make_float4(
      1.0f - (marginPixels + cubePixels) / (float(ds.width) * 0.5f),
      1.0f - (marginPixels + cubePixels) / (float(ds.height) * 0.5f),
      halfW, halfH);
  const simd_float3 light = simd_normalize(simd_make_float3(0.4f, -0.7f, 0.9f));
  u.lightDirection = simd_make_float4(light.x, light.y, light.z, 0.0f);
  [self backgroundTop:&u.backgroundTop
               bottom:&u.backgroundBottom
                model:&u.baseColor];
  u.shadingMode = (unsigned int)_shadingMode;
  u.selectedEntityId = FACE_ID_NONE;  // selection is per-entity flags now
  u.hoverEntityId = _hoverEntity;
  _lastViewProjection = u.modelViewProjection;
  return u;
}

#pragma mark - Drawing

// Metal rejects MTLTextureType2DMultisample with a sampleCount of 1, so with
// anti-aliasing off every attachment in the pass has to be a plain 2D texture.
// One place decides it, because the colour, identity and depth attachments of a
// pass must agree with each other and with the pipeline's rasterSampleCount.
- (void)applySampleCountTo:(MTLTextureDescriptor *)d {
  if (_sampleCount > 1) {
    d.textureType = MTLTextureType2DMultisample;
    d.sampleCount = _sampleCount;
  }
}

- (void)ensureFaceIdTextureOfSize:(CGSize)size {
  if (_faceIdTexture && _faceIdTexture.width == (NSUInteger)size.width &&
      _faceIdTexture.height == (NSUInteger)size.height)
    return;
  MTLTextureDescriptor *d = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint
                                   width:(NSUInteger)size.width
                                  height:(NSUInteger)size.height
                               mipmapped:NO];
  [self applySampleCountTo:d];
  d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  d.storageMode = MTLStorageModePrivate;
  _faceIdTexture = [self.device newTextureWithDescriptor:d];

  MTLTextureDescriptor *dz = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                   width:(NSUInteger)size.width
                                  height:(NSUInteger)size.height
                               mipmapped:NO];
  [self applySampleCountTo:dz];
  dz.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  dz.storageMode = MTLStorageModePrivate;
  _depthTexture = [self.device newTextureWithDescriptor:dz];
}

- (void)encodeSceneInto:(id<MTLRenderCommandEncoder>)enc uniforms:(Uniforms)u {
  if (!_transparentBackground) {
    [enc setRenderPipelineState:_backgroundPipeline];
    [enc setDepthStencilState:_depthAlways];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:1];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  }

  if (_indexCount > 0) {
    [enc setRenderPipelineState:_shadedPipeline];
    [enc setDepthStencilState:_depthLess];
    [enc setCullMode:MTLCullModeNone];
    // OCCT emits counter-clockwise triangles; Metal defaults to clockwise, so
    // without this every face reads as back-facing and the shader inverts
    // every normal.
    [enc setFrontFacingWinding:MTLWindingCounterClockwise];
    // Push surfaces away from the eye so coplanar feature edges win the depth
    // test. Slope-scaled, so steeply-viewed and curved faces get proportionally
    // more offset - a fixed epsilon cannot cover both.
    [enc setDepthBias:24.0f slopeScale:6.0f clamp:0.0f];
    [enc setVertexBuffer:_vertexBuffer offset:0 atIndex:0];
    [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
    [enc setVertexBuffer:_faceSelectedBuffer offset:0 atIndex:2];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:1];
    [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                    indexCount:_indexCount
                     indexType:MTLIndexTypeUInt32
                   indexBuffer:_indexBuffer
             indexBufferOffset:0];
  }

  // Markers: the measurement ends, plus the live snap preview.
  int markerCount = 0;
  float packed[12] = {0};
  for (int i = 0; i < _refCount && i < 2; ++i) {
    packed[markerCount * 3 + 0] = _measurePoints[i].x;
    packed[markerCount * 3 + 1] = _measurePoints[i].y;
    packed[markerCount * 3 + 2] = _measurePoints[i].z;
    markerCount++;
  }
  const int placedMarkers = markerCount;
  if (_hasSnapPreview) {
    packed[markerCount * 3 + 0] = _snapPreview.x;
    packed[markerCount * 3 + 1] = _snapPreview.y;
    packed[markerCount * 3 + 2] = _snapPreview.z;
    markerCount++;
  }
  if (markerCount > 0)
    memcpy(_markerBuffer.contents, packed, sizeof(float) * 3 * markerCount);

  // "Shaded" hides the feature edges; the other two modes draw them.
  if (_edgeIndexCount > 0 && _shadingMode != 1) {
    [enc setRenderPipelineState:_edgePipeline];
    [enc setDepthStencilState:_depthLessEqual];
    // Depth offset is applied in the vertex shader; keep the fixed-function
    // bias off so the two do not compound.
    [enc setDepthBias:0.0f slopeScale:0.0f clamp:0.0f];
    [enc setVertexBuffer:_edgeVertexBuffer offset:0 atIndex:0];
    [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
    [enc setVertexBuffer:_edgeIndexBuffer offset:0 atIndex:2];
    [enc setVertexBuffer:_edgeIdBuffer offset:0 atIndex:3];
    [enc setVertexBuffer:_edgeSelectedBuffer offset:0 atIndex:4];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:1];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle
            vertexStart:0
            vertexCount:(_edgeIndexCount / 2) * 6];
  }

  if (_hasMeasureLine && _measureLinePipeline) {
    Uniforms lineUniforms = u;
    lineUniforms.markerColor = simd_make_float4(1.00f, 0.58f, 0.16f, 1.0f);
    [enc setRenderPipelineState:_measureLinePipeline];
    [enc setDepthStencilState:_depthAlways];
    [enc setVertexBuffer:_markerBuffer offset:0 atIndex:0];
    [enc setVertexBytes:&lineUniforms length:sizeof(lineUniforms) atIndex:1];
    [enc setFragmentBytes:&lineUniforms length:sizeof(lineUniforms) atIndex:1];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
  }

  if (markerCount > 0 && _markerPipeline) {
    [enc setRenderPipelineState:_markerPipeline];
    [enc setDepthStencilState:_depthAlways];
    [enc setVertexBuffer:_markerBuffer offset:0 atIndex:0];

    if (placedMarkers > 0) {
      Uniforms placed = u;
      placed.markerColor = simd_make_float4(1.00f, 0.58f, 0.16f, 1.0f);
      [enc setVertexBytes:&placed length:sizeof(placed) atIndex:1];
      [enc setFragmentBytes:&placed length:sizeof(placed) atIndex:1];
      [enc drawPrimitives:MTLPrimitiveTypeTriangle
              vertexStart:0
              vertexCount:placedMarkers * 6];
    }
    if (_hasSnapPreview) {
      // Cyan, so the live snap target reads as a suggestion rather than a
      // placed measurement.
      Uniforms preview = u;
      preview.markerColor = simd_make_float4(0.30f, 0.80f, 1.00f, 1.0f);
      [enc setVertexBytes:&preview length:sizeof(preview) atIndex:1];
      [enc setFragmentBytes:&preview length:sizeof(preview) atIndex:1];
      [enc drawPrimitives:MTLPrimitiveTypeTriangle
              vertexStart:placedMarkers * 6
              vertexCount:6];
    }
  }

  // The cube belongs to the app window only. A QuickLook preview is for
  // looking at the part, and a thumbnail is an image of the part - neither
  // wants a UI widget baked into it.
  if (_cubePipeline && _showViewCube && !_headless && !_navigationOnly) {
    [enc setRenderPipelineState:_cubePipeline];
    [enc setDepthStencilState:_depthLess];
    [enc setCullMode:MTLCullModeNone];
    [enc setDepthBias:0.0f slopeScale:0.0f clamp:0.0f];
    [enc setVertexBuffer:_cubeBuffer offset:0 atIndex:0];
    [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:1];
    [enc setFragmentTexture:_cubeLabels atIndex:0];
    [enc setFragmentSamplerState:_cubeSampler atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:36];
  }
}

- (CGImageRef)renderImageOfSize:(CGSize)size CF_RETURNS_RETAINED {

  const NSUInteger w = (NSUInteger)size.width, h = (NSUInteger)size.height;

  MTLTextureDescriptor *msaa = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:w height:h mipmapped:NO];
  [self applySampleCountTo:msaa];
  msaa.usage = MTLTextureUsageRenderTarget;
  msaa.storageMode = MTLStorageModePrivate;
  id<MTLTexture> colorMS =
      _sampleCount > 1 ? [self.device newTextureWithDescriptor:msaa] : nil;

  MTLTextureDescriptor *cd = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:w height:h mipmapped:NO];
  cd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  cd.storageMode = MTLStorageModeShared;
  id<MTLTexture> color = [self.device newTextureWithDescriptor:cd];

  [self ensureFaceIdTextureOfSize:size];

  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  // With one sample the pass draws straight into the readable texture; there is
  // no separate multisample target to resolve out of.
  pass.colorAttachments[0].texture = colorMS ?: color;
  pass.colorAttachments[0].resolveTexture = colorMS ? color : nil;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  pass.colorAttachments[0].storeAction =
      colorMS ? MTLStoreActionMultisampleResolve : MTLStoreActionStore;
  pass.colorAttachments[1].texture = _faceIdTexture;
  pass.colorAttachments[1].loadAction = MTLLoadActionClear;
  pass.colorAttachments[1].storeAction = MTLStoreActionStore;
  pass.colorAttachments[1].clearColor = MTLClearColorMake(FACE_ID_NONE, 0, 0, 0);
  pass.depthAttachment.texture = _depthTexture;
  pass.depthAttachment.loadAction = MTLLoadActionClear;
  pass.depthAttachment.clearDepth = 1.0;
  pass.depthAttachment.storeAction = MTLStoreActionStore;

  // Frame and rasterise for the output size; the window's is irrelevant here.
  _renderSizeOverride = size;
  [self fitToCurrentOrientationWithAspect:float(size.width / size.height)];

  Uniforms u = [self uniformsForAspect:float(size.width / size.height)];
  id<MTLCommandBuffer> cmd = [_queue commandBuffer];
  id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
  [self encodeSceneInto:enc uniforms:u];
  [enc endEncoding];
  [cmd commit];
  [cmd waitUntilCompleted];

  // Passing NULL lets CoreGraphics own the backing store. Supplying our own
  // buffer produced a CGImage that referenced memory freed when this method
  // returned - harmless when the image is written to disk immediately, fatal
  // for the QuickLook extension, whose drawing block runs much later.
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  // Model pixels are written opaque and everything else stays cleared, so the
  // premultiplied reading is correct and preserves the transparent surround.
  const uint32_t alphaInfo = _transparentBackground
                                 ? kCGImageAlphaPremultipliedFirst
                                 : kCGImageAlphaNoneSkipFirst;
  CGContextRef ctx = CGBitmapContextCreate(
      NULL, w, h, 8, w * 4, cs, alphaInfo | kCGBitmapByteOrder32Little);
  if (!ctx) {
    CGColorSpaceRelease(cs);
    return NULL;
  }
  [color getBytes:CGBitmapContextGetData(ctx)
      bytesPerRow:CGBitmapContextGetBytesPerRow(ctx)
       fromRegion:MTLRegionMake2D(0, 0, w, h)
      mipmapLevel:0];
  CGImageRef image = CGBitmapContextCreateImage(ctx);

  CGContextRelease(ctx);
  CGColorSpaceRelease(cs);
  return image;  // caller owns it
}

- (BOOL)renderOffscreenToPNG:(NSString *)path
                        size:(CGSize)size
                       error:(NSString **)outError {
  CGImageRef image = [self renderImageOfSize:size];
  if (!image) {
    if (outError) *outError = @"render failed";
    return NO;
  }
  CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
      (__bridge CFURLRef)[NSURL fileURLWithPath:path],
      (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
  BOOL ok = NO;
  if (dest) {
    CGImageDestinationAddImage(dest, image, NULL);
    ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
  }
  CGImageRelease(image);
  if (!ok && outError) *outError = @"failed to write PNG";
  return ok;
}

- (uint32_t)pickFaceHeadlessAtX:(uint32_t)x y:(uint32_t)y size:(CGSize)size {
  // Frame for the same size the render uses, or pick coordinates and rendered
  // pixels refer to different cameras.
  [self fitToCurrentOrientationWithAspect:float(size.width / size.height)];
  _renderSizeOverride = size;
  [self ensureFaceIdTextureOfSize:size];

  MTLTextureDescriptor *cd = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:(NSUInteger)size.width
                                  height:(NSUInteger)size.height
                               mipmapped:NO];
  [self applySampleCountTo:cd];
  cd.usage = MTLTextureUsageRenderTarget;
  cd.storageMode = MTLStorageModePrivate;
  id<MTLTexture> color = [self.device newTextureWithDescriptor:cd];

  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = color;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].storeAction = MTLStoreActionDontCare;
  pass.colorAttachments[1].texture = _faceIdTexture;
  pass.colorAttachments[1].loadAction = MTLLoadActionClear;
  pass.colorAttachments[1].storeAction = MTLStoreActionStore;
  pass.colorAttachments[1].clearColor = MTLClearColorMake(FACE_ID_NONE, 0, 0, 0);
  // Must be the owned texture, and stored: the resolve pass samples it.
  pass.depthAttachment.texture = _depthTexture;
  pass.depthAttachment.loadAction = MTLLoadActionClear;
  pass.depthAttachment.clearDepth = 1.0;
  pass.depthAttachment.storeAction = MTLStoreActionStore;

  Uniforms u = [self uniformsForAspect:float(size.width / size.height)];
  id<MTLCommandBuffer> cmd = [_queue commandBuffer];
  id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
  [self encodeSceneInto:enc uniforms:u];
  [enc endEncoding];
  [self encodePickResolveInto:cmd atX:x y:y];
  [cmd commit];
  [cmd waitUntilCompleted];

  uint32_t picked = FACE_ID_NONE;
  memcpy(&picked, _pickBuffer.contents, sizeof(uint32_t));
  return picked;
}

// Sweeps zoom and pan and checks the model's bounding sphere stays inside the
// frustum. A near plane derived from _distance fails this as soon as the pivot
// leaves the model, which is what sliced the part open on screen.
- (NSString *)clipReport {
  NSMutableString *out = [NSMutableString string];
  int failures = 0;
  float worstNear = INFINITY, worstFar = INFINITY;

  const float zooms[] = {0.5f, 1.0f, 2.0f, 5.0f, 12.0f, 30.0f};
  const float pans[] = {0.0f, 0.5f, 1.5f, 4.0f};
  const simd_float3 savedTarget = _target;
  const float savedDistance = _distance;

  for (float z : zooms) {
    for (float panFactor : pans) {
      _distance = _modelRadius * z;
      _target = _modelCenter + simd_make_float3(1, 0, 0) * _modelRadius * panFactor;
      Uniforms u = [self uniformsForAspect:1.5f];
      (void)u;

      const simd_float3 eye = [self eyePosition];
      const simd_float3 viewDirection = simd_normalize(_target - eye);
      const float centreDepth = simd_dot(_modelCenter - eye, viewDirection);
      const float margin = std::max(_modelRadius * 1.05f, 1e-4f);
      float far = centreDepth + margin;
      if (far <= 1e-4f) far = 1e-4f;
      const float near = std::max(centreDepth - margin, far * 5e-4f);

      // The sphere must sit inside [near, far] whenever the eye is outside it.
      const float frontOfModel = centreDepth - _modelRadius;
      const float backOfModel = centreDepth + _modelRadius;
      // Eye on or inside the bounding sphere: near clipping is unavoidable there.
      if (frontOfModel <= _modelRadius * 1e-3f) continue;
      const float nearMargin = frontOfModel - near;
      const float farMargin = far - backOfModel;
      worstNear = std::min(worstNear, nearMargin);
      worstFar = std::min(worstFar, farMargin);
      if (nearMargin < 0 || farMargin < 0) {
        failures++;
        [out appendFormat:@"  CLIP at zoom %.1fR pan %.1fR: near %.3f > model front %.3f\n",
                          z, panFactor, near, frontOfModel];
      }
    }
  }
  _target = savedTarget;
  _distance = savedDistance;

  [out appendFormat:@"%d clipping failures; worst near margin %.4f mm, far margin %.4f mm",
                    failures, worstNear, worstFar];
  return out;
}

// Draws the AppKit layer (the toolbar) into a bitmap. Screen capture needs a
// permission this process does not have; this needs none, and it is the only
// way to actually look at the chrome from here.
- (BOOL)captureChromeToPNG:(NSString *)path {
  [self layoutToolbar];
  // Establish the camera for this view's own aspect so the chip lands where it
  // would on screen, not where it sat for some other render size.
  const CGFloat h = std::max(self.bounds.size.height, CGFloat(1));
  [self fitToCurrentOrientationWithAspect:float(self.bounds.size.width / h)];
  [self uniformsForAspect:float(self.bounds.size.width / h)];
  [self positionMeasureChip];
  NSBitmapImageRep *rep = [self bitmapImageRepForCachingDisplayInRect:self.bounds];
  if (!rep) return NO;
  [self cacheDisplayInRect:self.bounds toBitmapImageRep:rep];
  NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG
                                  properties:@{}];
  return [png writeToFile:path atomically:YES];
}

// Headless equivalent of clicking two points in Points mode.
- (NSString *)pointMeasureFromX:(uint32_t)x1 y:(uint32_t)y1
                            toX:(uint32_t)x2 y:(uint32_t)y2
                           size:(CGSize)size {
  simd_float3 points[2];
  const uint32_t xs[2] = {x1, x2}, ys[2] = {y1, y2};
  for (int i = 0; i < 2; ++i) {
    const uint32_t entityId = [self pickFaceHeadlessAtX:xs[i] y:ys[i] size:size];
    float depth = 1.0f;
    memcpy(&depth, (const char *)_pickBuffer.contents + 4, sizeof(float));
    if (!(depth < 0.999999f))
      return [NSString stringWithFormat:@"no geometry at point %d", i + 1];
    simd_float3 p = [self worldPointAtPixel:simd_make_float2(float(xs[i]), float(ys[i]))
                                      depth:depth
                                     inSize:size];
    if (entityId != FACE_ID_NONE && !isEdgeId(entityId)) {
      std::array<double, 3> exact{};
      if (_doc->snapPointToFace(entityIndex(entityId), {p.x, p.y, p.z}, exact))
        p = simd_make_float3(float(exact[0]), float(exact[1]), float(exact[2]));
    }
    points[i] = p;
  }
  const simd_float3 d = points[1] - points[0];
  return [NSString stringWithFormat:
      @"p1 (%.3f, %.3f, %.3f)\np2 (%.3f, %.3f, %.3f)\n"
      @"distance %.4f mm   dx %.4f  dy %.4f  dz %.4f",
      points[0].x, points[0].y, points[0].z, points[1].x, points[1].y,
      points[1].z, simd_length(d), d.x, d.y, d.z];
}

// Runs two clicks through the real measure path, snapping included, so the
// headless render shows exactly what the app would.
- (NSString *)simulateMeasureFromX:(uint32_t)x1 y:(uint32_t)y1
                               toX:(uint32_t)x2 y:(uint32_t)y2
                              size:(CGSize)size {
  self.mode = CADModeMeasure;
  _pickSizeOverride = size;
  const uint32_t xs[2] = {x1, x2}, ys[2] = {y1, y2};
  NSString *last = @"";
  for (int i = 0; i < 2; ++i) {
    const uint32_t entityId = [self pickFaceHeadlessAtX:xs[i] y:ys[i] size:size];
    float depth = 1.0f;
    memcpy(&depth, (const char *)_pickBuffer.contents + 4, sizeof(float));
    _pickPointPixel = simd_make_float2(float(xs[i]), float(ys[i]));
    _pickForcedPoint = NO;
    _cursorWorldValid = depth < 0.999999f;
    if (_cursorWorldValid)
      _cursorWorld = [self worldPointAtPixel:_pickPointPixel
                                       depth:depth
                                      inSize:size];
    __block NSString *captured = @"";
    void (^saved)(NSString *) = self.statusHandler;
    self.statusHandler = ^(NSString *text) { captured = text; };
    [self handlePickedFace:entityId shift:NO];
    self.statusHandler = saved;
    last = captured;
  }
  return last;
}

- (void)drawRect:(CGRect)rect {
  id<CAMetalDrawable> drawable = self.currentDrawable;
  MTLRenderPassDescriptor *pass = self.currentRenderPassDescriptor;
  if (!drawable || !pass) return;

  const CGSize size = self.drawableSize;
  if (size.width < 1 || size.height < 1) return;
  [self ensureFaceIdTextureOfSize:size];

  pass.colorAttachments[1].texture = _faceIdTexture;
  pass.colorAttachments[1].loadAction = MTLLoadActionClear;
  pass.colorAttachments[1].storeAction = MTLStoreActionStore;
  pass.colorAttachments[1].clearColor = MTLClearColorMake(FACE_ID_NONE, 0, 0, 0);
  // Our own depth texture, stored so the pick resolve can sample it.
  pass.depthAttachment.texture = _depthTexture;
  pass.depthAttachment.loadAction = MTLLoadActionClear;
  pass.depthAttachment.clearDepth = 1.0;
  pass.depthAttachment.storeAction = MTLStoreActionStore;

  Uniforms u = [self uniformsForAspect:float(size.width / size.height)];
  [self positionMeasureChip];

  id<MTLCommandBuffer> cmd = [_queue commandBuffer];
  id<MTLRenderCommandEncoder> enc =
      [cmd renderCommandEncoderWithDescriptor:pass];
  [self encodeSceneInto:enc uniforms:u];
  [enc endEncoding];
  if (_pickPending) {
    _pickPending = NO;
    const uint32_t px = (uint32_t)std::clamp<CGFloat>(_pickPoint.x, 0, size.width - 1);
    const uint32_t py = (uint32_t)std::clamp<CGFloat>(_pickPoint.y, 0, size.height - 1);
    [self encodePickResolveInto:cmd atX:px y:py];

    const BOOL isShift = _pickIsShift;
    __weak CADView *weakSelf = self;
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> _) {
      uint32_t picked = FACE_ID_NONE;
      memcpy(&picked, weakSelf.pickBufferContents, sizeof(uint32_t));
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf handlePickedFace:picked shift:isShift];
      });
    }];
  }

  [cmd presentDrawable:drawable];
  [cmd commit];
}

- (void)encodePickResolveInto:(id<MTLCommandBuffer>)cmd
                          atX:(uint32_t)x
                            y:(uint32_t)y {
  [self encodePickResolveInto:cmd atX:x y:y toBuffer:_pickBuffer];
}

- (void)encodePickResolveInto:(id<MTLCommandBuffer>)cmd
                          atX:(uint32_t)x
                            y:(uint32_t)y
                     toBuffer:(id<MTLBuffer>)destination {
  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = _pickTexture;
  pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  pass.colorAttachments[1].texture = _pickDepthTexture;
  pass.colorAttachments[1].loadAction = MTLLoadActionDontCare;
  pass.colorAttachments[1].storeAction = MTLStoreActionStore;

  simd_uint2 coord = simd_make_uint2(x, y);
  id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
  [enc setRenderPipelineState:_pickResolvePipeline];
  [enc setFragmentTexture:_faceIdTexture atIndex:0];
  [enc setFragmentTexture:_depthTexture atIndex:1];
  [enc setFragmentBytes:&coord length:sizeof(coord) atIndex:0];
  [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  [enc endEncoding];

  id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
  [blit copyFromTexture:_pickTexture
            sourceSlice:0
            sourceLevel:0
           sourceOrigin:MTLOriginMake(0, 0, 0)
             sourceSize:MTLSizeMake(1, 1, 1)
               toBuffer:destination
      destinationOffset:0
 destinationBytesPerRow:sizeof(uint32_t)
destinationBytesPerImage:sizeof(uint32_t)];
  [blit copyFromTexture:_pickDepthTexture
            sourceSlice:0
            sourceLevel:0
           sourceOrigin:MTLOriginMake(0, 0, 0)
             sourceSize:MTLSizeMake(1, 1, 1)
               toBuffer:destination
      destinationOffset:4
 destinationBytesPerRow:sizeof(float)
destinationBytesPerImage:sizeof(float)];
  [blit endEncoding];
}

- (void *)pickBufferContents { return _pickBuffer.contents; }

#pragma mark - Picking and measurement

- (void)handlePickedFace:(uint32_t)entityId shift:(BOOL)shift {
  // The cube shares the identity buffer with the model, so a click on it
  // arrives here like any other pick.
  if (entityId != FACE_ID_NONE && (entityId & CUBE_FACE_FLAG) != 0) {
    [self applyStandardView:[CADView standardViewForCubeFace:
                                entityId & ~CUBE_FACE_FLAG]];
    return;
  }
  if (!_doc) return;

  if (entityId == FACE_ID_NONE) {
    [self clearMeasurement];
    [self report:@"no selection"];
    return;
  }

  // Shift accumulates, in either mode: several edges give a total length, and
  // a connected run reports as a chain.
  if (shift) {
    [self clearMeasurementKeepingSelection];
    [self toggleInSelection:entityId];
    [self report:[self describeSelection]];
    [self setNeedsDisplay:YES];
    return;
  }

  if (_mode != CADModeMeasure) {
    [self setSelectionTo:entityId];
    [self clearMeasurementKeepingSelection];
    [self report:[NSString stringWithFormat:@"%@    ⇧-click to add",
                                            [self describeFace:entityId]]];
    [self setNeedsDisplay:YES];
    return;
  }

  cadcore::MeasureRef ref;
  NSString *what = nil;
  simd_float3 point;
  if (![self referenceForPick:entityId
                      atPixel:_pickPointPixel
                   forcePoint:_pickForcedPoint
                       inSize:[self pickSize]
                       outRef:&ref
                      outWhat:&what
                     outPoint:&point])
    return;

  if (_refCount >= 2) _refCount = 0;  // a third click starts a new measurement
  if (_refCount == 0) {
    _selection.clear();
    _hasMeasureLine = NO;
  }
  if (!ref.isPoint) _selection.push_back(entityId);
  [self uploadSelectionFlags];
  _refs[_refCount] = ref;
  _measurePoints[_refCount] = point;
  _refCount++;

  if (_refCount == 1) {
    _lastRefDescription = what;
    [self report:[NSString stringWithFormat:@"%@ — click a second target", what]];
    [self setNeedsDisplay:YES];
    return;
  }

  // Two clicks on the same entity can only sensibly mean two points on it -
  // the distance from a face to itself is zero. This is what makes
  // point-to-point work without a separate mode or a modifier.
  if (!_refs[0].isPoint && !_refs[1].isPoint &&
      _refs[0].kind == _refs[1].kind && _refs[0].id == _refs[1].id) {
    for (int i = 0; i < 2; ++i) {
      const simd_float3 p = _measurePoints[i];
      std::array<double, 3> exact{};
      const bool onEdge = _refs[i].kind == cadcore::EntityKind::Edge;
      const bool ok = onEdge ? _doc->projectPointOntoEdge(_refs[i].id,
                                                          {p.x, p.y, p.z}, exact)
                             : _doc->snapPointToFace(_refs[i].id,
                                                     {p.x, p.y, p.z}, exact);
      _refs[i] = cadcore::MeasureRef::atPoint(
          ok ? exact : std::array<double, 3>{p.x, p.y, p.z});
    }
    _selection.clear();
    [self uploadSelectionFlags];
    what = @"point";
    _lastRefDescription = @"point";
  }

  const cadcore::MeasureResult result = _doc->measure(_refs[0], _refs[1]);
  if (!result.valid) {
    [self report:@"measurement failed"];
    [self setNeedsDisplay:YES];
    return;
  }

  // Draw the measurement where it is actually taken: the closest points the
  // solver found, not the two pick locations.
  _measurePoints[0] = simd_make_float3(float(result.pointA[0]),
                                       float(result.pointA[1]),
                                       float(result.pointA[2]));
  _measurePoints[1] = simd_make_float3(float(result.pointB[0]),
                                       float(result.pointB[1]),
                                       float(result.pointB[2]));
  _hasMeasureLine = YES;
  _lastMeasuredDistance = result.distance;
  [self setMeasureChipText:[self formatLength:result.distance]];

  const simd_float3 delta = _measurePoints[1] - _measurePoints[0];
  [self report:[NSString stringWithFormat:
      @"%@ → %@    distance %@    Δx %@  Δy %@  Δz %@",
      _lastRefDescription ?: @"", what, [self formatLength:result.distance],
      [self formatLength:delta.x], [self formatLength:delta.y],
      [self formatLength:delta.z]]];
  [self setNeedsDisplay:YES];
}

- (void)clearMeasurement {
  _selection.clear();
  [self uploadSelectionFlags];
  [self clearMeasurementKeepingSelection];
}

- (void)clearMeasurementKeepingSelection {
  _refCount = 0;
  _hasMeasureLine = NO;
  [self setMeasureChipText:nil];
  [self setNeedsDisplay:YES];
}

- (NSString *)shortNameFor:(uint32_t)entityId {
  return [NSString stringWithFormat:@"%@ %u",
                                    isEdgeId(entityId) ? @"edge" : @"face",
                                    entityIndex(entityId)];
}

- (NSString *)describeFace:(uint32_t)entityId {
  if (entityId != FACE_ID_NONE && (entityId & CUBE_FACE_FLAG) != 0)
    return @"view cube";
  if (!_doc || entityId == FACE_ID_NONE) return @"no selection";
  const uint32_t index = entityIndex(entityId);

  if (isEdgeId(entityId)) {
    const cadcore::EdgeInfo edge = _doc->edgeInfo(index);
    if (!edge.valid) return [NSString stringWithFormat:@"edge %u", index];
    NSMutableString *text = [NSMutableString
        stringWithFormat:@"edge %u    %s    length %@", index,
                         edge.curveType.c_str(),
                         [self formatLength:edge.length]];
    if (edge.hasRadius)
      [text appendFormat:@"    ⌀ %@  (r %@)",
                         [self formatLength:edge.radius * 2.0],
                         [self formatLength:edge.radius]];
    if (edge.closed) [text appendString:@"    closed"];
    return text;
  }

  const cadcore::FaceInfo info = _doc->faceInfo(index);
  if (!info.valid) return [NSString stringWithFormat:@"face %u", index];
  NSMutableString *text = [NSMutableString
      stringWithFormat:@"face %u    %s    area %.4f mm²", index,
                       info.surfaceType.c_str(), info.area];
  if (info.hasRadius)
    [text appendFormat:@"    ⌀ %.4f mm  (r %.4f)", info.radius * 2.0, info.radius];
  return text;
}

- (void)requestPickAt:(NSPoint)viewPoint shift:(BOOL)shift {
  _pickPointPixel = [self pixelForEventPoint:viewPoint];
  _pickForcedPoint =
      (NSEvent.modifierFlags & NSEventModifierFlagOption) != 0;
  const CGSize drawableSize = self.drawableSize;
  const CGFloat sx = drawableSize.width / self.bounds.size.width;
  const CGFloat sy = drawableSize.height / self.bounds.size.height;
  // AppKit is bottom-left origin; Metal textures are top-left.
  _pickPoint = CGPointMake(viewPoint.x * sx,
                           (self.bounds.size.height - viewPoint.y) * sy);
  _pickIsShift = shift;
  _pickPending = YES;
  [self setNeedsDisplay:YES];
}

#pragma mark - Input

- (void)setTransparentBackground:(BOOL)transparent {
  _transparentBackground = transparent;
  // The layer must be non-opaque or AppKit composites the cleared pixels
  // against black instead of letting the host show through.
  self.layer.opaque = !transparent;
  [self setNeedsDisplay:YES];
}

- (BOOL)acceptsFirstResponder { return YES; }

// Without this the first click in an inactive preview pane is swallowed by
// window activation instead of reaching the model.
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)handlePan:(NSPanGestureRecognizer *)recognizer {
  const NSPoint translation = [recognizer translationInView:self];
  if (recognizer.state == NSGestureRecognizerStateBegan) {
    _lastGestureTranslation = NSZeroPoint;
    _orbitPivotFromGesture = YES;
  }
  const CGFloat dx = translation.x - _lastGestureTranslation.x;
  const CGFloat dy = translation.y - _lastGestureTranslation.y;
  _lastGestureTranslation = translation;
  if (dx == 0 && dy == 0) return;

  _userNavigated = YES;
  const NSEventModifierFlags flags = NSEvent.modifierFlags;
  if (flags & (NSEventModifierFlagCommand | NSEventModifierFlagOption)) {
    [self panByDX:dx dy:dy];
  } else {
    _azimuth -= float(dx) * 0.01f;
    _elevation = std::clamp(_elevation - float(dy) * 0.01f, -1.55f, 1.55f);
  }
  [self setNeedsDisplay:YES];
}

- (void)handleMagnify:(NSMagnificationGestureRecognizer *)recognizer {
  _userNavigated = YES;
  _distance *= std::exp(float(-recognizer.magnification) * 1.2f);
  _distance = std::clamp(_distance, _modelRadius * 0.02f, _modelRadius * 60.0f);
  recognizer.magnification = 0;
  [self setNeedsDisplay:YES];
}

- (CGSize)pickSize {
  return _pickSizeOverride.width > 0 ? _pickSizeOverride : self.drawableSize;
}

#pragma mark - Selection

- (void)uploadSelectionFlags {
  if (_faceSelectedBuffer)
    memset(_faceSelectedBuffer.contents, 0, _faceCount * sizeof(uint32_t));
  if (_edgeSelectedBuffer)
    memset(_edgeSelectedBuffer.contents, 0, _edgeCount * sizeof(uint32_t));
  for (uint32_t entityId : _selection) {
    const uint32_t index = entityIndex(entityId);
    if (isEdgeId(entityId)) {
      if (index < _edgeCount)
        ((uint32_t *)_edgeSelectedBuffer.contents)[index] = 1;
    } else if (index < _faceCount) {
      ((uint32_t *)_faceSelectedBuffer.contents)[index] = 1;
    }
  }
}

- (void)setSelectionTo:(uint32_t)entityId {
  _selection.clear();
  if (entityId != FACE_ID_NONE) _selection.push_back(entityId);
  [self uploadSelectionFlags];
}

// Shift adds to the selection, or removes an entity already in it.
- (void)toggleInSelection:(uint32_t)entityId {
  auto it = std::find(_selection.begin(), _selection.end(), entityId);
  if (it != _selection.end())
    _selection.erase(it);
  else
    _selection.push_back(entityId);
  [self uploadSelectionFlags];
}

- (NSString *)describeSelection {
  if (_selection.empty()) return @"no selection";
  if (_selection.size() == 1) return [self describeFace:_selection.front()];

  std::vector<uint32_t> edges, faces;
  for (uint32_t entityId : _selection)
    (isEdgeId(entityId) ? edges : faces).push_back(entityIndex(entityId));

  NSMutableString *text = [NSMutableString string];
  if (!edges.empty()) {
    const auto group = _doc->measureEdges(edges);
    [text appendFormat:@"%zu edges    total length %.4f mm", group.count,
                       group.totalLength];
    if (group.closed)
      [text appendString:@"    closed loop"];
    else if (group.connected)
      [text appendFormat:@"    connected chain, end to end %.4f mm",
                         group.endToEnd];
    else
      [text appendString:@"    not connected"];
  }
  if (!faces.empty()) {
    if (text.length) [text appendString:@"    ·    "];
    [text appendFormat:@"%zu faces    total area %.4f mm²", faces.size(),
                       _doc->totalArea(faces)];
  }
  return text;
}

#pragma mark - Snapping

// Snap decisions are made in screen space, so a target feels close regardless
// of how far away it is in the model. The tolerance is per kind: a circle
// centre must be genuinely aimed at, otherwise clicking any small rim would
// always snap to its centre and the edge itself could never be selected.
static float snapRadiusFor(cadcore::SnapKind kind) {
  switch (kind) {
    case cadcore::SnapKind::Vertex: return 14.0f;
    case cadcore::SnapKind::EdgeMidpoint: return 11.0f;
    case cadcore::SnapKind::CircleCentre: return 8.0f;
    default: return 0.0f;
  }
}
static constexpr float kSnapRadiusPixels = 14.0f;

- (BOOL)snapForEntity:(uint32_t)entityId
              atPixel:(simd_float2)pixel
               inSize:(CGSize)size
             outPoint:(simd_float3 *)outPoint
              outKind:(cadcore::SnapKind *)outKind {
  if (!_doc || entityId == FACE_ID_NONE) return NO;
  const auto kind = isEdgeId(entityId) ? cadcore::EntityKind::Edge
                                       : cadcore::EntityKind::Face;
  const auto candidates = _doc->snapCandidates(kind, entityIndex(entityId));

  float bestScore = -1.0f;
  float bestDistance = kSnapRadiusPixels;
  bool found = false;
  for (const auto &candidate : candidates) {
    const simd_float3 world = simd_make_float3(float(candidate.position[0]),
                                               float(candidate.position[1]),
                                               float(candidate.position[2]));
    const simd_float2 at = [self projectWorldPoint:world inSize:size];
    const float distance = simd_length(at - pixel);
    if (distance > snapRadiusFor(candidate.kind)) continue;
    // Prefer the stronger kind; break ties by screen distance.
    const float score = float(candidate.kind) * 1000.0f - distance;
    if (score > bestScore) {
      bestScore = score;
      bestDistance = distance;
      *outPoint = world;
      *outKind = candidate.kind;
      found = true;
    }
  }
  (void)bestDistance;
  return found;
}

// Resolves a click into a measurement reference. Snap points win, then the
// entity under the cursor; holding option forces a free point on the surface.
- (BOOL)referenceForPick:(uint32_t)entityId
                 atPixel:(simd_float2)pixel
             forcePoint:(BOOL)forcePoint
                  inSize:(CGSize)size
                  outRef:(cadcore::MeasureRef *)outRef
                 outWhat:(NSString **)outWhat
                outPoint:(simd_float3 *)outPoint {
  if (entityId == FACE_ID_NONE) return NO;

  simd_float3 snapped;
  cadcore::SnapKind snapKind;
  if (!forcePoint &&
      [self snapForEntity:entityId atPixel:pixel inSize:size
                 outPoint:&snapped outKind:&snapKind]) {
    *outRef = cadcore::MeasureRef::atPoint(
        {snapped.x, snapped.y, snapped.z});
    *outWhat = [NSString stringWithUTF8String:cadcore::toString(snapKind)];
    *outPoint = snapped;
    return YES;
  }

  if (forcePoint || !_cursorWorldValid) {
    if (!_cursorWorldValid) return NO;
    simd_float3 point = _cursorWorld;
    std::array<double, 3> exact{};
    if (isEdgeId(entityId)) {
      if (_doc->projectPointOntoEdge(entityIndex(entityId),
                                     {point.x, point.y, point.z}, exact))
        point = simd_make_float3(float(exact[0]), float(exact[1]), float(exact[2]));
      *outWhat = @"on edge";
    } else {
      if (_doc->snapPointToFace(entityIndex(entityId),
                                {point.x, point.y, point.z}, exact))
        point = simd_make_float3(float(exact[0]), float(exact[1]), float(exact[2]));
      *outWhat = @"on face";
    }
    *outRef = cadcore::MeasureRef::atPoint({point.x, point.y, point.z});
    *outPoint = point;
    return YES;
  }

  *outRef = cadcore::MeasureRef::entity(
      isEdgeId(entityId) ? cadcore::EntityKind::Edge : cadcore::EntityKind::Face,
      entityIndex(entityId));
  *outWhat = [self shortNameFor:entityId];
  *outPoint = _cursorWorld;
  return YES;
}

#pragma mark - Unprojection

// Pixel + NDC depth -> world point, using the matrix that frame was drawn with.
- (simd_float3)worldPointAtPixel:(simd_float2)pixel depth:(float)depth {
  return [self worldPointAtPixel:pixel depth:depth inSize:self.drawableSize];
}

- (simd_float2)projectWorldPoint:(simd_float3)point inSize:(CGSize)size {
  const simd_float4 clip =
      simd_mul(_lastViewProjection, simd_make_float4(point, 1.0f));
  const simd_float3 ndc = clip.xyz / clip.w;
  return simd_make_float2((ndc.x * 0.5f + 0.5f) * float(size.width),
                          (0.5f - ndc.y * 0.5f) * float(size.height));
}

- (simd_float3)worldPointAtPixel:(simd_float2)pixel
                           depth:(float)depth
                          inSize:(CGSize)ds {
  const float ndcX = 2.0f * (pixel.x + 0.5f) / float(ds.width) - 1.0f;
  const float ndcY = 1.0f - 2.0f * (pixel.y + 0.5f) / float(ds.height);
  const simd_float4 clip = simd_make_float4(ndcX, ndcY, depth, 1.0f);
  const simd_float4 world = simd_mul(simd_inverse(_lastViewProjection), clip);
  return world.xyz / world.w;
}

// Where the cursor is pointing. Falls back to the plane through the current
// pivot when the pointer is over empty space, so orbiting off-model still
// behaves predictably instead of snapping to the model centre.
- (simd_float3)pivotForPixel:(simd_float2)pixel {
  return [self pivotForPixel:pixel inSize:self.drawableSize];
}

- (simd_float3)pivotForPixel:(simd_float2)pixel inSize:(CGSize)size {
  if (_cursorWorldValid) return _cursorWorld;

  const simd_float3 near = [self worldPointAtPixel:pixel depth:0.0f inSize:size];
  const simd_float3 far = [self worldPointAtPixel:pixel depth:1.0f inSize:size];
  const simd_float3 dir = simd_normalize(far - near);
  const simd_float3 eye = [self eyePosition];
  const simd_float3 normal = simd_normalize(eye - _target);
  const float denom = simd_dot(dir, normal);
  if (std::abs(denom) < 1e-6f) return _target;
  const float t = simd_dot(_target - near, normal) / denom;
  if (t <= 0) return _target;
  return near + dir * t;
}

- (simd_float2)pixelForEventPoint:(NSPoint)p {
  const CGSize ds = self.drawableSize;
  const CGFloat sx = ds.width / self.bounds.size.width;
  const CGFloat sy = ds.height / self.bounds.size.height;
  return simd_make_float2(
      float(std::clamp<CGFloat>(p.x * sx, 0, ds.width - 1)),
      float(std::clamp<CGFloat>((self.bounds.size.height - p.y) * sy, 0,
                                ds.height - 1)));
}

#pragma mark - Cursor

- (void)setMode:(CADInteractionMode)mode {
  _mode = mode;
  if (_modeControl) _modeControl.selectedSegment = mode;
  [self clearMeasurementKeepingSelection];
  [self updateCursor];
  [self report:mode == CADModeMeasure
                   ? @"measure    click any two: point, edge or face  (⌥ for a free point)"
                   : @"view    drag to orbit, click a face or edge to inspect"];
  [self setNeedsDisplay:YES];
}

- (void)updateCursor {
  // Grabbing is the only state that earns a custom cursor. Showing an open
  // hand just for hovering meant the cursor flickered every time the pointer
  // passed the window controls, and it says nothing the model does not.
  if (_isPanning || _isDragging) { [[NSCursor closedHandCursor] set]; return; }
  if (_lastMousePoint.y > self.bounds.size.height - kTitlebarBand) {
    [[NSCursor arrowCursor] set];
    return;
  }
  if (!_navigationOnly && _mode == CADModeMeasure) {
    [[NSCursor crosshairCursor] set];
    return;
  }
  [[NSCursor arrowCursor] set];
}

- (void)cursorUpdate:(NSEvent *)event { [self updateCursor]; }

- (void)selectFace:(uint32_t)entityId {
  [self setSelectionTo:entityId];
  [self report:[self describeFace:entityId]];
  [self setNeedsDisplay:YES];
}

- (void)highlightEntity:(uint32_t)faceId { [self setHoverEntity:faceId]; }

#pragma mark - Hover

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  for (NSTrackingArea *area in [self.trackingAreas copy])
    [self removeTrackingArea:area];
  [self addTrackingArea:[[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:(NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                    NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect)
             owner:self
          userInfo:nil]];
}

- (void)setHoverEntity:(uint32_t)faceId {
  if (faceId == _hoverEntity) return;
  _hoverEntity = faceId;
  [self updateCursor];
  [self setNeedsDisplay:YES];
}

- (void)mouseMoved:(NSEvent *)event {
  const NSPoint where = [self convertPoint:event.locationInWindow fromView:nil];
  _lastMousePoint = where;
  if ([self pointIsOverToolbar:where]) {
    [self setHoverEntity:FACE_ID_NONE];
    _cursorWorldValid = NO;
    [[NSCursor arrowCursor] set];
    return;
  }
  [self updateCursor];
  if (_navigationOnly || !_doc || !_faceIdTexture) return;
  // One resolve in flight at a time; hovering must not queue work per event.
  if (_hoverResolveInFlight) return;

  const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  if (!NSPointInRect(p, self.bounds)) { [self setHoverEntity:FACE_ID_NONE]; return; }

  const CGSize drawableSize = self.drawableSize;
  const CGFloat sx = drawableSize.width / self.bounds.size.width;
  const CGFloat sy = drawableSize.height / self.bounds.size.height;
  const uint32_t px = (uint32_t)std::clamp<CGFloat>(p.x * sx, 0, drawableSize.width - 1);
  const uint32_t py = (uint32_t)std::clamp<CGFloat>(
      (self.bounds.size.height - p.y) * sy, 0, drawableSize.height - 1);

  // Resolves against the identity buffer from the last frame, so hovering
  // costs one 3-vertex pass rather than a full re-render.
  _hoverResolveInFlight = YES;
  id<MTLCommandBuffer> cmd = [_queue commandBuffer];
  [self encodePickResolveInto:cmd atX:px y:py toBuffer:_hoverBuffer];
  __weak CADView *weakSelf = self;
  const simd_float2 pixel = simd_make_float2(float(px), float(py));
  [cmd addCompletedHandler:^(id<MTLCommandBuffer> _) {
    uint32_t hovered = FACE_ID_NONE;
    float depth = 1.0f;
    const char *bytes = (const char *)weakSelf.hoverBufferContents;
    memcpy(&hovered, bytes, sizeof(uint32_t));
    memcpy(&depth, bytes + 4, sizeof(float));
    dispatch_async(dispatch_get_main_queue(), ^{
      [weakSelf setHoverEntity:hovered];
      [weakSelf updateCursorWorldAtPixel:pixel depth:depth];
      [weakSelf updateSnapPreviewForEntity:hovered atPixel:pixel];
      [weakSelf clearHoverInFlight];
    });
  }];
  [cmd commit];
}

- (void)clearHoverInFlight { _hoverResolveInFlight = NO; }

// Shows where a click would actually land while measuring, so snapping is
// visible before you commit to it.
- (void)updateSnapPreviewForEntity:(uint32_t)entityId
                           atPixel:(simd_float2)pixel {
  const BOOL wanted = (_mode == CADModeMeasure) && entityId != FACE_ID_NONE &&
                      (entityId & CUBE_FACE_FLAG) == 0;
  if (!_doc) return;
  BOOL had = _hasSnapPreview;
  _hasSnapPreview = NO;
  if (wanted) {
    simd_float3 point;
    cadcore::SnapKind kind;
    if ([self snapForEntity:entityId
                    atPixel:pixel
                     inSize:self.drawableSize
                   outPoint:&point
                    outKind:&kind]) {
      _snapPreview = point;
      _hasSnapPreview = YES;
    }
  }
  if (had || _hasSnapPreview) [self setNeedsDisplay:YES];
}

- (void)updateCursorWorldAtPixel:(simd_float2)pixel depth:(float)depth {
  // Cleared depth is 1.0, so anything less means the ray hit geometry.
  _cursorWorldValid = depth < 0.999999f;  // false for NaN too
  if (_cursorWorldValid)
    _cursorWorld = [self worldPointAtPixel:pixel depth:depth];
}
- (void *)hoverBufferContents { return _hoverBuffer.contents; }

- (void)mouseExited:(NSEvent *)event {
  [self setHoverEntity:FACE_ID_NONE];
  _cursorWorldValid = NO;
}

#pragma mark - Drag and drop

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
  return [self pathFromDrag:sender] ? NSDragOperationCopy : NSDragOperationNone;
}

- (NSString *)pathFromDrag:(id<NSDraggingInfo>)sender {
  NSArray *urls = [sender.draggingPasteboard
      readObjectsForClasses:@[ [NSURL class] ]
                    options:@{NSPasteboardURLReadingFileURLsOnlyKey : @YES}];
  NSURL *url = urls.firstObject;
  if (!url) return nil;
  const std::string ext = url.pathExtension.lowercaseString.UTF8String;
  for (const auto &f : cadcore::Document::supportedFormats())
    if (f.extension == ext) return url.path;
  return nil;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  NSString *path = [self pathFromDrag:sender];
  if (!path) return NO;
  NSString *error = nil;
  if (![self loadDocumentAtPath:path error:&error]) {
    [self report:[NSString stringWithFormat:@"could not open %@ — %@",
                                            path.lastPathComponent, error]];
    return NO;
  }
  return YES;
}

- (void)mouseDown:(NSEvent *)event {
  _lastDrag = [self convertPoint:event.locationInWindow fromView:nil];
  _lastMousePoint = _lastDrag;
  _isDragging = NO;
  _isPanning = (event.modifierFlags &
                (NSEventModifierFlagCommand | NSEventModifierFlagOption)) != 0;
  [self updateCursor];
}

- (void)mouseUp:(NSEvent *)event {
  const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  const BOOL wasClick = !_isDragging;
  _isDragging = _isPanning = NO;
  [self updateCursor];
  if (wasClick && !_navigationOnly)
    [self requestPickAt:p shift:(event.modifierFlags & NSEventModifierFlagShift) != 0];
}

- (void)mouseDragged:(NSEvent *)event {
  const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  const CGFloat dx = p.x - _lastDrag.x, dy = p.y - _lastDrag.y;
  _lastDrag = p;
  if (std::abs(dx) > 0 || std::abs(dy) > 0) {
    _isDragging = YES;
    _userNavigated = YES;
    [self updateCursor];
  }

  if (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption)) {
    [self panByDX:dx dy:dy];
  } else {
    _azimuth -= float(dx) * 0.01f;
    // Inverted vertical orbit: dragging up tips the top of the model away.
    _elevation = std::clamp(_elevation - float(dy) * 0.01f, -1.55f, 1.55f);
  }
  [self setNeedsDisplay:YES];
}

- (void)rightMouseDragged:(NSEvent *)event {
  _userNavigated = YES;
  const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  [self panByDX:p.x - _lastDrag.x dy:p.y - _lastDrag.y];
  _lastDrag = p;
  [self setNeedsDisplay:YES];
}

- (void)rightMouseDown:(NSEvent *)event {
  _lastDrag = [self convertPoint:event.locationInWindow fromView:nil];
  _isPanning = YES;
  [self updateCursor];
}

- (void)rightMouseUp:(NSEvent *)event {
  _isPanning = NO;
  [self updateCursor];
}

- (void)panByDX:(CGFloat)dx dy:(CGFloat)dy {
  const simd_float3 eye = [self eyePosition];
  const simd_float3 forward = simd_normalize(_target - eye);
  const simd_float3 right = simd_normalize(simd_cross(forward, simd_make_float3(0, 0, 1)));
  const simd_float3 up = simd_cross(right, forward);

  // World units per point of cursor motion at the pivot distance. The visible
  // height there is 2*d*tan(fov/2), so this makes the model track the pointer
  // exactly instead of outrunning it. Mouse deltas are in points, so this uses
  // the view bounds, not the backing-scaled drawable size.
  const float viewHeight = std::max(float(self.bounds.size.height), 1.0f);
  const float worldPerPoint =
      2.0f * _distance * std::tan(kFovYDegrees * 0.5f * float(M_PI) / 180.0f) /
      viewHeight;

  _target -= right * float(dx) * worldPerPoint;
  _target -= up * float(dy) * worldPerPoint;
}

- (void)scrollWheel:(NSEvent *)event {
  _userNavigated = YES;
  _distance *= std::exp(float(-event.scrollingDeltaY) * 0.006f);
  _distance = std::clamp(_distance, _modelRadius * 0.02f, _modelRadius * 60.0f);
  [self setNeedsDisplay:YES];
}

- (void)magnifyWithEvent:(NSEvent *)event {
  _userNavigated = YES;
  _distance *= std::exp(float(-event.magnification) * 1.6f);
  _distance = std::clamp(_distance, _modelRadius * 0.02f, _modelRadius * 60.0f);
  [self setNeedsDisplay:YES];
}

- (void)keyDown:(NSEvent *)event {
  NSString *k = event.charactersIgnoringModifiers.lowercaseString;
  if ([k isEqualToString:@"f"]) { [self frameModel]; return; }
  if ([k isEqualToString:@"v"]) { self.mode = CADModeOrbit; return; }
  if ([k isEqualToString:@"m"]) { self.mode = CADModeMeasure; return; }
  if ([k isEqualToString:@"\033"]) {          // esc clears selection
    [self clearMeasurement];
    [self report:@"no selection"];
    [self setNeedsDisplay:YES];
    return;
  }
  [super keyDown:event];
}
@end
