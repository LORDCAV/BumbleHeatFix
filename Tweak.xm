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
@end

@implementation ThermalThrottleManager

// ============================================================
//  UI OVERLAY - FIXED FOR NOTCH / DYNAMIC ISLAND
// ============================================================
+ (void)updateOverlay {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!overlayWindow) {
            UIWindowScene *scene = [UIApplication sharedApplication].keyWindow.windowScene;
            if (!scene) return;
            
            // Get safe area insets to avoid the notch
            UIEdgeInsets safeInsets = UIApplication.sharedApplication.keyWindow.safeAreaInsets;
            CGFloat topInset = safeInsets.top;
            
            // Position overlay below the notch/status bar
            CGFloat overlayHeight = 44;
            CGFloat overlayY = topInset; // Start right below the notch
            
            overlayWindow = [[UIWindow alloc] initWithWindowScene:scene];
            overlayWindow.frame = CGRectMake(0, overlayY, [UIScreen mainScreen].bounds.size.width, overlayHeight);
            overlayWindow.windowLevel = UIWindowLevelStatusBar + 1;
            overlayWindow.backgroundColor = [UIColor clearColor];
            overlayWindow.userInteractionEnabled = YES; // IMPORTANT: Enable interaction
            
            overlayLabel = [[UILabel alloc] initWithFrame:overlayWindow.bounds];
            overlayLabel.textAlignment = NSTextAlignmentCenter;
            overlayLabel.font = [UIFont boldSystemFontOfSize:15];
            overlayLabel.textColor = [UIColor whiteColor];
            overlayLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.7];
            overlayLabel.layer.cornerRadius = 10;
            overlayLabel.clipsToBounds = YES;
            [overlayWindow addSubview:overlayLabel];
            
            // Make the entire overlay tappable
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[ThermalThrottleManager class] 
                                                                                 action:@selector(toggleThrottle)];
            tap.numberOfTapsRequired = 3;
            [overlayWindow addGestureRecognizer:tap];
            
            // Make it visible
            overlayWindow.hidden = NO;
        }
        
        // Update text
        if (isThrottlingActive) {
            overlayLabel.text = @"🔥 Throttling ON (triple-tap to toggle)";
            overlayLabel.backgroundColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.1 alpha:0.75];
        } else {
            overlayLabel.text = @"⛔ Throttling OFF (triple-tap to toggle)";
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
    
    // Show a quick visual feedback
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
//  IDLE TIMER
// ============================================================
+ (void)resetIdleTimer {
    [idleTimer invalidate];
    idleTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 
                                                 repeats:NO 
                                                   block:^(NSTimer *timer) {
        if (currentThermalState >= NSProcessInfoThermalStateFair || isThrottlingActive) {
            NSLog(@"[Thermal] 💤 User idle for 30s - killing GPS until next touch");
            [[NSNotificationCenter defaultCenter] postNotificationName:@"BumbleThermalKillGPS" object:nil];
            gpsKilledForIdle = YES;
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
                
                NSLog(@"[Thermal] ⏳ Delaying %@ on %@ due to throttling", pattern, NSStringFromClass(cls));
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    NSLog(@"[Thermal] 🔹 Executing delayed %@", pattern);
                });
                return;
            }
        }
        NSLog(@"[Thermal] 🔹 Executing %@ on %@ (throttling %@)", pattern, NSStringFromClass(cls), isThrottlingActive ? @"ON" : @"OFF");
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
        NSLog(@"[Thermal] 📍 Location: low accuracy due to throttling");
    }
    %orig;
}

- (void)setDesiredAccuracy:(CLLocationAccuracy)accuracy {
    if (isThrottlingActive || gpsKilledForIdle) {
        accuracy = kCLLocationAccuracyKilometer;
        NSLog(@"[Thermal] 📍 Location: forced accuracy downgrade");
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
//  SYSTEM HOOKS - NETWORK
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
                NSLog(@"[Thermal] 🖼️ Image download set to LOW priority");
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
//  SYSTEM HOOKS - BACKGROUND TASKS
// ============================================================
%hook UIApplication

- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithName:(NSString *)taskName 
                                         expirationHandler:(void (^)(void))handler {
    if (isThrottlingActive) {
        NSLog(@"[Thermal] ⏱️ Reducing background task time for: %@", taskName);
    }
    return %orig(taskName, handler);
}

- (void)setMinimumBackgroundFetchInterval:(NSTimeInterval)minimumBackgroundFetchInterval {
    if (isThrottlingActive) {
        minimumBackgroundFetchInterval = 86400; // 24 hours
        NSLog(@"[Thermal] ⏱️ Background fetch interval extended to 24h");
    }
    %orig(minimumBackgroundFetchInterval);
}

- (void)sendEvent:(UIEvent *)event {
    %orig;
    if (event.type == UIEventTypeTouches) {
        if (gpsKilledForIdle) {
            gpsKilledForIdle = NO;
            NSLog(@"[Thermal] 👆 Touch detected - restoring GPS");
        }
        [ThermalThrottleManager resetIdleTimer];
    }
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
//  SYSTEM HOOKS - APP DELEGATE
// ============================================================
%hook AppDelegate

- (void)applicationDidEnterBackground:(UIApplication *)application {
    %orig;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"BumbleThermalKillGPS" object:nil];
    gpsKilledForIdle = YES;
    NSLog(@"[Thermal] 📍 GPS killed for background idle");
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    %orig;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"BumbleThermalRestoreGPS" object:nil];
    gpsKilledForIdle = NO;
    NSLog(@"[Thermal] 📍 GPS restored for foreground");
}

%end

// ============================================================
//  MAIN ENTRY POINT
// ============================================================
%ctor {
    NSLog(@"[Thermal] ✅ Thermal throttling dylib loaded!");
    
    // Load manual toggle from preferences
    manualThrottleEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:kManualToggleKey];
    
    // Start thermal monitoring
    [NSTimer scheduledTimerWithTimeInterval:2.0 
                                     repeats:YES 
                                     block:^(NSTimer *timer) {
        NSProcessInfoThermalState newState = [NSProcessInfo processInfo].thermalState;
        BOOL wasThermalActive = thermalActive;
        thermalActive = (newState >= NSProcessInfoThermalStateSerious);
        
        if (thermalActive != wasThermalActive) {
            NSString *stateName = @"Nominal";
            if (newState == NSProcessInfoThermalStateFair) stateName = @"Fair ⚠️";
            else if (newState == NSProcessInfoThermalStateSerious) stateName = @"Serious 🔥";
            else if (newState == NSProcessInfoThermalStateCritical) stateName = @"Critical 🚨";
            NSLog(@"[Thermal] Thermal state: %@", stateName);
        }
        
        [ThermalThrottleManager updateCombinedState];
    }];
    
    // Delay overlay creation until app is ready
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [ThermalThrottleManager updateCombinedState];
        [ThermalThrottleManager updateOverlay];
    });
    
    // Run dynamic swizzling after classes load
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [ThermalThrottleManager performDynamicSwizzling];
    });
}
