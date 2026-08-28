// Asks macOS for a thumbnail exactly the way Finder does.
#import <Foundation/Foundation.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#import <AppKit/AppKit.h>

int main(int argc, const char **argv) {
  @autoreleasepool {
    NSURL *url = [NSURL fileURLWithPath:@(argv[1])];
    QLThumbnailGenerationRequest *req = [[QLThumbnailGenerationRequest alloc]
        initWithFileAtURL:url
                     size:CGSizeMake(512, 512)
                    scale:(argc > 3 ? atof(argv[3]) : 2.0)  // Finder uses 2
      representationTypes:QLThumbnailGenerationRequestRepresentationTypeAll];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[QLThumbnailGenerator sharedGenerator]
        generateBestRepresentationForRequest:req
                           completionHandler:^(QLThumbnailRepresentation *rep,
                                               NSError *err) {
          if (err) {
            printf("FAILED: %s\n", err.localizedDescription.UTF8String);
          } else {
            const char *kind = rep.type == QLThumbnailRepresentationTypeIcon
                                   ? "generic icon (extension NOT used)"
                                   : "rendered thumbnail";
            // contentRect is only filled in for icon representations, so
            // reporting it made real thumbnails look like 0x0 failures. Measure
            // the image that actually came back.
            printf("type=%s size=%zux%zu\n", kind, CGImageGetWidth(rep.CGImage),
                   CGImageGetHeight(rep.CGImage));
            NSData *png = [NSBitmapImageRep
                representationOfImageRepsInArray:@[ [[NSBitmapImageRep alloc]
                                                     initWithCGImage:rep.CGImage] ]
                                       usingType:NSBitmapImageFileTypePNG
                                      properties:@{}];
            [png writeToFile:@(argv[2]) atomically:YES];
          }
          dispatch_semaphore_signal(done);
        }];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 40ull * NSEC_PER_SEC));
  }
  return 0;
}
