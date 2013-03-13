// ScanViewController.mm
//
#import <CoreGraphics/CoreGraphics.h>
#import "TGVSettings.h"
#import "ScanViewController.h"
#import "QRCodeReader.h"
#import "filters.h"
#import "EventLog.h"
#import "Synchronizer.h"
#import "Voice.h"
#import "Signal.h"
#import "Analysis.h"
#import "Blob.h"
#import "findqrcs.h"

#define ANNOT_HEIGHT 30  // Add pixels of annotation to saved images
#define MAX_SAVES 10     // Don't save too many images per scan

@interface ScanViewController ()
{
  NSUserDefaults *defaults;
  int savedFailScans;      // Number of images saved so far for failed scans
  int savedSuccScans;      // Number of images saved so far for successful scans
  int savedFailCounts;     // Number of images saved so far for failed counts
  uint8_t *bitmapCopy;     // Copy of bitmap for failure analysis
  size_t copyWidth;        // Width of copied bitmap
  size_t copyHeight;       // Height of copied bitmap (includes annotation)
  BOOL copyGoodTime;       // Copy was made at a good time for periodic actions
  CMAcceleration copyGrav; // Gravity at time of copy, for failure analysis
}
@property (nonatomic, strong) EventLog *eventLog;
@property (nonatomic, strong) CMMotionManager *motionManager;
@property (nonatomic, strong) Synchronizer *synchronizer;
@property (nonatomic, strong) Voice *voice;
@property (nonatomic, strong) Signal *signal;
- (void) setup;
- (void) didBecomeActive: (NSNotification *) notification;
@end


@implementation ScanViewController

@synthesize tabController = _tabController;
@synthesize resultsController = _resultsController;
@synthesize eventLog = _eventLog;
@synthesize motionManager = _motionManager;
@synthesize synchronizer = _synchronizer;
@synthesize voice = _voice;
@synthesize signal = _signal;


- (EventLog *) eventLog
{
  if (!_eventLog) {
    _eventLog = [[EventLog alloc] init];
    _eventLog.delegate = self;
  }
  return _eventLog;
}


- (CMMotionManager *) motionManager
{
  if (!_motionManager) {
    _motionManager = [[CMMotionManager alloc] init];
    [_motionManager startDeviceMotionUpdates];
  }
  return _motionManager;
}

- (Synchronizer *) synchronizer
{
  if (!_synchronizer)
    _synchronizer = [[Synchronizer alloc] init];
  return _synchronizer;
}

- (Voice *) voice
{
  if(!_voice) {
    _voice = [[Voice alloc] init];
  }
  return _voice;
}

- (Signal *) signal
{
  if(!_signal) {
    _signal = [[Signal alloc] init];
    NSBundle *mainBundle = [NSBundle mainBundle];
    _signal.signalToIssue =
      [NSURL fileURLWithPath: [mainBundle pathForResource: @"epianodb4" ofType: @"aif"] isDirectory:NO];
  }
  return _signal;
}

- (BOOL) zxingController:(ZXingWidgetController *)controller
        shouldScanBitmap:(uint8_t *)bitmap
                   width:(size_t)width
                  height:(size_t)height
{
  // Tell the ZXing controller whether to scan the given bitmap looking
  // for QR codes. We say yes only if there looks to be one code there.
  // We also offer vocal guidance on getting the camera aimed at just one
  // code.
  //
  // Note: ownership of bitmap is being transferred to us. We need to
  // free it.
  //

  if ([self anyReasonToSave]) {
    // Make copy of original bitmap for failure analysis. Also save the
    // direction of gravity.
    //
    copyWidth = width;
    copyHeight = height + ANNOT_HEIGHT;
    bitmapCopy = (uint8_t *) malloc(copyWidth * copyHeight * BPP);
    memset(bitmapCopy, 0xff, copyWidth * copyHeight * BPP);
    memcpy(bitmapCopy, bitmap, width * height * BPP);
    copyGrav = self.motionManager.deviceMotion.gravity;
  }
  
  Analysis *analysis =
    [Analysis analysisWithBitmap: bitmap width: width height: height];
  //NSArray *qrcs = findqrcs(bitmap, width, height);
  free(bitmap);
  
  // Offer some audible guidance.
  //
  if ([defaults boolForKey:kSettingsGuideWithBeeps])
    [self guideByBeep: analysis.QRBlobs width: width height: height];
  else
    [self guideByVoice: analysis.QRBlobs width: width height: height];
  
  // The "save failed counts" setting asks to save images whose count
  // isn't 1. The way to test is to aim the camera at exactly one QRC.
  // For now, have to change this line of code to test with other numbers
  // of QRCs.
  //
  if ([defaults boolForKey: kSettingsSaveFailedCounts] &&
      [analysis.QRBlobs count] != 1 &&
      bitmapCopy && savedFailCounts++ < MAX_SAVES) {
    NSString *anno =
      [NSString stringWithFormat:@"Counted %d QR codes",
        [analysis.QRBlobs count]];
    [self saveFrame: bitmapCopy width: copyWidth height: copyHeight annotation: anno];
  }

  // If number of QRCs != 1, no further use for the bitmap copy. Otherwise,
  // remember whether it's a good time to save an image.
  //
  if ([analysis.QRBlobs count] != 1 && bitmapCopy) {
    free(bitmapCopy);
    bitmapCopy = NULL;
  }
  if (bitmapCopy)
    copyGoodTime = self.synchronizer.isGoodTime;

#ifdef WANT_TO_SET_FOCUS_POINT
  // If there's just one QR code, set the focus on it every now and then.
  // Note: this didn't seem to help, disabled for now.
  //
  if ([analysis.QRBlobs count] == 1) {
    Blob *b = analysis.QRBlobs[0];
    CGFloat x = (b.maxx + b.minx) / 2.0 / width;
    CGFloat y = (b.maxy + b.miny) / 2.0 / height;
    CGPoint focusPoint = CGPointMake(x, y);
    if (guided && guidanceCount % 2 == 0)
      [controller setFocusPointOfInterest: focusPoint];
  }
#endif // WANT_TO_SET_FOCUS_POINT

  // The autofocus seems to get stuck with QR codes completely out of
  // focus. Perhaps it's not designed to focus on things like QR codes.
  // At any rate, things seem to go far better if you ask for a refocus
  // now and then.
  //
  if (self.synchronizer.isGoodTime)
    [controller setFocusMode: AVCaptureFocusModeAutoFocus];

#if TGV_EXPERIMENTAL
  // In experimental version, if good time for periodic actions, and
  // don't see 0 QRCs, log some events.
  //
  int qrcsCount = [analysis.QRBlobs count];
  if (self.synchronizer.isGoodTime && qrcsCount != 0 &&
      [defaults boolForKey: kSettingsLogEvents]) {
    NSString *grav = [self gravityDescription: @"" gravity: self.motionManager.deviceMotion.gravity];
    NSString *line = [NSString stringWithFormat:@"Saw %d code%@, %@", qrcsCount, qrcsCount == 1 ? @"" : @"s", grav];
    [self.eventLog log: line];
  }
#endif

  // For now, if we see 1 QR code, it's worth scanning. Even if it's at
  // the edge or is too small. (Something else to figure out.)
  //
#ifdef NEVERSCAN
  if(bitmapCopy) {
    free(bitmapCopy);
    bitmapCopy = NULL;
  }
  return NO; // (Useful for testing the blob finding.)
#else
  return [analysis.QRBlobs count] == 1;
#endif
}

- (BOOL) anyReasonToSave
{
  // Determine if there would be any reason to save the current image for
  // later off-line failure analysis.
  //
  if([defaults boolForKey: kSettingsSaveFailedScans] && savedFailScans < MAX_SAVES)
    return YES;
  if([defaults boolForKey: kSettingsSaveSucceededScans] && savedSuccScans < MAX_SAVES)
    return YES;
  if([defaults boolForKey: kSettingsSaveFailedCounts] && savedFailCounts < MAX_SAVES)
    return YES;
  return NO;
}

- (void) guideByVoice: (NSArray *) qrcs width: (size_t) width height: (size_t) height
{
  // For now, pretty simple guidance. If number of QR codes != 1, then
  // say the number seen. If there is 1 code at edge, name the edge.
  // If there's 1 code that seems too small, say "too high". If there's 1
  // code that seems too large, say "too low". Otherwise just say "one".
  //
  // Note: images are presented in landscape mode with home button to
  // the right. We're translating here between this orientation and the
  // expected portrait orientation of the phone while scanning. (This is
  // something to figure out, however.)
  //
# define LARGEST_QRC_PX 48400
# define SMALLEST_QRC 60
  BOOL guided;
  Blob *qrc1;
  self.signal.period = SIGNAL_INF_PERIOD; // Make sure no beeps
  switch([qrcs count]) {
    case 0: guided = [self.voice offerGuidance: @"zero"]; break;
    case 1:
      qrc1 = qrcs[0];
      if ([qrc1 touchesTop])
        guided = [self.voice offerGuidance: @"right"];
      else if ([qrc1 touchesBottom])
        guided = [self.voice offerGuidance: @"left"];
      else if ([qrc1 touchesLeft])
        guided = [self.voice offerGuidance: @"top"];
      else if ([qrc1 touchesRight])
        guided = [self.voice offerGuidance: @"bottom"];
      else if ([qrc1 width] < SMALLEST_QRC && [qrc1 height] < SMALLEST_QRC)
        guided = [self.voice offerGuidance: @"too high"];
      else if (qrc1.pixelCount > LARGEST_QRC_PX)
        guided = [self.voice offerGuidance: @"too low"];
      else
        guided = [self.voice offerGuidance: @"one"];
      break;
    case 2: guided = [self.voice offerGuidance: @"two"]; break;
    case 3: guided = [self.voice offerGuidance: @"three"]; break;
    default: guided = [self.voice offerGuidance: @"many"]; break;
  }
  self.synchronizer.goodTime = guided;
}

- (void) guideByBeep: (NSArray *) qrcs width: (int) width height: (int) height
{
  // For now, issue beeps when there is just one QRC. Beep faster
  // when it's near the center of the display.
  //
  CFTimeInterval period;
  Blob *qrc1;
  int dist;
# define SMALL_DIST 90
# define LARGE_DIST 240

  if ([qrcs count] == 1) {
    qrc1 = qrcs[0];
    dist = abs(qrc1.minx - width / 2);
    dist = MAX(dist, abs(qrc1.maxx - width / 2));
    dist = MAX(dist, abs(qrc1.miny - height / 2));
    dist = MAX(dist, abs(qrc1.maxy - height / 2));
    dist = MAX(SMALL_DIST, dist);
    dist = MIN(LARGE_DIST, dist);
    period = 0.4 + 1.1 * ((double) (dist - SMALL_DIST) / (double) (LARGE_DIST - SMALL_DIST));
  } else {
    period = SIGNAL_INF_PERIOD;
  }
  self.signal.period = period;
  [self.synchronizer step];
}

- (void) zxingController: (ZXingWidgetController *) controller
           didScanResult: (NSString *) scanres
{
  if ([defaults boolForKey: kSettingsSaveSucceededScans] && bitmapCopy && savedSuccScans++ < MAX_SAVES) {
    NSString *anno = [self gravityDescription: @"Y " gravity: copyGrav];
    [self saveFrame: bitmapCopy width:copyWidth height:copyHeight annotation: anno];
  }
#if TGV_EXPERIMENTAL
  NSString *line = [NSString stringWithFormat: @"Scan succeeded, text %@", scanres];
  [self.eventLog log: line];
#endif
  [self.resultsController addResult: scanres];
  self.tabController.selectedViewController = self.resultsController;
  if (bitmapCopy) free(bitmapCopy);
  bitmapCopy = NULL;
}

- (void) zxingController:(ZXingWidgetController *) controller didNotScanReason:(NSString *)reason
{
  // To avoid saving too many similar images, only save failed images when
  // it's a good time (around once a second).
  //
  if ([defaults boolForKey: kSettingsSaveFailedScans] && bitmapCopy &&
      copyGoodTime && savedFailScans++ < MAX_SAVES) {
    NSString *anno = [self gravityDescription: @"N " gravity: copyGrav];
    [self saveFrame: bitmapCopy width:copyWidth height:copyHeight annotation: anno];
  }
  if (bitmapCopy) free(bitmapCopy);
  bitmapCopy = NULL;
}

- (void) zxingControllerDidCancel: (ZXingWidgetController *) controller
{
#if TGV_EXPERIMENTAL
  [self.eventLog log: @"Scan cancelled"];
#endif
  self.tabController.selectedViewController = self.resultsController;
  if (bitmapCopy) free(bitmapCopy);
  bitmapCopy = NULL;
}


- (id) init
{
  if(!(self = [super initWithDelegate: self showCancel: NO OneDMode:NO showLicense:NO]))
    return nil;
  [self setup];
  return self;
}

- (id) initWithCoder: (NSCoder *) aDecoder
{
  if(!(self = [super initWithCoder: aDecoder]))
    return nil;
  self.delegate = self;
  self.showCancel = NO;
  self.oneDMode = NO;
  self.showLicense = NO;
  [self setup];
  return self;
}

- (void) setup
{
  // Shared initialization code.
  //
  defaults = [NSUserDefaults standardUserDefaults];

  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(didBecomeActive:)
             name:UIApplicationDidBecomeActiveNotification
           object:nil];
  NSMutableSet *readerset = [[NSMutableSet alloc ] init];

  QRCodeReader* qrcodeReader = [[QRCodeReader alloc] init];
  [readerset addObject:qrcodeReader];
  [qrcodeReader release];
  
  self.readers = readerset;
  [readerset release];
  
  NSBundle *mainBundle = [NSBundle mainBundle];
  self.soundToPlay =
    [NSURL fileURLWithPath:[mainBundle pathForResource:@"epianodbmaj" ofType:@"aif"] isDirectory:NO];
}

- (void) viewDidAppear:(BOOL)animated
{
#if TGV_EXPERIMENTAL
  [self.eventLog log: @"Scanning started"];
#endif
  [super viewDidAppear:animated];
  [self.voice initializeGuidance];
  if ([defaults boolForKey: kSettingsIlluminateScans]) {
    [self setTorch: YES];
    [self.voice offerGuidance: @"Illumination is on"];
  }
  savedFailScans = 0;
  savedSuccScans = 0;
  savedFailCounts = 0;
}

- (void) viewDidDisappear: (BOOL) animated
{
  [super viewDidDisappear: animated];
  if(self.motionManager) {
    [self.motionManager stopDeviceMotionUpdates];
    self.motionManager = nil;
  }
  if ([self torchIsOn])
    [self setTorch: NO];
}

- (void) didBecomeActive: (NSNotification *) notification
{
  if ([self.tabBarController selectedViewController] != self)
    return;
#if TGV_EXPERIMENTAL
  [self.eventLog log: @"Scanning restarted from background"];
#endif
  [self.voice initializeGuidance];
  if ([defaults boolForKey: kSettingsIlluminateScans]) {
    [self setTorch: YES];
    // Wait for silent period when restarting in scan mode.
    // Note: this doesn't work very well currently. It might help
    // to have a way to queue up a guidance message.
    //
    [self.voice performSelector: @selector(offerGuidance:)
                     withObject: @"Illumination is on"
                     afterDelay: 1.8];
    // [self.voice offerGuidance: @"Illumination is on"];
  }
  savedFailScans = 0;
  savedSuccScans = 0;
  savedFailCounts = 0;
}

- (BOOL) scanViewShouldReportTouches:(ScanView *)scanView
{
#if TGV_EXPERIMENTAL
  return [defaults boolForKey: kSettingsTrackTouches];
#else
  return NO;
#endif
}

- (void) scanView: scanView didFeelTouchesAtPoints: (NSArray *) points
{
  self.trackedPoints = points;
}

- (BOOL) eventLogShouldLogEvent:(EventLog *)eventLog
{
  return [defaults boolForKey: kSettingsLogEvents];
}

- (void) saveFrame: (uint8_t *) bitmap
             width: (size_t) width
            height: (size_t) height
        annotation: (NSString *) annotation
{
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx =
    CGBitmapContextCreate(bitmap, width, height, 8, width * BPP, colorSpace,
                        kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
  CGContextSelectFont(ctx, "Helvetica", ANNOT_HEIGHT - 6, kCGEncodingMacRoman);
  const char *text = [annotation UTF8String];
  CGContextShowTextAtPoint(ctx, 5, 5, text, strlen(text));
  CGImageRef image = CGBitmapContextCreateImage(ctx);
  CGContextRelease(ctx);
  CGColorSpaceRelease(colorSpace);
  UIImageWriteToSavedPhotosAlbum([UIImage imageWithCGImage: image], nil, nil, nil);
  CGImageRelease(image);
}

- (NSString *) gravityDescription: (NSString *) prefix gravity: (CMAcceleration) accel
{
# define DOT(x0,y0,z0,x1,y1,z1) (x0*x1 + y0*y1 + z0*z1)
# define MAG(x,y,z) sqrt(x*x + y*y + z*z)
# define BETWEEN(x0,y0,z0,x1,y1,z1) \
   acos(DOT(x0,y0,z0,x1,y1,z1)/(MAG(x0,y0,z0)*MAG(x1,y1,z1)))
# define DEGREES(theta) ((int) (theta * 57.29577951308232 + 0.5))
  
  // Gravity reports as (0.0, 0.0, 0.0) when not warmed up. Otherwise
  // it's a unit vector.
  //
  if(MAG(accel.x, accel.y, accel.z) < 0.5)
    return [NSString stringWithFormat:@"%@(No gravity data)", prefix];
  
  // Our expected down direction is (0.0, 0.0, -1.0) in device coordinates
  double slant = BETWEEN(accel.x, accel.y, accel.z, 0.0, 0.0, -1.0);
  // Projected (x, y) of gravity gives the low spot, so (-x, -y) is
  // high spot.
  double high = atan2(-accel.y, -accel.x);

  high += M_PI / 8.0; // Round to octant
  if (high < 0.0) high += 2.0 * M_PI;
  int hidir = (int) (high / M_PI * 4.0);
  NSString *dirs[] = { @"E", @"NE", @"N", @"NW", @"W", @"SW", @"S", @"SE" };
  
  return [NSString stringWithFormat: @"%@tilt %d, hi pt %@ (%6.3f, %6.3f, %6.3f)",
           prefix, DEGREES(slant), dirs[hidir], accel.x, accel.y, accel.z];
}

- (void) dealloc
{
  self.eventLog = nil;
  if (self.motionManager) {
    [self.motionManager stopDeviceMotionUpdates];
    self.motionManager = nil;
  }
  self.synchronizer = nil;
  self.voice = nil;
  self.signal = nil;
  [super dealloc];
}
@end
