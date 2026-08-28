// QuickLook thumbnail provider: gives Finder real model thumbnails instead of
// a generic document icon. Runs headless - there is no window here - so it
// drives CADView's offscreen render path directly.

#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#import <MetalKit/MetalKit.h>

#import "CADView.h"

@interface CADThumbnailProvider : QLThumbnailProvider
@end

@implementation CADThumbnailProvider

- (void)provideThumbnailForFileRequest:(QLFileThumbnailRequest *)request
                     completionHandler:
                         (void (^)(QLThumbnailReply *_Nullable,
                                   NSError *_Nullable))handler {
  @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
      handler(nil, [NSError errorWithDomain:@"dev.cadviewer" code:1 userInfo:nil]);
      return;
    }

    // Draw into exactly the context Finder asked for. Forcing a square left
    // the rest of the preview panel unpainted, which showed up as the model
    // shoved into a corner of a white box.
    const CGFloat scale = request.scale > 0 ? request.scale : 1.0;
    CGSize points = request.maximumSize;
    if (points.width < 16 || points.height < 16) points = CGSizeMake(256, 256);
    const CGSize pixels = CGSizeMake(points.width * scale, points.height * scale);

    __block CADView *view = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
      view = [[CADView alloc] initHeadlessWithFrame:NSMakeRect(0, 0, points.width,
                                                               points.height)
                                             device:device];
    });

    // Deliberately opaque: a transparent thumbnail gets wrapped in Finder's
    // white document-page frame, which insets and shrinks the model, while an
    // opaque one is drawn full-bleed. The preview extension stays transparent,
    // where it composites onto the pane instead.
    view.transparentBackground = NO;

    NSString *error = nil;
    if (![view loadDocumentAtPath:request.fileURL.path error:&error]) {
      handler(nil, [NSError errorWithDomain:@"dev.cadviewer"
                                       code:2
                                   userInfo:@{NSLocalizedDescriptionKey :
                                                  error ?: @"could not read"}]);
      return;
    }

    CGImageRef image = [view renderImageOfSize:pixels];
    if (!image) {
      handler(nil, [NSError errorWithDomain:@"dev.cadviewer" code:3 userInfo:nil]);
      return;
    }

    // The drawing block runs asynchronously, after this method has returned.
    // Releasing the image here left the block drawing freed memory, which
    // crashed inside CGContextDrawImage. Hand ownership to ARC so the block
    // keeps it alive for exactly as long as it needs it.
    id retainedImage = CFBridgingRelease(image);
    QLThumbnailReply *reply = [QLThumbnailReply
        replyWithContextSize:points
                drawingBlock:^BOOL(CGContextRef _Nonnull context) {
                  // Draw into the context's real extent. replyWithContextSize:
                  // is in points, but the context Finder supplies is scaled -
                  // assuming points put the model in the bottom-left quadrant
                  // of the tile with the rest left white.
                  CGRect box = CGContextGetClipBoundingBox(context);
                  if (CGRectIsEmpty(box) || CGRectIsInfinite(box))
                    box = CGRectMake(0, 0, points.width, points.height);
                  // Paint the ground: a transparent thumbnail gets wrapped in
                  // Finder's white document-page frame, which insets the model.
                  CGContextSetRGBFillColor(context, 0.157, 0.169, 0.196, 1.0);
                  CGContextFillRect(context, box);
                  CGContextDrawImage(context, box,
                                     (__bridge CGImageRef)retainedImage);
                  return YES;
                }];
    handler(reply, nil);
  }
}

@end
