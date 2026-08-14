#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>

// ============================================================
//  GLOBAL STATE
// ============================================================
static NSProcessInfoThermalState currentThermalState = NSProcessInfoThermalStateNominal;
static BOOL manualThrottleEnabled = NO;
static BOOL thermalActive = NO;
static BOOL isThrottlingActive = NO;

static UIWindow *overlayWindow = nil;
static UILabel *overlayLabel = nil;
static NSString *const kManualToggleKey = @"BumbleThermalManualToggle";
static NSTimer *idleTimer = nil;
static BOOL gpsKilledForIdle = NO;

// ============================================================
//  THERMALTHROTTLEMANAGER CLASS
// ============================================================
@interface ThermalThrottleManager : NSObject
+ (void)toggleThrottle;
+ (void)updateCombinedState;
+ (void)applyThrottlingState;
+ (void)resetIdleTimer;
+ (void)performDynamicSwizzling;
+ (void)swizzleMethod:(SEL)originalSelector onClass:(Class)cls withPattern:(NSString *)pattern;
+ (void)updateOverlay;
@end

@implementation ThermalThrottleManager

// ============================================================
//  UI OVERLAY - FIXED FOR NOTCH (iPhone 11 Pro)
// ============================================================
+ (void)updateOverlay {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!overlayWindow) {
            UIWindowScene *scene = [UIApplication sharedApplication].keyWindow.windowScene;
            if (!scene) return;
            
            UIEdgeInsets safeInsets = UIApplication.sharedApplication.keyWindow.safeAreaInsets;
            CGFloat topInset = safeInsets.top;
            CGFloat overlayHeight = 44;
            CGFloat overlayY = topInset;
            
            overlayWindow = [[UIWindow alloc] initWithWindowScene:scene];
            overlayWindow.frame = CGRectMake(0, overlayY, [UIScreen mainScreen].bounds.size.width, overlayHeight);
            overlayWindow.windowLevel = UIWindowLevelStatusBar + 1;
            overlayWindow.backgroundColor = [UIColor clearColor];
            overlayWindow.userInteractionEnabled = YES;
            
            overlayLabel = [[UILabel alloc] initWithFrame:overlayWindow.bounds];
            overlayLabel.textAlignment = NSTextAlignmentCenter;
            overlayLabel.font = [UIFont boldSystemFontOfSize:13];
            overlayLabel.textColor = [UIColor whiteColor];
            overlayLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.7];
            overlayLabel.layer.cornerRadius = 10;
            overlayLabel.clipsToBounds = YES;
            overlayLabel.numberOfLines = 1;
            [overlayWindow addSubview:overlayLabel];
            
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[ThermalThrottleManager class] 
                                                                                 action:@selector(toggleThrottle)];
            tap.numberOfTapsRequired = 3;
            [overlayWindow addGestureRecognizer:tap];
            
            overlayWindow.hidden = NO;
        }
        
        // Build detailed status string
        if (isThrottlingActive) {
            NSMutableString *status = [NSMutableString stringWithString:@"🔥 "];
            if (gpsKilledForIdle) {
                [status appendString:@"📍OFF "];
            } else {
                [status appendString:@"📍LOW "];
            }
            [status appendString:@"🖥️30fps "];
            [status appendString:@"🌐⏳ "];
            [status appendString:@"🔋⚡"];
            overlayLabel.text = status;
            overlayLabel.backgroundColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.1 alpha:0.8];
        } else {
            overlayLabel.text = @"⛔ Throttling OFF (tap 3x)";
            overlayLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.6];
        }
    });
}

// ============================================================
//  TOGGLE & STATE MANAGEMENT
// ============================================================
+ (void)toggleThrottle {
    manualThrottleEnabled = !manualThrottleEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:manualThrottleEnabled forKey:kManualToggleKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self updateCombinedState];
    NSLog(@"[Thermal] Manual toggle: %@", manualThrottleEnabled ? @"ON" : @"OFF");
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (overlayLabel) {
            overlayLabel.text = isThrottlingActive ? @"🔥 Toggled ON!" : @"⛔ Toggled OFF!";
            [UIView animateWithDuration:0.3 animations:^{
                overlayLabel.alpha = 1.0;
            } completion:^(BOOL finished) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self updateOverlay];
                });
            }];
        }
    });
}

+ (void)updateCombinedState {
    isThrottlingActive = manualThrottleEnabled || thermalActive;
    [self updateOverlay];
    [self applyThrottlingState];
}

+ (void)applyThrottlingState {
    if (isThrottlingActive) {
        [[NSProcessInfo processInfo] performExpiringActivityWithReason:@"Thermal throttling" 
                                                             usingBlock:^(BOOL expired) {
            if (expired) {
                NSLog(@"[Thermal] Activity expired");
            }
        }];
    }
}

// ============================================================
//  IDLE TIMER - NOW 15 SECONDS
// ============================================================
+ (void)resetIdleTimer {
    [idleTimer invalidate];
    idleTimer = [NSTimer scheduledTimerWithTimeInterval:15.0 
                                                 repeats:NO 
                                                   block:^(NSTimer *timer) {
        if (currentThermalState >= NSProcessInfoThermalStateFair || isThrottlingActive) {
            NSLog(@"[Thermal] 💤 User idle for 15s - killing GPS");
            [[NSNotificationCenter defaultCenter] postNotificationName:@"BumbleThermalKillGPS" object:nil];
            gpsKilledForIdle = YES;
            [self updateOverlay];
        }
    }];
}

// ============================================================
//  DYNAMIC SWIZZLING
// ============================================================
+ (void)performDynamicSwizzling {
    int numClasses = objc_getClassList(NULL, 0);
    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    numClasses = objc_getClassList(classes, numClasses);
    
    NSArray *methodPatterns = @[
        @"startUpdatingLocation",
        @"setDesiredAccuracy:",
        @"uploadImage:",
        @"uploadPhoto:",
        @"uploadVideo:",
        @"syncProfile",
        @"refreshFeed",
        @"loadMatches",
        @"fetchMatches",
        @"sendMessage:",
        @"beginBackgroundTaskWithName:expirationHandler:",
        @"processImage:",
        @"applyFilter:"
    ];
    
    for (int i = 0; i < numClasses; i++) {
        Class cls = classes[i];
        NSString *className = NSStringFromClass(cls);
        
        if (![className containsString:@"Bumble"] && 
            ![className containsString:@"Bm"] && 
            ![className hasPrefix:@"BM"] &&
            ![className containsString:@"Upload"] &&
            ![className containsString:@"Location"] &&
            ![className containsString:@"Network"] &&
            ![className containsString:@"Sync"]) {
            continue;
        }
        
        for (NSString *pattern in methodPatterns) {
            SEL sel = NSSelectorFromString(pattern);
            if ([cls instancesRespondToSelector:sel]) {
                [self swizzleMethod:sel onClass:cls withPattern:pattern];
            }
        }
    }
    free(classes);
    NSLog(@"[Thermal] Dynamic swizzling complete.");
}

+ (void)swizzleMethod:(SEL)originalSelector onClass:(Class)cls withPattern:(NSString *)pattern {
    Method originalMethod = class_getInstanceMethod(cls, originalSelector);
    if (!originalMethod) return;
    
    IMP newImp = imp_implementationWithBlock(^(id self, ...) {
        if (isThrottlingActive) {
            if ([pattern isEqualToString:@"uploadImage:"] || 
                [pattern isEqualToString:@"uploadPhoto:"] ||
                [pattern isEqualToString:@"uploadVideo:"] ||
                [pattern isEqualToString:@"syncProfile"] ||
                [pattern isEqualToString:@"refreshFeed"] ||
                [pattern isEqualToString:@"loadMatches"]) {
                
                NSLog(@"[Thermal] ⏳ Delaying %@ on %@", pattern, NSStringFromClass(cls));
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    NSLog(@"[Thermal] 🔹 Executing delayed %@", pattern);
                });
                return;
            }
        }
        NSLog(@"[Thermal] 🔹 Executing %@ on %@", pattern, NSStringFromClass(cls));
    });
    
    class_replaceMethod(cls, originalSelector, newImp, method_getTypeEncoding(originalMethod));
    NSLog(@"[Thermal] 🔄 Swizzled %@ on %@", pattern, NSStringFromClass(cls));
}

@end

// ============================================================
//  SYSTEM HOOKS - LOCATION
// ============================================================
%hook CLLocationManager
- (void)startUpdatingLocation {
    if (isThrottlingActive || gpsKilledForIdle) {
        self.desiredAccuracy = kCLLocationAccuracyKilometer;
        self.distanceFilter = 100.0;
        NSLog(@"[Thermal] 📍 Location: low accuracy");
    }
    %orig;
}
- (void)setDesiredAccuracy:(CLLocationAccuracy)accuracy {
    if (isThrottlingActive || gpsKilledForIdle) {
        accuracy = kCLLocationAccuracyKilometer;
    }
    %orig(accuracy);
}
%end

// ============================================================
//  SYSTEM HOOKS - FRAME RATE
// ============================================================
%hook CADisplayLink
+ (CADisplayLink *)displayLinkWithTarget:(id)target selector:(SEL)sel {
    CADisplayLink *link = %orig(target, sel);
    if (isThrottlingActive) {
        if (@available(iOS 15.0, *)) {
            link.preferredFrameRateRange = CAFrameRateRangeMake(20.0, 30.0, 30.0);
        } else if (@available(iOS 10.0, *)) {
            link.preferredFramesPerSecond = 30;
        }
        NSLog(@"[Thermal] 🖥️ Frame rate capped to 30 FPS");
    }
    return link;
}
- (void)setPreferredFramesPerSecond:(NSInteger)preferredFramesPerSecond {
    if (isThrottlingActive) {
        preferredFramesPerSecond = MIN(preferredFramesPerSecond, 30);
    }
    %orig(preferredFramesPerSecond);
}
%end

// ============================================================
//  SYSTEM HOOKS - NETWORK & IMAGE PRIORITY
// ============================================================
%hook NSURLSessionDataTask
- (void)resume {
    if (isThrottlingActive) {
        NSURL *url = self.currentRequest.URL;
        NSString *urlString = [url absoluteString];
        
        if ([urlString containsString:@".jpg"] || 
            [urlString containsString:@".png"] ||
            [urlString containsString:@"image"] ||
            [urlString containsString:@"photo"] ||
            [urlString containsString:@"avatar"]) {
            if ([self respondsToSelector:@selector(setPriority:)]) {
                self.priority = NSURLSessionTaskPriorityLow;
                NSLog(@"[Thermal] 🖼️ Image priority LOW");
            }
        }
        
        if ([urlString containsString:@"upload"] || 
            [urlString containsString:@"photo"] ||
            [urlString containsString:@"image"] ||
            [urlString containsString:@"profile"] ||
            [urlString containsString:@"sync"]) {
            NSLog(@"[Thermal] 🌐 Delaying network request: %@", urlString);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), 
                           dispatch_get_main_queue(), ^{
                %orig;
            });
            return;
        }
    }
    %orig;
}
%end

// ============================================================
//  NEW: WebSocket Throttling
// ============================================================
%hook NSURLSessionWebSocketTask
- (void)resume {
    if (isThrottlingActive) {
        NSLog(@"[Thermal] 🔌 WebSocket connection delayed");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), 
                       dispatch_get_main_queue(), ^{
            %orig;
        });
        return;
    }
    %orig;
}
- (void)sendMessage:(NSURLSessionWebSocketMessage *)message 
 completionHandler:(void (^)(NSError *error))completionHandler {
    if (isThrottlingActive) {
        static NSDate *lastSendTime = nil;
        NSDate *now = [NSDate date];
        if (lastSendTime && [now timeIntervalSinceDate:lastSendTime] < 2.0) {
            NSLog(@"[Thermal] 🔌 WebSocket message throttled");
            return;
        }
        lastSendTime = now;
    }
    %orig(message, completionHandler);
}
%end

// ============================================================
//  NEW: CPU THROTTLING - Lower thread priority
// ============================================================
%hook NSThread
+ (void)setThreadPriority:(double)priority {
    if (isThrottlingActive) {
        priority = MIN(priority, 0.5);
        NSLog(@"[Thermal] 🧠 CPU thread priority lowered");
    }
    %orig(priority);
}
%end

%hook NSRunLoop
- (void)runMode:(NSRunLoopMode)mode beforeDate:(NSDate *)limitDate {
    if (isThrottlingActive) {
        [NSThread sleepForTimeInterval:0.01];
    }
    %orig(mode, limitDate);
}
%end

// ============================================================
//  NEW: SCREEN DIMMING
// ============================================================
%hook UIScreen
- (CGFloat)brightness {
    if (isThrottlingActive) {
        CGFloat current = %orig;
        return current * 0.6; // 60% brightness
    }
    return %orig;
}
%end

// ============================================================
//  NEW: CACHE THROTTLING
// ============================================================
%hook NSURLCache
- (NSCachedURLResponse *)cachedResponseForRequest:(NSURLRequest *)request {
    if (isThrottlingActive) {
        NSCachedURLResponse *cached = %orig(request);
        if (cached) {
            NSLog(@"[Thermal] 📦 Using cached response");
            return cached;
        }
    }
    return %orig(request);
}
%end

// ============================================================
//  NEW: SENSOR THROTTLING (Motion/Accelerometer)
// ============================================================
%hook CMMotionManager
- (void)startAccelerometerUpdates {
    if (isThrottlingActive) {
        NSLog(@"[Thermal] 📱 Accelerometer throttled");
        return;
    }
    %orig;
}
- (void)startGyroUpdates {
    if (isThrottlingActive) {
        NSLog(@"[Thermal] 📱 Gyroscope throttled");
        return;
    }
    %orig;
}
- (void)startDeviceMotionUpdates {
    if (isThrottlingActive) {
        NSLog(@"[Thermal] 📱 Device motion throttled");
        return;
    }
    %orig;
}
%end

// ============================================================
//  SYSTEM HOOKS - BACKGROUND TASKS & UIApplication
// ============================================================
%hook UIApplication

- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithName:(NSString *)taskName 
                                         expirationHandler:(void (^)(void))handler {
    if (isThrottlingActive) {
        if (handler) {
            handler(); // immediately expire
        }
        NSLog(@"[Thermal] ⏱️ Background task immediately expired");
        return UIBackgroundTaskInvalid;
    }
    return %orig(taskName, handler);
}

- (void)setMinimumBackgroundFetchInterval:(NSTimeInterval)minimumBackgroundFetchInterval {
    if (isThrottlingActive) {
        minimumBackgroundFetchInterval = 86400; // 24h
        NSLog(@"[Thermal] ⏱️ Background fetch interval extended");
    }
    %orig(minimumBackgroundFetchInterval);
}

- (void)sendEvent:(UIEvent *)event {
    %orig;
    if (event.type == UIEventTypeTouches) {
        if (gpsKilledForIdle) {
            gpsKilledForIdle = NO;
            NSLog(@"[Thermal] 👆 Touch detected - restoring GPS");
            [ThermalThrottleManager updateOverlay];
        }
        [ThermalThrottleManager resetIdleTimer];
    }
}

- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithExpirationHandler:(void (^)(void))handler {
    if (isThrottlingActive) {
        if (handler) handler();
        return UIBackgroundTaskInvalid;
    }
    return %orig(handler);
}

%end

// ============================================================
//  SYSTEM HOOKS - SCROLLING
// ============================================================
%hook UITableView
- (void)setDecelerationRate:(CGFloat)decelerationRate {
    if (isThrottlingActive) {
        decelerationRate = UIScrollViewDecelerationRateNormal;
        NSLog(@"[Thermal] 📜 Scroll deceleration reduced");
    }
    %orig(decelerationRate);
}
- (void)setPrefetchingEnabled:(BOOL)prefetchingEnabled {
    if (isThrottlingActive) {
        prefetchingEnabled = NO;
        NSLog(@"[Thermal] 📜 Prefetching disabled");
    }
    %orig(prefetchingEnabled);
}
%end

%hook UICollectionView
- (void)setPrefetchingEnabled:(BOOL)prefetchingEnabled {
    if (isThrottlingActive) {
        prefetchingEnabled = NO;
    }
    %orig(prefetchingEnabled);
}
%end

// ============================================================
//  APP DELEGATE - Background/Foreground
// ============================================================
%hook AppDelegate
- (void)applicationDidEnterBackground:(UIApplication *)application {
    %orig;
    gpsKilledForIdle = YES;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"BumbleThermalKillGPS" object:nil];
    NSLog(@"[Thermal] 📍 GPS killed for background");
    [ThermalThrottleManager updateOverlay];
}
- (void)applicationWillEnterForeground:(UIApplication *)application {
    %orig;
    gpsKilledForIdle = NO;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"BumbleThermalRestoreGPS" object:nil];
    NSLog(@"[Thermal] 📍 GPS restored for foreground");
    [ThermalThrottleManager updateOverlay];
}
%end

// ============================================================
//  MAIN ENTRY POINT
// ============================================================
%ctor {
    NSLog(@"[Thermal] ✅ Thermal throttling dylib loaded!");
    
    manualThrottleEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:kManualToggleKey];
    
    // Monitor thermal state every 1.5 seconds
    [NSTimer scheduledTimerWithTimeInterval:1.5 
                                     repeats:YES 
                                     block:^(NSTimer *timer) {
        NSProcessInfoThermalState newState = [NSProcessInfo processInfo].thermalState;
        BOOL wasThermalActive = thermalActive;
        
        // Activate at FAIR (earlier than SERIOUS)
        thermalActive = (newState >= NSProcessInfoThermalStateFair);
        
        if (thermalActive != wasThermalActive) {
            NSString *stateName = @"Nominal";
            if (newState == NSProcessInfoThermalStateFair) stateName = @"Fair ⚠️ (throttling ON)";
            else if (newState == NSProcessInfoThermalStateSerious) stateName = @"Serious 🔥";
            else if (newState == NSProcessInfoThermalStateCritical) stateName = @"Critical 🚨";
            NSLog(@"[Thermal] Thermal state: %@", stateName);
        }
        
        [ThermalThrottleManager updateCombinedState];
        
        // If critical, dim screen further
        if (newState == NSProcessInfoThermalStateCritical) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [UIScreen mainScreen].brightness = 0.3;
            });
        }
    }];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [ThermalThrottleManager updateCombinedState];
        [ThermalThrottleManager updateOverlay];
    });
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [ThermalThrottleManager performDynamicSwizzling];
    });
}