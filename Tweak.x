#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <mach/task.h>
#import <mach/thread_act.h>

static UIWindow *BHFOverlayWindow = nil;
static UILabel *BHFLabel = nil;

static double BHFCPUTime(void)
{
    task_thread_times_info_data_t info;
    mach_msg_type_number_t count = TASK_THREAD_TIMES_INFO_COUNT;

    kern_return_t kr = task_info(
        mach_task_self(),
        TASK_THREAD_TIMES_INFO,
        (task_info_t)&info,
        &count
    );

    if (kr != KERN_SUCCESS) {
        return -1.0;
    }

    return
        (double)info.user_time.seconds +
        (double)info.user_time.microseconds / 1000000.0 +
        (double)info.system_time.seconds +
        (double)info.system_time.microseconds / 1000000.0;
}

static NSUInteger BHFThreadCount(void)
{
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;

    kern_return_t kr = task_threads(
        mach_task_self(),
        &threads,
        &count
    );

    if (kr != KERN_SUCCESS) {
        return 0;
    }

    if (threads != NULL) {
        vm_deallocate(
            mach_task_self(),
            (vm_address_t)threads,
            count * sizeof(thread_t)
        );
    }

    return (NSUInteger)count;
}

static uint64_t BHFMemoryUsage(void)
{
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;

    kern_return_t kr = task_info(
        mach_task_self(),
        TASK_VM_INFO,
        (task_info_t)&info,
        &count
    );

    if (kr != KERN_SUCCESS) {
        return 0;
    }

    return info.phys_footprint;
}

static NSString *BHFFormatMemory(uint64_t bytes)
{
    double mb = (double)bytes / (1024.0 * 1024.0);

    if (mb >= 1024.0) {
        return [NSString stringWithFormat:@"%.2f GB",
                mb / 1024.0];
    }

    return [NSString stringWithFormat:@"%.0f MB", mb];
}

static UIWindow *BHFFindWindow(void)
{
    if (@available(iOS 13.0, *)) {

        for (UIScene *scene
             in [UIApplication sharedApplication].connectedScenes) {

            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }

            UIWindowScene *windowScene =
                (UIWindowScene *)scene;

            if (windowScene.activationState !=
                    UISceneActivationStateForegroundActive &&
                windowScene.activationState !=
                    UISceneActivationStateForegroundInactive) {
                continue;
            }

            for (UIWindow *window in windowScene.windows) {

                if (window.hidden) {
                    continue;
                }

                if (window.rootViewController == nil) {
                    continue;
                }

                if (window.windowLevel != UIWindowLevelNormal) {
                    continue;
                }

                return window;
            }
        }
    }

    return nil;
}

static void BHFUpdateOverlay(void)
{
    if (BHFLabel == nil) {
        return;
    }

    double cpuTime = BHFCPUTime();
    NSUInteger threads = BHFThreadCount();
    uint64_t memory = BHFMemoryUsage();

    NSString *cpuText;

    if (cpuTime < 0.0) {
        cpuText = @"CPU time: unavailable";
    } else {
        cpuText =
            [NSString stringWithFormat:
                @"CPU time: %.2fs",
                cpuTime];
    }

    NSString *text =
        [NSString stringWithFormat:
            @"BumbleHeatFix\n"
             "MONITOR\n"
             "────────────\n"
             "%@\n"
             "Threads: %lu\n"
             "Memory: %@",
            cpuText,
            (unsigned long)threads,
            BHFFormatMemory(memory)];

    dispatch_async(dispatch_get_main_queue(), ^{
        BHFLabel.text = text;
    });
}

static void BHFCreateOverlay(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{

        if (BHFOverlayWindow != nil) {
            return;
        }

        UIWindow *hostWindow = BHFFindWindow();

        if (hostWindow == nil) {
            NSLog(@"[BumbleHeatFix] Bumble window not found");
            return;
        }

        CGRect hostBounds = hostWindow.bounds;

        CGFloat width =
            MIN(250.0, hostBounds.size.width - 20.0);

        BHFOverlayWindow =
            [[UIWindow alloc]
                initWithFrame:
                    CGRectMake(
                        10.0,
                        55.0,
                        width,
                        145.0
                    )];

        BHFOverlayWindow.windowLevel =
            UIWindowLevelAlert + 100.0;

        BHFOverlayWindow.backgroundColor =
            [UIColor colorWithWhite:0.0 alpha:0.82];

        BHFOverlayWindow.layer.cornerRadius = 12.0;
        BHFOverlayWindow.clipsToBounds = YES;

        UIViewController *controller =
            [[UIViewController alloc] init];

        BHFOverlayWindow.rootViewController =
            controller;

        BHFLabel =
            [[UILabel alloc]
                initWithFrame:
                    controller.view.bounds];

        BHFLabel.autoresizingMask =
            UIViewAutoresizingFlexibleWidth |
            UIViewAutoresizingFlexibleHeight;

        BHFLabel.textColor =
            [UIColor whiteColor];

        BHFLabel.backgroundColor =
            [UIColor clearColor];

        BHFLabel.font =
            [UIFont monospacedSystemFontOfSize:13.0
                                         weight:UIFontWeightMedium];

        BHFLabel.numberOfLines = 0;
        BHFLabel.textAlignment =
            NSTextAlignmentLeft;

        BHFLabel.text =
            @"BumbleHeatFix\n"
             "MONITOR\n"
             "Starting...";

        [controller.view addSubview:BHFLabel];

        BHFOverlayWindow.hidden = NO;

        NSLog(@"[BumbleHeatFix] Monitor overlay working");

        [NSTimer scheduledTimerWithTimeInterval:1.0
                                         repeats:YES
                                           block:^(NSTimer *timer) {
            BHFUpdateOverlay();
        }];

        BHFUpdateOverlay();
    });
}

%ctor
{
    @autoreleasepool {

        NSString *processName =
            [[NSProcessInfo processInfo] processName];

        NSLog(@"================================");
        NSLog(@"[BumbleHeatFix] DYLIB LOADED");
        NSLog(@"[BumbleHeatFix] Process: %@", processName);
        NSLog(@"[BumbleHeatFix] iOS: %@",
              [[UIDevice currentDevice] systemVersion]);
        NSLog(@"================================");

        if (![processName.lowercaseString containsString:@"bumble"]) {
            return;
        }

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                (int64_t)(2 * NSEC_PER_SEC)
            ),
            dispatch_get_main_queue(),
            ^{
                BHFCreateOverlay();
            }
        );
    }
}
