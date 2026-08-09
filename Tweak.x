#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/mach_time.h>

static UIView *BHFPanel = nil;
static UILabel *BHFCPU = nil;
static UILabel *BHFThreads = nil;
static UILabel *BHFMemory = nil;
static UILabel *BHFRuntime = nil;

static uint64_t BHFPreviousCPUTime = 0;
static uint64_t BHFPreviousTime = 0;

static UIWindow *BHFGetActiveWindow(void)
{
    UIApplication *application = [UIApplication sharedApplication];

    for (UIScene *scene in application.connectedScenes) {

        if (scene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }

        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }

        UIWindowScene *windowScene = (UIWindowScene *)scene;

        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }

        for (UIWindow *window in windowScene.windows) {
            if (!window.hidden &&
                window.alpha > 0.0 &&
                window.windowLevel == UIWindowLevelNormal) {
                return window;
            }
        }
    }

    return nil;
}

static double BHFGetCPUUsage(void)
{
    task_thread_times_info_data_t taskInfo;
    mach_msg_type_number_t taskInfoCount = TASK_THREAD_TIMES_INFO_COUNT;

    kern_return_t result = task_info(
        mach_task_self(),
        TASK_THREAD_TIMES_INFO,
        (task_info_t)&taskInfo,
        &taskInfoCount
    );

    if (result != KERN_SUCCESS) {
        return -1.0;
    }

    uint64_t userTime =
        ((uint64_t)taskInfo.user_time.seconds * NSEC_PER_SEC) +
        taskInfo.user_time.microseconds * 1000ULL;

    uint64_t systemTime =
        ((uint64_t)taskInfo.system_time.seconds * NSEC_PER_SEC) +
        taskInfo.system_time.microseconds * 1000ULL;

    uint64_t currentCPUTime = userTime + systemTime;

    uint64_t currentTime = mach_absolute_time();

    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);

    uint64_t currentTimeNano =
        currentTime * timebase.numer / timebase.denom;

    if (BHFPreviousCPUTime == 0 || BHFPreviousTime == 0) {
        BHFPreviousCPUTime = currentCPUTime;
        BHFPreviousTime = currentTimeNano;
        return 0.0;
    }

    uint64_t cpuDelta = currentCPUTime - BHFPreviousCPUTime;
    uint64_t timeDelta = currentTimeNano - BHFPreviousTime;

    BHFPreviousCPUTime = currentCPUTime;
    BHFPreviousTime = currentTimeNano;

    if (timeDelta == 0) {
        return 0.0;
    }

    double cpuUsage = ((double)cpuDelta / (double)timeDelta) * 100.0;

    return cpuUsage;
}

static NSUInteger BHFGetThreadCount(void)
{
    thread_act_array_t threadList = NULL;
    mach_msg_type_number_t threadCount = 0;

    kern_return_t result = task_threads(
        mach_task_self(),
        &threadList,
        &threadCount
    );

    if (result != KERN_SUCCESS) {
        return 0;
    }

    for (mach_msg_type_number_t i = 0; i < threadCount; i++) {
        mach_port_deallocate(
            mach_task_self(),
            threadList[i]
        );
    }

    vm_deallocate(
        mach_task_self(),
        (vm_address_t)threadList,
        threadCount * sizeof(thread_t)
    );

    return (NSUInteger)threadCount;
}

static NSUInteger BHFGetMemoryMB(void)
{
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;

    kern_return_t result = task_info(
        mach_task_self(),
        TASK_VM_INFO,
        (task_info_t)&vmInfo,
        &count
    );

    if (result != KERN_SUCCESS) {
        return 0;
    }

    uint64_t memory = vmInfo.phys_footprint;

    return (NSUInteger)(memory / (1024ULL * 1024ULL));
}

static void BHFUpdateMetrics(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{

        if (!BHFPanel) {
            return;
        }

        double cpu = BHFGetCPUUsage();

        NSUInteger threads = BHFGetThreadCount();
        NSUInteger memory = BHFGetMemoryMB();

        static NSDate *startDate = nil;

        if (!startDate) {
            startDate = [NSDate date];
        }

        NSTimeInterval runtime =
            [[NSDate date] timeIntervalSinceDate:startDate];

        NSInteger seconds = (NSInteger)runtime;

        NSInteger hours = seconds / 3600;
        seconds %= 3600;

        NSInteger minutes = seconds / 60;
        seconds %= 60;

        if (cpu < 0.0) {
            BHFCPU.text = @"CPU: unavailable";
        } else {
            BHFCPU.text =
                [NSString stringWithFormat:@"CPU: %.1f%%", cpu];
        }

        BHFThreads.text =
            [NSString stringWithFormat:@"Threads: %lu",
             (unsigned long)threads];

        BHFMemory.text =
            [NSString stringWithFormat:@"Memory: %lu MB",
             (unsigned long)memory];

        BHFRuntime.text =
            [NSString stringWithFormat:@"Runtime: %02ld:%02ld:%02ld",
             (long)hours,
             (long)minutes,
             (long)seconds];
    });
}

static void BHFCreateOverlay(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{

        UIWindow *targetWindow = BHFGetActiveWindow();

        if (!targetWindow) {
            NSLog(@"[BumbleHeatFix] Could not find active window");
            return;
        }

        UIView *existing =
            [targetWindow viewWithTag:987654];

        if (existing) {
            BHFPanel = existing;
            return;
        }

        BHFPanel =
            [[UIView alloc] initWithFrame:
             CGRectMake(12.0, 70.0, 210.0, 130.0)];

        BHFPanel.tag = 987654;

        BHFPanel.backgroundColor =
            [[UIColor blackColor] colorWithAlphaComponent:0.82];

        BHFPanel.layer.cornerRadius = 12.0;
        BHFPanel.layer.masksToBounds = YES;

        UILabel *title =
            [[UILabel alloc] initWithFrame:
             CGRectMake(10.0, 7.0, 190.0, 22.0)];

        title.text = @"BumbleHeatFix";
        title.textColor = UIColor.whiteColor;
        title.font =
            [UIFont boldSystemFontOfSize:15.0];

        BHFCPU =
            [[UILabel alloc] initWithFrame:
             CGRectMake(10.0, 31.0, 190.0, 20.0)];

        BHFThreads =
            [[UILabel alloc] initWithFrame:
             CGRectMake(10.0, 51.0, 190.0, 20.0)];

        BHFMemory =
            [[UILabel alloc] initWithFrame:
             CGRectMake(10.0, 71.0, 190.0, 20.0)];

        BHFRuntime =
            [[UILabel alloc] initWithFrame:
             CGRectMake(10.0, 91.0, 190.0, 20.0)];

        NSArray *labels = @[
            BHFCPU,
            BHFThreads,
            BHFMemory,
            BHFRuntime
        ];

        for (UILabel *label in labels) {
            label.textColor = UIColor.whiteColor;
            label.font =
                [UIFont monospacedSystemFontOfSize:12.0
                                            weight:UIFontWeightRegular];
            label.text = @"Loading...";
            [BHFPanel addSubview:label];
        }

        [BHFPanel addSubview:title];

        [targetWindow addSubview:BHFPanel];

        NSLog(@"[BumbleHeatFix] Monitoring overlay created");

        [NSTimer scheduledTimerWithTimeInterval:1.0
                                         repeats:YES
                                           block:^(NSTimer *timer) {
            BHFUpdateMetrics();
        }];

        BHFUpdateMetrics();
    });
}

%ctor
{
    @autoreleasepool {

        NSLog(@"[BumbleHeatFix] ===============================");
        NSLog(@"[BumbleHeatFix] Monitoring dylib loaded");
        NSLog(@"[BumbleHeatFix] ===============================");

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                3 * NSEC_PER_SEC
            ),
            dispatch_get_main_queue(),
            ^{
                BHFCreateOverlay();
            }
        );
    }
}
