// QuickLook preview extension: an interactive model in Finder's preview pane
// and the spacebar panel. Unlike the thumbnail provider this is a real view
// controller, so the viewer's own orbit, zoom and picking all work in place.

#import <Cocoa/Cocoa.h>
#import <QuickLookUI/QuickLookUI.h>
#import <MetalKit/MetalKit.h>

#import "CADView.h"

@interface CADPreviewViewController : NSViewController <QLPreviewingController>
@end

@implementation CADPreviewViewController {
  CADView *_viewer;
  NSTextField *_message;
}

- (void)loadView {
  NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 600, 480)];
  container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if (device) {
    // Headless init: no toolbar or measurement chip in a preview pane, but
    // orbit, zoom and hover all still work.
    _viewer = [[CADView alloc] initHeadlessWithFrame:container.bounds
                                              device:device];
    _viewer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    // A preview pane is for looking at the part: drag to rotate, scroll or
    // pinch to zoom. No selection, no hover, no measurement.
    _viewer.navigationOnly = YES;
    _viewer.transparentBackground = YES;
    [container addSubview:_viewer];
  }

  _message = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 600, 20)];
  _message.bezeled = NO;
  _message.drawsBackground = NO;
  _message.editable = NO;
  _message.selectable = NO;
  _message.alignment = NSTextAlignmentCenter;
  _message.textColor = NSColor.secondaryLabelColor;
  _message.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
  _message.hidden = YES;
  [container addSubview:_message];

  self.view = container;
}

- (void)preparePreviewOfFileAtURL:(NSURL *)url
                completionHandler:(void (^)(NSError *_Nullable))handler {
  if (!_viewer) {
    _message.stringValue = @"No Metal device available";
    _message.hidden = NO;
    handler(nil);
    return;
  }

  NSString *error = nil;
  if (![_viewer loadDocumentAtPath:url.path error:&error]) {
    _message.stringValue = error ?: @"Could not read this file";
    _message.hidden = NO;
    _viewer.hidden = YES;
    handler(nil);  // report in the pane rather than failing the preview
    return;
  }

  [_viewer frameModel];
  handler(nil);
}

@end
