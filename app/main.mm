#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "CADView.h"

#include "cadcore/CadDocument.h"

@class ViewerWindowController;

@interface AppDelegate : NSObject <NSApplicationDelegate>
- (void)windowControllerWillClose:(ViewerWindowController *)controller;
@end

// One window per part, the way a normal document-based Mac app behaves: the
// app outlives its windows, and each file gets its own.
@interface ViewerWindowController : NSWindowController <NSWindowDelegate>
@property(nonatomic, readonly) CADView *viewer;
@property(nonatomic, readonly) BOOL hasDocument;
- (BOOL)openPath:(NSString *)path;
@end

@implementation ViewerWindowController {
  CADView *_viewer;
  NSTextField *_status;
  BOOL _hasDocument;
}

- (instancetype)init {
  const NSRect frame = NSMakeRect(0, 0, 1180, 780);
  NSWindow *window = [[NSWindow alloc]
      initWithContentRect:frame
                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                           NSWindowStyleMaskMiniaturizable |
                           NSWindowStyleMaskResizable |
                           NSWindowStyleMaskFullSizeContentView)
                  backing:NSBackingStoreBuffered
                    defer:NO];
  if ((self = [super initWithWindow:window])) {
    window.title = @"CAD Viewer";
    window.titlebarAppearsTransparent = YES;
    window.titleVisibility = NSWindowTitleHidden;
    window.releasedWhenClosed = NO;  // the controller owns its lifetime
    window.delegate = self;
    window.minSize = NSMakeSize(520, 400);
    [window center];

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSAssert(device, @"no Metal device");
    _viewer = [[CADView alloc] initWithFrame:frame device:device];
    _viewer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    _status = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 12, 1100, 20)];
    _status.bezeled = NO;
    _status.drawsBackground = NO;
    _status.editable = NO;
    _status.selectable = NO;
    _status.font = [NSFont monospacedSystemFontOfSize:11
                                               weight:NSFontWeightRegular];
    _status.textColor = [NSColor colorWithWhite:0.78 alpha:1.0];
    _status.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    _status.stringValue = @"open a file  (⌘O, or drag one in)";

    __weak NSTextField *weakStatus = _status;
    _viewer.statusHandler = ^(NSString *text) { weakStatus.stringValue = text; };

    [_viewer addSubview:_status];
    window.contentView = _viewer;
    [window makeFirstResponder:_viewer];
  }
  return self;
}

- (BOOL)openPath:(NSString *)path {
  NSString *error = nil;
  if (![_viewer loadDocumentAtPath:path error:&error]) {
    _status.stringValue =
        [NSString stringWithFormat:@"could not open %@ — %@",
                                   path.lastPathComponent, error];
    return NO;
  }
  _hasDocument = YES;
  self.window.title = path.lastPathComponent;
  self.window.representedFilename = path;  // proxy icon and ⌘-click path menu
  return YES;
}

- (void)windowWillClose:(NSNotification *)note {
  [(AppDelegate *)NSApp.delegate windowControllerWillClose:self];
}

@end

@implementation AppDelegate {
  NSMutableArray<ViewerWindowController *> *_windows;
  // A double-click delivers the open event before the app has finished
  // launching, so the path is held until there is a window for it.
  NSString *_pendingOpenPath;
  NSPoint _cascade;
  NSMenu *_recentsMenu;
}

#pragma mark - Windows

- (ViewerWindowController *)newWindow:(id)sender {
  ViewerWindowController *controller = [[ViewerWindowController alloc] init];
  if (_windows.count == 0)
    _cascade = NSMakePoint(NSMinX(controller.window.frame),
                           NSMaxY(controller.window.frame));
  else
    _cascade = [controller.window cascadeTopLeftFromPoint:_cascade];
  [_windows addObject:controller];
  [controller showWindow:nil];
  [controller.window makeKeyAndOrderFront:nil];
  return controller;
}

- (void)windowControllerWillClose:(ViewerWindowController *)controller {
  [_windows removeObject:controller];
}

// Headless flags act on the frontmost window, creating one if needed.
- (CADView *)activeViewer {
  if (_windows.count == 0) [self newWindow:nil];
  ViewerWindowController *front = _windows.lastObject;
  for (ViewerWindowController *c in _windows)
    if (c.window.isKeyWindow) front = c;
  return front.viewer;
}

// The app stays running with no windows, like any normal Mac app. ⌘W closes a
// window; ⌘Q quits.
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app {
  return NO;
}

// Clicking the Dock icon with nothing open gives a window back.
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app
                    hasVisibleWindows:(BOOL)visible {
  if (!visible) [self newWindow:nil];
  return YES;
}

#pragma mark - Opening

- (BOOL)openPath:(NSString *)path {
  if (!_windows) {  // opened a file before the app finished launching
    _pendingOpenPath = path;
    return YES;
  }
  // Reuse the front window while it is still empty; otherwise each part gets a
  // window of its own so several can be open side by side.
  ViewerWindowController *target = nil;
  for (ViewerWindowController *c in _windows)
    if (c.window.isKeyWindow && !c.hasDocument) target = c;
  if (!target)
    for (ViewerWindowController *c in _windows)
      if (!c.hasDocument) target = c;
  if (!target) target = [self newWindow:nil];

  const BOOL ok = [target openPath:path];
  [target.window makeKeyAndOrderFront:nil];
  if (ok) [self noteRecentPath:path];
  return ok;
}

- (void)application:(NSApplication *)sender openURLs:(NSArray<NSURL *> *)urls {
  for (NSURL *url in urls)
    if (url.isFileURL) [self openPath:url.path];
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
  return [self openPath:filename];
}

- (void)openDocument:(id)sender {
  NSMutableArray<UTType *> *types = [NSMutableArray array];
  for (const auto &f : cadcore::Document::supportedFormats()) {
    NSString *ext = [NSString stringWithUTF8String:f.extension.c_str()];
    // Most CAD extensions have no registered UTType; a dynamic one filters fine.
    UTType *t = [UTType typeWithFilenameExtension:ext];
    if (t) [types addObject:t];
  }
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.allowedContentTypes = types;
  panel.allowsMultipleSelection = YES;
  if ([panel runModal] != NSModalResponseOK) return;
  for (NSURL *url in panel.URLs) [self openPath:url.path];
}

#pragma mark - Recent files

// NSDocumentController's recents only persist for genuinely document-based
// apps; here it silently recorded nothing and left the menu permanently empty.
static NSString *const kRecentsKey = @"RecentDocumentPaths";

- (void)noteRecentPath:(NSString *)path {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  NSMutableArray<NSString *> *recents =
      [[defaults stringArrayForKey:kRecentsKey] ?: @[] mutableCopy];
  [recents removeObject:path];
  [recents insertObject:path atIndex:0];
  while (recents.count > 10) [recents removeLastObject];
  [defaults setObject:recents forKey:kRecentsKey];
  [self rebuildRecentsMenu];
}

- (void)rebuildRecentsMenu {
  if (!_recentsMenu) return;
  [_recentsMenu removeAllItems];
  NSArray<NSString *> *recents =
      [NSUserDefaults.standardUserDefaults stringArrayForKey:kRecentsKey] ?: @[];
  for (NSString *path in recents) {
    // Skip anything that has since been moved or deleted.
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) continue;
    NSMenuItem *item = [_recentsMenu addItemWithTitle:path.lastPathComponent
                                               action:@selector(openRecent:)
                                        keyEquivalent:@""];
    item.representedObject = path;
    item.toolTip = path;
  }
  if (_recentsMenu.numberOfItems > 0)
    [_recentsMenu addItem:[NSMenuItem separatorItem]];
  [_recentsMenu addItemWithTitle:@"Clear Menu"
                          action:@selector(clearRecents:)
                   keyEquivalent:@""];
}

- (void)openRecent:(NSMenuItem *)item { [self openPath:item.representedObject]; }

- (void)clearRecents:(id)sender {
  [NSUserDefaults.standardUserDefaults removeObjectForKey:kRecentsKey];
  [self rebuildRecentsMenu];
}

#pragma mark - Menu

- (void)buildMenu {
  NSMenu *bar = [NSMenu new];

  NSMenuItem *appItem = [NSMenuItem new];
  [bar addItem:appItem];
  NSMenu *appMenu = [NSMenu new];
  [appMenu addItemWithTitle:@"Hide CAD Viewer"
                     action:@selector(hide:)
              keyEquivalent:@"h"];
  [appMenu addItem:[NSMenuItem separatorItem]];
  [appMenu addItemWithTitle:@"Quit CAD Viewer"
                     action:@selector(terminate:)
              keyEquivalent:@"q"];
  appItem.submenu = appMenu;

  NSMenuItem *fileItem = [NSMenuItem new];
  [bar addItem:fileItem];
  NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
  [fileMenu addItemWithTitle:@"New Window"
                      action:@selector(newWindow:)
               keyEquivalent:@"n"];
  [fileMenu addItemWithTitle:@"Open…"
                      action:@selector(openDocument:)
               keyEquivalent:@"o"];
  NSMenuItem *recents = [fileMenu addItemWithTitle:@"Open Recent"
                                            action:nil
                                     keyEquivalent:@""];
  _recentsMenu = [[NSMenu alloc] initWithTitle:@"Open Recent"];
  recents.submenu = _recentsMenu;
  [self rebuildRecentsMenu];
  [fileMenu addItem:[NSMenuItem separatorItem]];
  // performClose: goes to the key window, so ⌘W closes that window and leaves
  // the app running.
  [fileMenu addItemWithTitle:@"Close" action:@selector(performClose:)
               keyEquivalent:@"w"];
  fileItem.submenu = fileMenu;

  NSMenuItem *viewItem = [NSMenuItem new];
  [bar addItem:viewItem];
  NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
  [[viewMenu addItemWithTitle:@"View Mode" action:@selector(setOrbitMode:)
                keyEquivalent:@"v"] setKeyEquivalentModifierMask:0];
  [[viewMenu addItemWithTitle:@"Measure Mode" action:@selector(setMeasureMode:)
                keyEquivalent:@"m"] setKeyEquivalentModifierMask:0];
  [viewMenu addItem:[NSMenuItem separatorItem]];
  [[viewMenu addItemWithTitle:@"Frame Model" action:@selector(frameModel:)
                keyEquivalent:@"f"] setKeyEquivalentModifierMask:0];
  [viewMenu addItem:[NSMenuItem separatorItem]];
  [viewMenu addItemWithTitle:@"Isometric" action:@selector(viewIso:)
               keyEquivalent:@"1"];
  [viewMenu addItemWithTitle:@"Front" action:@selector(viewFront:)
               keyEquivalent:@"2"];
  [viewMenu addItemWithTitle:@"Top" action:@selector(viewTop:)
               keyEquivalent:@"3"];
  [viewMenu addItemWithTitle:@"Right" action:@selector(viewRight:)
               keyEquivalent:@"4"];
  viewItem.submenu = viewMenu;

  NSMenuItem *windowItem = [NSMenuItem new];
  [bar addItem:windowItem];
  NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
  [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:)
                 keyEquivalent:@"m"];
  [windowMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:)
                 keyEquivalent:@""];
  [windowMenu addItem:[NSMenuItem separatorItem]];
  [windowMenu addItemWithTitle:@"Bring All to Front"
                        action:@selector(arrangeInFront:)
                 keyEquivalent:@""];
  windowItem.submenu = windowMenu;
  NSApp.windowsMenu = windowMenu;  // AppKit lists open windows here itself

  NSApp.mainMenu = bar;
}

- (void)frameModel:(id)sender { [self.activeViewer frameModel]; }
- (void)setOrbitMode:(id)sender { self.activeViewer.mode = CADModeOrbit; }
- (void)setMeasureMode:(id)sender { self.activeViewer.mode = CADModeMeasure; }
- (void)viewIso:(id)sender { [self.activeViewer applyStandardView:0]; }
- (void)viewFront:(id)sender { [self.activeViewer applyStandardView:1]; }
- (void)viewTop:(id)sender { [self.activeViewer applyStandardView:2]; }
- (void)viewRight:(id)sender { [self.activeViewer applyStandardView:3]; }

- (BOOL)validateMenuItem:(NSMenuItem *)item {
  if (item.action == @selector(setOrbitMode:))
    item.state = self.activeViewer.mode == CADModeOrbit ? NSControlStateValueOn
                                                        : NSControlStateValueOff;
  if (item.action == @selector(setMeasureMode:))
    item.state = self.activeViewer.mode == CADModeMeasure
                     ? NSControlStateValueOn
                     : NSControlStateValueOff;
  return YES;
}

#pragma mark - Launch

// -[NSApplication terminate:] routes through the run loop, which is not yet
// running while applicationDidFinishLaunching: is on the stack; that hangs the
// one-shot headless modes. Flush and leave directly instead.
- (void)exitHeadless:(int)status {
  fflush(stdout);
  fflush(stderr);
  exit(status);
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
  _windows = [NSMutableArray array];
  [self buildMenu];

  NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
  const BOOL headless =
      [args containsObject:@"--render"] || [args containsObject:@"--pick"] ||
      [args containsObject:@"--cliptest"] || [args containsObject:@"--points"] ||
      [args containsObject:@"--measure"] || [args containsObject:@"--chromeshot"];

  // A malformed headless flag used to fall through and silently open a window,
  // which looks exactly like a hang when the caller is waiting on stdout.
  if ([args containsObject:@"--pick"] &&
      [args indexOfObject:@"--pick"] + 2 >= args.count) {
    fprintf(stderr, "--pick needs two arguments: --pick <x> <y>\n");
    [self exitHeadless:2];
  }
  if ([args containsObject:@"--render"] &&
      [args indexOfObject:@"--render"] + 1 >= args.count) {
    fprintf(stderr, "--render needs a path: --render <out.png>\n");
    [self exitHeadless:2];
  }

  if (_pendingOpenPath) {
    NSString *path = _pendingOpenPath;
    _pendingOpenPath = nil;
    [self openPath:path];
  }
  if (args.count > 1 && ![args[1] hasPrefix:@"-"]) [self openPath:args[1]];
  if (_windows.count == 0 && !headless) [self newWindow:nil];

  CADView *view = self.activeViewer;

  // Force an appearance for headless renders; thumbnails need generating for a
  // specific theme rather than whatever the machine happens to be set to.
  const NSUInteger appearanceIdx = [args indexOfObject:@"--appearance"];
  if (appearanceIdx != NSNotFound && appearanceIdx + 1 < args.count) {
    NSString *want = args[appearanceIdx + 1];
    NSApp.appearance = [NSAppearance appearanceNamed:
        [want isEqualToString:@"light"] ? NSAppearanceNameAqua
                                        : NSAppearanceNameDarkAqua];
  }
  if ([args containsObject:@"--transparent"]) view.transparentBackground = YES;

  const NSUInteger measIdx = [args indexOfObject:@"--measure"];
  if (measIdx != NSNotFound && measIdx + 4 < args.count) {
    printf("%s\n", [view simulateMeasureFromX:(uint32_t)args[measIdx + 1].intValue
                                            y:(uint32_t)args[measIdx + 2].intValue
                                          toX:(uint32_t)args[measIdx + 3].intValue
                                            y:(uint32_t)args[measIdx + 4].intValue
                                         size:CGSizeMake(1400, 950)].UTF8String);
    // Stay alive when a later stage still needs to run.
    if (![args containsObject:@"--render"] &&
        ![args containsObject:@"--chromeshot"])
      [self exitHeadless:0];
  }

  const NSUInteger chromeIdx = [args indexOfObject:@"--chromeshot"];
  if (chromeIdx != NSNotFound && chromeIdx + 1 < args.count) {
    const BOOL ok = [view captureChromeToPNG:args[chromeIdx + 1]];
    printf("%s\n", ok ? "chrome captured" : "chrome capture failed");
    [self exitHeadless:ok ? 0 : 1];
  }

  const NSUInteger ptIdx = [args indexOfObject:@"--points"];
  if (ptIdx != NSNotFound && ptIdx + 4 < args.count) {
    printf("%s\n", [view pointMeasureFromX:(uint32_t)args[ptIdx + 1].intValue
                                         y:(uint32_t)args[ptIdx + 2].intValue
                                       toX:(uint32_t)args[ptIdx + 3].intValue
                                         y:(uint32_t)args[ptIdx + 4].intValue
                                      size:CGSizeMake(1400, 950)].UTF8String);
    [self exitHeadless:0];
  }

  if ([args containsObject:@"--cliptest"]) {
    printf("%s\n", [view clipReport].UTF8String);
    [self exitHeadless:0];
  }

  const NSUInteger pickIdx = [args indexOfObject:@"--pick"];
  if (pickIdx != NSNotFound && pickIdx + 2 < args.count) {
    const uint32_t fid = [view pickFaceHeadlessAtX:args[pickIdx + 1].intValue
                                                 y:args[pickIdx + 2].intValue
                                              size:CGSizeMake(1400, 950)];
    printf("%s\n", [view describeFace:fid].UTF8String);
    [self exitHeadless:0];
  }

  const NSUInteger viewIdx = [args indexOfObject:@"--view"];
  if (viewIdx != NSNotFound && viewIdx + 1 < args.count) {
    NSArray *names = @[ @"iso", @"front", @"top", @"right" ];
    const NSUInteger which = [names indexOfObject:args[viewIdx + 1]];
    [view applyStandardView:(which == NSNotFound ? 0 : (NSInteger)which)];
  }

  // intValue is 32-bit signed, so an edge id (top bit set) would clamp to
  // INT_MAX and silently select nothing.
  const NSUInteger selIdx = [args indexOfObject:@"--select"];
  if (selIdx != NSNotFound && selIdx + 1 < args.count)
    [view selectFace:(uint32_t)args[selIdx + 1].longLongValue];
  const NSUInteger hovIdx = [args indexOfObject:@"--hover"];
  if (hovIdx != NSNotFound && hovIdx + 1 < args.count)
    [view highlightEntity:(uint32_t)args[hovIdx + 1].longLongValue];

  const NSUInteger renderIdx = [args indexOfObject:@"--render"];
  if (renderIdx != NSNotFound && renderIdx + 1 < args.count) {
    NSString *out = args[renderIdx + 1];
    NSString *error = nil;
    const BOOL ok = [view renderOffscreenToPNG:out
                                          size:CGSizeMake(1400, 950)
                                         error:&error];
    fprintf(ok ? stdout : stderr, "%s\n",
            ok ? [NSString stringWithFormat:@"rendered %@", out].UTF8String
               : error.UTF8String);
    [self exitHeadless:ok ? 0 : 1];
  }

  [NSApp activateIgnoringOtherApps:YES];
}

@end

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    app.activationPolicy = NSApplicationActivationPolicyRegular;
    AppDelegate *delegate = [AppDelegate new];
    app.delegate = delegate;
    [app run];
  }
  return 0;
}
