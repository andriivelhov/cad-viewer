#import <Cocoa/Cocoa.h>

#include <algorithm>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "CADView.h"

#include "cadcore/CadDocument.h"

@class ViewerWindowController;

// Settings apply to every open window and persist, so the app looks and
// behaves the same next launch.
@protocol SettingsDelegate <NSObject>
- (void)applySettings:(void (^)(CADView *viewer))block;
- (CADView *)anyViewer;
@end

@interface SettingsWindowController : NSWindowController
- (instancetype)initWithOwner:(id<SettingsDelegate>)owner;
@end

@implementation SettingsWindowController {
  __weak id<SettingsDelegate> _owner;
  NSPopUpButton *_units, *_background, *_shading, *_quality, *_antialiasing;
  NSButton *_viewCube, *_materials;
  NSArray<NSNumber *> *_aaSamples;
}

- (instancetype)initWithOwner:(id<SettingsDelegate>)owner {
  NSWindow *window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, 460, 300)
                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                  backing:NSBackingStoreBuffered
                    defer:NO];
  if ((self = [super initWithWindow:window])) {
    _owner = owner;
    window.title = @"Settings";
    [window center];

    CADView *viewer = [owner anyViewer];

    _units = [self popupWithTitles:[CADView unitNames]
                          selected:viewer.unitStyle
                            action:@selector(unitsChanged:)];
    _background = [self popupWithTitles:[CADView backgroundNames]
                               selected:viewer.backgroundStyle
                                 action:@selector(backgroundChanged:)];
    _shading = [self popupWithTitles:[CADView shadingNames]
                            selected:viewer.shadingMode
                              action:@selector(shadingChanged:)];
    _quality = [self popupWithTitles:[CADView qualityNames]
                            selected:viewer.tessellationQuality
                              action:@selector(qualityChanged:)];
    // Only offer levels this GPU can render. Listing 8x on hardware that tops
    // out at 4x offers a setting that crashes the renderer when chosen.
    _aaSamples = [viewer supportedAntialiasingSamples];
    NSMutableArray<NSString *> *aaTitles = [NSMutableArray array];
    NSInteger aaIndex = 0;
    for (NSUInteger i = 0; i < _aaSamples.count; ++i) {
      const NSInteger value = _aaSamples[i].integerValue;
      [aaTitles addObject:value == 1 ? @"Off"
                                     : [NSString stringWithFormat:@"%ld×", (long)value]];
      if (value == viewer.antialiasingSamples) aaIndex = (NSInteger)i;
    }
    _antialiasing = [self popupWithTitles:aaTitles
                                 selected:aaIndex
                                   action:@selector(antialiasingChanged:)];

    _viewCube = [NSButton checkboxWithTitle:@"Show the view cube"
                                     target:self
                                     action:@selector(viewCubeChanged:)];
    _viewCube.state = viewer.showViewCube ? NSControlStateValueOn
                                          : NSControlStateValueOff;

    _materials = [NSButton checkboxWithTitle:@"Use materials from the file"
                                      target:nil
                                      action:nil];
    _materials.enabled = NO;  // honest: not implemented yet
    _materials.toolTip = @"Not implemented yet. Textures and materials are read "
                         @"from OBJ and glTF files but are not displayed; "
                         @"everything renders in one matte grey.";

    NSGridView *grid = [NSGridView gridViewWithViews:@[
      @[ [self label:@"Units"], _units ],
      @[ [self label:@"Background"], _background ],
      @[ [self label:@"Shading"], _shading ],
      @[ [self label:@"Detail"], _quality ],
      @[ [self label:@"Anti-aliasing"], _antialiasing ],
      @[ [NSGridCell emptyContentView], _viewCube ],
      @[ [NSGridCell emptyContentView], _materials ],
    ]];
    grid.rowSpacing = 12;
    grid.columnSpacing = 12;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    grid.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *note = [NSTextField
        wrappingLabelWithString:@"Detail trades load time against how smooth "
                                @"curved faces look; changing it rebuilds the "
                                @"model. Measurements stay exact either way — "
                                @"they come from the geometry, not the mesh."];
    note.font = [NSFont systemFontOfSize:11];
    note.textColor = NSColor.secondaryLabelColor;
    note.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *content = window.contentView;
    [content addSubview:grid];
    [content addSubview:note];
    // Pin all four edges and fix only the width: the window then takes its
    // height from the laid-out controls, so the note cannot be clipped when the
    // text or the control heights change.
    [NSLayoutConstraint activateConstraints:@[
      [content.widthAnchor constraintEqualToConstant:460],
      [grid.topAnchor constraintEqualToAnchor:content.topAnchor constant:24],
      [grid.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
      [grid.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor
                                                    constant:-24],
      [note.topAnchor constraintEqualToAnchor:grid.bottomAnchor constant:20],
      [note.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
      [note.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],
      [note.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-20],
    ]];
    [content layoutSubtreeIfNeeded];
    [window setContentSize:content.fittingSize];
    [window center];
  }
  return self;
}

- (NSTextField *)label:(NSString *)text {
  NSTextField *field = [NSTextField labelWithString:text];
  field.alignment = NSTextAlignmentRight;
  return field;
}

- (NSPopUpButton *)popupWithTitles:(NSArray<NSString *> *)titles
                          selected:(NSInteger)index
                            action:(SEL)action {
  NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect
                                                    pullsDown:NO];
  [popup addItemsWithTitles:titles];
  [popup selectItemAtIndex:std::clamp<NSInteger>(index, 0, titles.count - 1)];
  popup.target = self;
  popup.action = action;
  return popup;
}

- (void)unitsChanged:(id)s {
  const NSInteger v = _units.indexOfSelectedItem;
  [_owner applySettings:^(CADView *viewer) { viewer.unitStyle = v; }];
}
- (void)backgroundChanged:(id)s {
  const NSInteger v = _background.indexOfSelectedItem;
  [_owner applySettings:^(CADView *viewer) { viewer.backgroundStyle = v; }];
}
- (void)shadingChanged:(id)s {
  const NSInteger v = _shading.indexOfSelectedItem;
  [_owner applySettings:^(CADView *viewer) { viewer.shadingMode = v; }];
}
- (void)qualityChanged:(id)s {
  const NSInteger v = _quality.indexOfSelectedItem;
  [_owner applySettings:^(CADView *viewer) { viewer.tessellationQuality = v; }];
}
- (void)antialiasingChanged:(id)s {
  const NSInteger index = std::clamp<NSInteger>(
      _antialiasing.indexOfSelectedItem, 0, (NSInteger)_aaSamples.count - 1);
  const NSInteger v = _aaSamples[index].integerValue;
  [_owner applySettings:^(CADView *viewer) { viewer.antialiasingSamples = v; }];
}
- (void)viewCubeChanged:(id)s {
  const BOOL on = _viewCube.state == NSControlStateValueOn;
  [_owner applySettings:^(CADView *viewer) { viewer.showViewCube = on; }];
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate, SettingsDelegate>
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
    __weak CADView *weakViewer = _viewer;
    // The status line sits at the bottom of the gradient, which on some
    // backgrounds is the dark end while the toolbar's end is light.
    _viewer.appearanceHandler = ^{
      weakStatus.textColor = [weakViewer groundIsDarkNearBottom]
                                 ? [NSColor colorWithWhite:0.78 alpha:1.0]
                                 : [NSColor colorWithWhite:0.28 alpha:1.0];
    };
    _viewer.statusHandler = ^(NSString *text) { weakStatus.stringValue = text; };
    // The view built its chrome before this handler existed, so run it once.
    _viewer.appearanceHandler();

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
  SettingsWindowController *_settings;
}

- (void)applySettings:(void (^)(CADView *))block {
  for (ViewerWindowController *c in _windows) block(c.viewer);
}

- (CADView *)anyViewer { return self.activeViewer; }

- (void)showSettings:(id)sender {
  if (!_settings) _settings = [[SettingsWindowController alloc] initWithOwner:self];
  [_settings showWindow:nil];
  [_settings.window makeKeyAndOrderFront:nil];
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
  [appMenu addItemWithTitle:@"Settings…"
                     action:@selector(showSettings:)
              keyEquivalent:@","];
  [appMenu addItem:[NSMenuItem separatorItem]];
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
  NSMenuItem *backgrounds = [viewMenu addItemWithTitle:@"Background"
                                                action:nil
                                         keyEquivalent:@""];
  NSMenu *backgroundMenu = [[NSMenu alloc] initWithTitle:@"Background"];
  NSArray<NSString *> *names = [CADView backgroundNames];
  for (NSUInteger i = 0; i < names.count; ++i) {
    NSMenuItem *item = [backgroundMenu addItemWithTitle:names[i]
                                                 action:@selector(setBackground:)
                                          keyEquivalent:@""];
    item.tag = (NSInteger)i;
  }
  backgrounds.submenu = backgroundMenu;

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
- (void)setBackground:(NSMenuItem *)item {
  // Applies to every open window, so the app looks consistent.
  for (ViewerWindowController *c in _windows) c.viewer.backgroundStyle = item.tag;
}
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
  if (item.action == @selector(setBackground:))
    item.state = self.activeViewer.backgroundStyle == item.tag
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
      [args containsObject:@"--measure"] || [args containsObject:@"--chromeshot"] ||
      [args containsObject:@"--settingsshot"] || [args containsObject:@"--thumb"];

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
  const NSUInteger bgIdx = [args indexOfObject:@"--background"];
  if (bgIdx != NSNotFound && bgIdx + 1 < args.count)
    [view previewBackgroundStyle:args[bgIdx + 1].integerValue];

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

  // Renders the Settings window to a file: it cannot be screenshotted from a
  // terminal, and this proves it builds without a crash.
  const NSUInteger settingsIdx = [args indexOfObject:@"--settingsshot"];
  if (settingsIdx != NSNotFound && settingsIdx + 1 < args.count) {
    [self showSettings:nil];
    NSView *content = _settings.window.contentView;
    [content layoutSubtreeIfNeeded];
    NSBitmapImageRep *rep =
        [content bitmapImageRepForCachingDisplayInRect:content.bounds];
    [content cacheDisplayInRect:content.bounds toBitmapImageRep:rep];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG
                                    properties:@{}];
    const BOOL ok = [png writeToFile:args[settingsIdx + 1] atomically:YES];
    printf("%s\n", ok ? "settings captured" : "settings capture failed");
    [self exitHeadless:ok ? 0 : 1];
  }

  // Reproduces the QuickLook thumbnail provider's exact path -- headless init,
  // transparent background, renderImageOfSize: at the requested pixel size --
  // so thumbnail bugs can be chased without going through Finder.
  const NSUInteger thumbIdx = [args indexOfObject:@"--thumb"];
  if (thumbIdx != NSNotFound && thumbIdx + 3 < args.count) {
    const CGFloat w = args[thumbIdx + 2].doubleValue;
    const CGFloat h = args[thumbIdx + 3].doubleValue;
    // The provider sizes the view in points but renders at pixel size, so the
    // scale has to be reproducible here too.
    const CGFloat scale =
        (thumbIdx + 4 < args.count && ![args[thumbIdx + 4] hasPrefix:@"-"])
            ? args[thumbIdx + 4].doubleValue
            : 1.0;
    CADView *shot =
        [[CADView alloc] initHeadlessWithFrame:NSMakeRect(0, 0, w, h)
                                        device:MTLCreateSystemDefaultDevice()];
    shot.transparentBackground = YES;
    NSString *err = nil;
    if (![shot loadDocumentAtPath:args[1] error:&err]) {
      fprintf(stderr, "%s\n", err.UTF8String);
      [self exitHeadless:1];
    }
    CGImageRef img = [shot renderImageOfSize:CGSizeMake(w * scale, h * scale)];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
    CGImageRelease(img);
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:args[thumbIdx + 1]
         atomically:YES];
    printf("thumb %.0fx%.0f @%gx\n", w, h, scale);
    [self exitHeadless:0];
  }

  // Dragging the window by its titlebar used to orbit the model too, because
  // a full-size-content window puts the view under the titlebar. Needs a real
  // window: without one there is no titlebar band to be inside of.
  if ([args containsObject:@"--dragtest"]) {
    CADView *v = self.activeViewer;
    const CGFloat h = v.bounds.size.height, w = v.bounds.size.width;
    const CGFloat band = [v titlebarBandHeight];

    NSString *before = [v cameraReport];
    [v simulateDragFromX:w * 0.5 y:h - 8 toX:w * 0.5 + 120 y:h - 8];
    NSString *afterBand = [v cameraReport];
    [v simulateDragFromX:w * 0.5 y:h * 0.5 toX:w * 0.5 + 120 y:h * 0.5];
    NSString *afterBody = [v cameraReport];

    printf("band %.0f\ntitlebar drag %s\nbody drag %s\n", band,
           [afterBand isEqualToString:before] ? "ignored" : "MOVED THE MODEL",
           [afterBody isEqualToString:afterBand] ? "IGNORED" : "orbits");
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
