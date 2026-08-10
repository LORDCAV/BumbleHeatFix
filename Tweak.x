#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>

static UILabel *BHFLabel = nil;
static NSTimer *BHFUpdateTimer = nil;

static double BHFPreviousCPUTime = 0.0;
static CFTimeInterval BHFPreviousTime = 0.0;

static double BHFPeakCPUPercent = 0.0;
static NSUInteger BHFPeakThreads = 0;
static NSUInteger BHFPeakMemoryMB = 0;

static void BHFCreateOverlay(void);

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

    uint64_t userTime =
        ((uint64_t)taskInfo.user_time.seconds * 1000000000ULL) +
        ((uint64_t)taskInfo.user_time.microseconds * 1000ULL);

    uint64_t systemTime =
        ((uint64_t)taskInfo.system_time.seconds * 1000000000ULL) +
        ((uint64_t)taskInfo.system_time.microseconds * 1000ULL);

    return (double)(userTime + systemTime) / 1000000000.0;
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

    return (NSUInteger)(
        vmInfo.phys_footprint /
        (1024ULL * 1024ULL)
    );
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

        BHFLabel = [[UILabel alloc]
            initWithFrame:CGRectMake(10, 60, 315, 190)];

        BHFLabel.numberOfLines = 0;
        BHFLabel.textAlignment = NSTextAlignmentLeft;

        BHFLabel.font =
            [UIFont monospacedSystemFontOfSize:13.0
                                        weight:UIFontWeightMedium];

        BHFLabel.textColor = [UIColor whiteColor];

        BHFLabel.backgroundColor =
            [[UIColor blackColor] colorWithAlphaComponent:0.80];

        BHFLabel.layer.cornerRadius = 8.0;
        BHFLabel.layer.masksToBounds = YES;

        BHFLabel.text =
            @"BumbleHeatFix\n"
             "MONITOR v1.0.1\n\n"
             "CPU: measuring...\n"
             "Threads: measuring...\n"
             "Memory: measuring...";

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
    CFTimeInterval currentTime = CACurrentMediaTime();
    double currentCPUTime = BHFProcessCPUTime();

    double elapsed = 0.0;
    double cpuDelta = 0.0;
    double cpuPercent = 0.0;

    if (BHFPreviousTime > 0.0 &&
        currentTime > BHFPreviousTime &&
        currentCPUTime >= BHFPreviousCPUTime) {

        elapsed =
            currentTime -
            BHFPreviousTime;

        cpuDelta =
            currentCPUTime -
            BHFPreviousCPUTime;

        if (elapsed > 0.0) {
            cpuPercent =
                (cpuDelta / elapsed) * 100.0;
        }
    }

    BHFPreviousCPUTime = currentCPUTime;
    BHFPreviousTime = currentTime;

    NSUInteger threads = BHFThreadCount();
    NSUInteger memory = BHFMemoryMB();

    if (cpuPercent > BHFPeakCPUPercent) {
        BHFPeakCPUPercent = cpuPercent;
    }

    if (threads > BHFPeakThreads) {
        BHFPeakThreads = threads;
    }

    if (memory > BHFPeakMemoryMB) {
        BHFPeakMemoryMB = memory;
    }

    NSString *output =
        [NSString stringWithFormat:
            @"BumbleHeatFix\n"
             "MONITOR v1.0.1\n\n"
             "CPU: %.1f%%\n"
             "Peak CPU: %.1f%%\n"
             "Threads: %lu (peak %lu)\n"
             "Memory: %lu MB (peak %lu MB)",
             cpuPercent,
             BHFPeakCPUPercent,
             (unsigned long)threads,
             (unsigned long)BHFPeakThreads,
             (unsigned long)memory,
             (unsigned long)BHFPeakMemoryMB
        ];

    BHFUpdateOverlay(output);
}

%ctor
{
    @autoreleasepool {

        NSLog(@"[BumbleHeatFix] Monitor v1.0.1 loaded");

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                2 * NSEC_PER_SEC
            ),
            dispatch_get_main_queue(),
            ^{

                BHFCreateOverlay();

                BHFUpdateTimer =
                    [NSTimer
                        scheduledTimerWithTimeInterval:1.0
                        repeats:YES
                        block:^(NSTimer *timer) {

                    BHFCollectStats();
                }];
            }
        );
    }
}
