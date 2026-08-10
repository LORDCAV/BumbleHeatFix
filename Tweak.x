```objc
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <mach/mach_host.h>
#import <pthread.h>

static UILabel *BHFLabel = nil;
static NSTimer *BHFUpdateTimer = nil;
static uint64_t BHFPreviousCPUTime = 0;
static CFTimeInterval BHFPreviousTime = 0;

static void BHFUpdateOverlay(NSString *text);

static UIWindow *BHFGetWindow(void)
{
    UIWindow *result = nil;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) {
                continue;
            }

            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }

            UIWindowScene *windowScene = (UIWindowScene *)scene;

            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow) {
                    result = window;
                    break;
                }
            }

            if (result == nil && windowScene.windows.count > 0) {
                result = windowScene.windows.firstObject;
            }

            if (result != nil) {
                break;
            }
        }
    }

    return result;
}

static double BHFProcessCPUTime(void)
{
    task_thread_times_info_data_t taskInfo;
    mach_msg_type_number_t count = TASK_THREAD_TIMES_INFO_COUNT;

    kern_return_t kr = task_info(
        mach_task_self(),
        TASK_THREAD_TIMES_INFO,
        (task_info_t)&taskInfo,
        &count
    );

    if (kr != KERN_SUCCESS) {
        return 0.0;
    }

    uint64_t user =
        ((uint64_t)taskInfo.user_time.seconds * 1000000000ULL) +
        taskInfo.user_time.microseconds * 1000ULL;

    uint64_t system =
        ((uint64_t)taskInfo.system_time.seconds * 1000000000ULL) +
        taskInfo.system_time.microseconds * 1000ULL;

    return (double)(user + system) / 1000000000.0;
}

static NSUInteger BHFThreadCount(void)
{
    thread_act_array_t threadList = NULL;
    mach_msg_type_number_t threadCount = 0;

    kern_return_t kr = task_threads(
        mach_task_self(),
        &threadList,
        &threadCount
    );

    if (kr != KERN_SUCCESS) {
        return 0;
    }

    if (threadList != NULL) {
        vm_deallocate(
            mach_task_self(),
            (vm_address_t)threadList,
            threadCount * sizeof(thread_t)
        );
    }

    return (NSUInteger)threadCount;
}

static NSUInteger BHFMemoryMB(void)
{
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;

    kern_return_t kr = task_info(
        mach_task_self(),
        TASK_VM_INFO,
        (task_info_t)&vmInfo,
        &count
    );

    if (kr != KERN_SUCCESS) {
        return 0;
    }

    uint64_t physicalFootprint = vmInfo.phys_footprint;

    return (NSUInteger)(physicalFootprint / (1024ULL * 1024ULL));
}

static void BHFCreateOverlay(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (BHFLabel != nil) {
            return;
        }

        UIWindow *window = BHFGetWindow();

        if (window == nil) {
            return;
        }

        BHFLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 60, 300, 130)];

        BHFLabel.numberOfLines = 0;
        BHFLabel.textAlignment = NSTextAlignmentLeft;
        BHFLabel.font = [UIFont monospacedSystemFontOfSize:13.0 weight:UIFontWeightMedium];
        BHFLabel.textColor = [UIColor whiteColor];
        BHFLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.78];
        BHFLabel.layer.cornerRadius = 8.0;
        BHFLabel.layer.masksToBounds = YES;

        BHFLabel.text =
            @"BumbleHeatFix\n"
             "MONITOR TEST\n\n"
             "Dylib: LOADED\n"
             "Overlay: WORKING";

        [window addSubview:BHFLabel];
    });
}

static void BHFUpdateOverlay(NSString *text)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (BHFLabel == nil) {
            BHFCreateOverlay();
        }

        if (BHFLabel != nil) {
            BHFLabel.text = text;
        }
    });
}

static void BHFCollectStats(void)
{
    double currentCPUTime = BHFProcessCPUTime();
    CFTimeInterval currentTime = CACurrentMediaTime();

    double cpuDelta = 0.0;

    if (BHFPreviousTime > 0.0 && currentTime > BHFPreviousTime) {
        cpuDelta = currentCPUTime - BHFPreviousCPUTime;
    }

    BHFPreviousCPUTime = (uint64_t)(currentCPUTime * 1000000000.0);
    BHFPreviousTime = currentTime;

    NSUInteger threads = BHFThreadCount();
    NSUInteger memory = BHFMemoryMB();

    NSString *output = [NSString stringWithFormat:
        @"BumbleHeatFix\n"
         "CPU time: %.2fs\n"
         "CPU Δ/1s: %.2fs\n"
         "Threads: %lu\n"
         "Memory: %lu MB",
        currentCPUTime,
        cpuDelta,
        (unsigned long)threads,
        (unsigned long)memory
    ];

    BHFUpdateOverlay(output);
}

%ctor
{
    @autoreleasepool {
        NSLog(@"[BumbleHeatFix] Loaded successfully");

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
            dispatch_get_main_queue(),
            ^{
                BHFCreateOverlay();

                BHFUpdateTimer =
                    [NSTimer scheduledTimerWithTimeInterval:1.0
                                                     repeats:YES
                                                       block:^(NSTimer *timer) {
                    BHFCollectStats();
                }];
            }
        );
    }
}
```
