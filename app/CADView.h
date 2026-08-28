#import <MetalKit/MetalKit.h>

typedef NS_ENUM(NSInteger, CADInteractionMode) {
  CADModeOrbit = 0,   // click inspects a face
  CADModeMeasure = 1  // click any two things: point, edge or face
};

@interface CADView : MTKView
@property(nonatomic) CADInteractionMode mode;
// Navigation only: no picking, no hover highlight, no cursor changes. Used by
// the QuickLook preview, where the pane is for looking at the part, not
// working on it.
@property(nonatomic) BOOL navigationOnly;
// Draws the model on transparency instead of the gradient, so QuickLook
// composites it onto Finder's own background.
@property(nonatomic) BOOL transparentBackground;
// 0 follows the system appearance; 1+ are explicit looks. See backgroundNames.
@property(nonatomic) NSInteger backgroundStyle;
+ (NSArray<NSString *> *)backgroundNames;
// Applies a look without writing it to preferences; used by the headless
// flags, which must not change what the user sees next launch.
- (void)previewBackgroundStyle:(NSInteger)style;

// Live settings. Each persists and applies immediately; quality and
// anti-aliasing rebuild what they have to.
@property(nonatomic) NSInteger unitStyle;            // 0 mm, 1 cm, 2 m, 3 in
@property(nonatomic) BOOL showViewCube;
@property(nonatomic) NSInteger shadingMode;          // 0 shaded+edges, 1 shaded, 2 wireframe
@property(nonatomic) NSInteger tessellationQuality;  // 0 coarse, 1 normal, 2 fine
@property(nonatomic) NSInteger antialiasingSamples;  // 1, 2, 4 or 8
// True when the rendered ground at that end of the gradient is dark. The
// background is chosen independently of the system theme, so overlay chrome has
// to take its contrast from what is actually behind it.
- (BOOL)groundIsDarkNearTop;
- (BOOL)groundIsDarkNearBottom;
// Called whenever the ground changes, so an owner can restyle chrome it added
// to the view itself.
@property(nonatomic, copy) void (^appearanceHandler)(void);

// Sample counts this device can actually render, ascending. Apple silicon
// commonly tops out at 4x, and requesting more is fatal rather than ignored.
- (NSArray<NSNumber *> *)supportedAntialiasingSamples;

+ (NSArray<NSString *> *)unitNames;
+ (NSArray<NSString *> *)shadingNames;
+ (NSArray<NSString *> *)qualityNames;
- (instancetype)initHeadlessWithFrame:(CGRect)frame device:(id<MTLDevice>)device;
- (BOOL)loadDocumentAtPath:(NSString *)path error:(NSString **)outError;
- (void)frameModel;
// Renders one frame without a window. Used for verification now, and it is
// the same path a QuickLook thumbnail extension will need.
// Renders headlessly to an image. Used by the QuickLook thumbnail extension,
// which has no window.
- (CGImageRef)renderImageOfSize:(CGSize)size CF_RETURNS_RETAINED;
- (BOOL)renderOffscreenToPNG:(NSString *)path
                        size:(CGSize)size
                       error:(NSString **)outError;
// Renders and resolves one pick in the same command buffer. Exercises the
// multisampled identity buffer without needing a window.
- (uint32_t)pickFaceHeadlessAtX:(uint32_t)x y:(uint32_t)y size:(CGSize)size;
// Human-readable summary of a face: type, area, and exact diameter if round.
- (NSString *)describeFace:(uint32_t)faceId;
// Drive selection/highlight from outside the view - used by the headless
// render flags today and by the component sidebar next.
- (void)selectFace:(uint32_t)faceId;
- (void)highlightEntity:(uint32_t)faceId;
- (void)applyStandardView:(NSInteger)index;  // 0 iso, 1 front, 2 top, 3 right
- (void)fitToCurrentOrientationWithAspect:(float)aspect;
- (NSString *)clipReport;
- (NSString *)simulateMeasureFromX:(uint32_t)x1 y:(uint32_t)y1
                               toX:(uint32_t)x2 y:(uint32_t)y2
                              size:(CGSize)size;
- (NSString *)pointMeasureFromX:(uint32_t)x1 y:(uint32_t)y1
                            toX:(uint32_t)x2 y:(uint32_t)y2
                           size:(CGSize)size;
- (BOOL)captureChromeToPNG:(NSString *)path;
@property(nonatomic, copy) void (^statusHandler)(NSString *);
@end
