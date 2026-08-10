#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>

static void BHFLog(NSString *format, ...)
{
    va_list args;
    va_start(args, format);

    NSString *message =
        [[NSString alloc] initWithFormat:format arguments:args];

    va_end(args);

    NSLog(@"[BumbleHeatFix] %@", message);
}

static UIWindow *BHFGetWindow(void)
{
    UIApplication *app = [UIApplication sharedApplication];

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {

            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }

            UIWindowScene *windowScene = (UIWindowScene *)scene;

            if (windowScene.activationState != UISceneActivationStateForegroundActive) {
                continue;
            }

            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow) {
                    return window;
                }
            }

            if (windowScene.windows.count > 0) {
                return windowScene.windows.firstObject;
            }
        }
    }

    return nil;
}

static BOOL BHFGetProcessStats(double *cpuUsage,
                               NSUInteger *threadCount,
                               double *memoryMB)
{
    task_t task = mach_task_self();

    task_thread_times_info_data_t taskTime;
    mach_msg_type_number_t taskTimeCount =
        TASK_THREAD_TIMES_INFO_COUNT;

    kern_return_t kr =
        task_info(
            task,
            TASK_THREAD_TIMES_INFO,
            (task_info_t)&taskTime,
            &taskTimeCount
        );

    if (kr != KERN_SUCCESS) {
        return NO;
    }

    thread_act_array_t threads = NULL;
    mach_msg_type_number_t threadCountRaw = 0;

    kr = task_threads(
        task,
        &threads,
        &threadCountRaw
    );

    if (kr != KERN_SUCCESS) {
        return NO;
    }

    if (threadCount) {
        *threadCount = threadCountRaw;
    }

    uint64_t totalCPU =
        (uint64_t)taskTime.user_time.seconds * 1000000ULL +
        (uint64_t)taskTime.user_time.microseconds +
        (uint64_t)taskTime.system_time.seconds * 1000000ULL +
        (uint64_t)taskTime.system_time.microseconds;

    /*
     * This is intentionally a simple instantaneous estimate.
     * We will replace it with interval-based CPU measurement
     * once the basic monitor is confirmed working.
     */

    if (cpuUsage) {
        *cpuUsage = (double)totalCPU / 1000000.0;
    }

    if (memoryMB) {
        mach_task_basic_info_data_t info;
        mach_msg_type_number_t count =
            MACH_TASK_BASIC_INFO_COUNT;

        kr = task_info(
            task,
            MACH_TASK_BASIC_INFO,
            (task_info_t)&info,
            &count
        );

        if (kr == KERN_SUCCESS) {
            *memoryMB =
                (double)info.resident_size / (1024.0 * 1024.0);
        } else {
            *memoryMB = 0.0;
        }
    }

    /*
     * task_threads() allocates this array.
     * We only need the count here.
     */
    if (threads) {
        vm_deallocate(
            mach_task_self(),
            (vm_address_t)threads,
            threadCountRaw * sizeof(thread_act_t)
        );
    }

    return YES;
}

static void BHFUpdateOverlay(UILabel *label)
{
    double cpu = 0.0;
    double memory = 0.0;
    NSUInteger threads = 0;

    BOOL success =
        BHFGetProcessStats(
            &cpu,
            &threads,
            &memory
        );

    if (!success) {
        label.text =
            @"BumbleHeatFix\n"
             "CPU: unavailable\n"
             "Threads: unavailable\n"
             "Memory: unavailable";
        return;
    }

    label.text =
        [NSString stringWithFormat:
            @"BumbleHeatFix\n"
             "CPU: %.1f%%\n"
             "Threads: %lu\n"
             "Memory: %.1f MB",
             cpu,
             (unsigned long)threads,
             memory];

    BHFLog(
        @"CPU %.1f%% | Threads %lu | Memory %.1f MB",
        cpu,
        (unsigned long)threads,
        memory
    );
}

static void BHFShowMonitor(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{

        UIWindow *window = BHFGetWindow();

        if (!window) {
            BHFLog(@"ERROR: Could not find Bumble window");
            return;
        }

        UIView *oldView =
            [window viewWithTag:987654];

        [oldView removeFromSuperview];

        UIView *panel =
            [[UIView alloc]
                initWithFrame:CGRectMake(15, 55, 270, 140)];

        panel.tag = 987654;
        panel.backgroundColor =
            [[UIColor blackColor]
                colorWithAlphaComponent:0.85];

        panel.layer.cornerRadius = 12.0;
        panel.layer.masksToBounds = YES;

        UILabel *label =
            [[UILabel alloc]
                initWithFrame:CGRectMake(12, 10, 246, 120)];

        label.numberOfLines = 0;
        label.textColor = UIColor.whiteColor;

        label.font =
            [UIFont systemFontOfSize:14.0
                              weight:UIFontWeightMedium];

        label.text =
            @"BumbleHeatFix\n"
             "CPU: measuring...\n"
             "Threads: measuring...\n"
             "Memory: measuring...";

        [panel addSubview:label];
        [window addSubview:panel];

        BHFLog(@"Monitor overlay created");

        /*
         * Update once immediately.
         */
        BHFUpdateOverlay(label);

        /*
         * Update every second.
         */
        dispatch_source_t timer =
            dispatch_source_create(
                DISPATCH_SOURCE_TYPE_TIMER,
                0,
                0,
                dispatch_get_main_queue()
            );

        dispatch_source_set_timer(
            timer,
            dispatch_time(
                DISPATCH_TIME_NOW,
                1 * NSEC_PER_SEC
            ),
            1 * NSEC_PER_SEC,
            100 * NSEC_PER_MSEC
        );

        dispatch_source_set_event_handler(
            timer,
            ^{
                if (!label.superview) {
                    dispatch_source_cancel(timer);
                    return;
                }

                BHFUpdateOverlay(label);
            }
        );

        dispatch_resume(timer);
    });
}

%ctor
{
    @autoreleasepool {

        BHFLog(@"================================");
        BHFLog(@"BumbleHeatFix monitor loaded");
        BHFLog(
            @"Process: %@",
            [[NSProcessInfo processInfo] processName]
        );
        BHFLog(
            @"iOS: %@",
            [[UIDevice currentDevice] systemVersion]
        );
        BHFLog(@"================================");

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                2 * NSEC_PER_SEC
            ),
            dispatch_get_main_queue(),
            ^{
                BHFShowMonitor();
            }
        );
    }
}
