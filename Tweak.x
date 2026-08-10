```objc
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <pthread.h>

static UIWindow *BHFWindow = nil;
static UILabel *BHFLabel = nil;

static uint64_t BHFLastTime = 0;

static uint64_t BHFNow(void)
{
    return mach_absolute_time();
}

static double BHFSeconds(uint64_t value)
{
    static mach_timebase_info_data_t timebase = {0, 0};

    if (timebase.denom == 0) {
        mach_timebase_info(&timebase);
    }

    return ((double)value * (double)timebase.numer /
            (double)timebase.denom) / 1000000000.0;
}

static UIWindow *BHFGetWindow(void)
{
    UIApplication *app = [UIApplication sharedApplication];

    for (UIScene *scene in app.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }

        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }

        UIWindowScene *windowScene = (UIWindowScene *)scene;

        for (UIWindow *window in windowScene.windows) {
            if (window.hidden) {
                continue;
            }

            if (window.alpha <= 0.0) {
                continue;
            }

            if (window.windowLevel != UIWindowLevelNormal) {
                continue;
            }

            return window;
        }
    }

    return nil;
}

static void BHFCreateOverlay(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (BHFWindow != nil) {
            return;
        }

        UIWindow *targetWindow = BHFGetWindow();

        if (targetWindow == nil) {
            return;
        }

        BHFWindow = [[UIWindow alloc] initWithFrame:CGRectMake(8, 50, 260, 150)];

        BHFWindow.windowLevel = UIWindowLevelAlert + 100;
        BHFWindow.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.82];
        BHFWindow.userInteractionEnabled = NO;
        BHFWindow.hidden = NO;

        BHFLabel = [[UILabel alloc] initWithFrame:BHFWindow.bounds];

        BHFLabel.numberOfLines = 0;
        BHFLabel.textColor = [UIColor whiteColor];
        BHFLabel.font = [UIFont monospacedSystemFontOfSize:11.0
                                                     weight:UIFontWeightRegular];
        BHFLabel.textAlignment = NSTextAlignmentLeft;
        BHFLabel.text = @"BumbleHeatFix\nTHREAD MONITOR\nStarting...";

        [BHFWindow addSubview:BHFLabel];
    });
}

static void BHFUpdateOverlay(NSString *text)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (BHFLabel != nil) {
            BHFLabel.text = text;
        }
    });
}

static NSString *BHFThreadName(thread_t thread)
{
    char name[64] = {0};

    pthread_t pthreadID = pthread_from_mach_thread_np(thread);

    if (pthreadID != NULL) {
        int result = pthread_getname_np(pthreadID, name, sizeof(name));

        if (result == 0 && name[0] != '\0') {
            return [NSString stringWithUTF8String:name];
        }
    }

    return @"<unnamed>";
}

static void BHFReadThreads(void)
{
    mach_port_t task = mach_task_self();

    thread_act_array_t threads = NULL;
    mach_msg_type_number_t threadCount = 0;

    kern_return_t kr = task_threads(task, &threads, &threadCount);

    if (kr != KERN_SUCCESS || threads == NULL || threadCount == 0) {
        BHFUpdateOverlay(@"BumbleHeatFix\nTHREAD MONITOR\nUnable to read threads");
        return;
    }

    double totalCPU = 0.0;

    thread_t topThreads[3] = {MACH_PORT_NULL, MACH_PORT_NULL, MACH_PORT_NULL};
    double topCPU[3] = {0.0, 0.0, 0.0};

    for (mach_msg_type_number_t i = 0; i < threadCount; i++) {

        thread_basic_info_data_t info;
        mach_msg_type_number_t infoCount = THREAD_BASIC_INFO_COUNT;

        kern_return_t infoResult =
            thread_info(
                threads[i],
                THREAD_BASIC_INFO,
                (thread_info_t)&info,
                &infoCount
            );

        if (infoResult != KERN_SUCCESS) {
            continue;
        }

        if (info.flags & TH_FLAGS_IDLE) {
            continue;
        }

        double cpu =
            (double)info.user_time.seconds +
            (double)info.user_time.microseconds / 1000000.0 +
            (double)info.system_time.seconds +
            (double)info.system_time.microseconds / 1000000.0;

        /*
         * cpu above is lifetime CPU time.
         *
         * For this diagnostic pass, we compare the current thread
         * CPU time against the previous sampling point.
         */

        totalCPU += cpu;

        if (cpu > topCPU[0]) {
            topCPU[2] = topCPU[1];
            topThreads[2] = topThreads[1];

            topCPU[1] = topCPU[0];
            topThreads[1] = topThreads[0];

            topCPU[0] = cpu;
            topThreads[0] = threads[i];
        }
        else if (cpu > topCPU[1]) {
            topCPU[2] = topCPU[1];
            topThreads[2] = topThreads[1];

            topCPU[1] = cpu;
            topThreads[1] = threads[i];
        }
        else if (cpu > topCPU[2]) {
            topCPU[2] = cpu;
            topThreads[2] = threads[i];
        }
    }

    uint64_t now = BHFNow();

    double interval = 0.0;

    if (BHFLastTime != 0) {
        interval = BHFSeconds(now - BHFLastTime);
    }

    BHFLastTime = now;

    /*
     * The values above are lifetime values. We therefore display
     * the top threads for identification while retaining the
     * overall process CPU measurement separately.
     */

    NSString *thread1 =
        topThreads[0] != MACH_PORT_NULL
        ? BHFThreadName(topThreads[0])
        : @"<none>";

    NSString *thread2 =
        topThreads[1] != MACH_PORT_NULL
        ? BHFThreadName(topThreads[1])
        : @"<none>";

    NSString *thread3 =
        topThreads[2] != MACH_PORT_NULL
        ? BHFThreadName(topThreads[2])
        : @"<none>";

    NSString *text =
        [NSString stringWithFormat:
            @"BumbleHeatFix\n"
             "THREAD MONITOR\n"
             "Threads: %u\n"
             "Sample: %.2fs\n\n"
             "#1 %.2fs  %@\n"
             "#2 %.2fs  %@\n"
             "#3 %.2fs  %@",
             threadCount,
             interval,
             topCPU[0],
             thread1,
             topCPU[1],
             thread2,
             topCPU[2],
             thread3];

    BHFUpdateOverlay(text);

    vm_deallocate(
        mach_task_self(),
        (vm_address_t)threads,
        threadCount * sizeof(thread_t)
    );
}

%ctor
{
    @autoreleasepool {

        NSLog(@"[BumbleHeatFix] Thread monitor loaded");

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
            dispatch_get_main_queue(),
            ^{
                BHFCreateOverlay();
            }
        );

        dispatch_source_t timer =
            dispatch_source_create(
                DISPATCH_SOURCE_TYPE_TIMER,
                0,
                0,
                dispatch_get_main_queue()
            );

        if (timer != NULL) {

            dispatch_source_set_timer(
                timer,
                dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                1 * NSEC_PER_SEC,
                100 * NSEC_PER_MSEC
            );

            dispatch_source_set_event_handler(
                timer,
                ^{
                    BHFCreateOverlay();

                    BHFReadThreads();
                }
            );

            dispatch_resume(timer);
        }
    }
}
```
