```objc
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <mach/task_info.h>
#import <mach/thread_act.h>

static UILabel *BHFLabel = nil;
static NSTimer *BHFTimer = nil;

static void BHFLog(NSString *format, ...)
{
    va_list args;
    va_start(args, format);

    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];

    va_end(args);

    NSLog(@"[BumbleHeatFix] %@", message);
}

static double BHFCPU(void)
{
    task_thread_times_info_data_t info;
    mach_msg_type_number_t count = TASK_THREAD_TIMES_INFO_COUNT;

    kern_return_t result = task_info(
        mach_task_self(),
        TASK_THREAD_TIMES_INFO,
        (task_info_t)&info,
        &count
    );

    if (result != KERN_SUCCESS)
        return -1.0;

    uint64_t cpuTime =
        ((uint64_t)info.user_time.seconds * 1000000000ULL) +
        ((uint64_t)info.user_time.microseconds * 1000ULL) +
        ((uint64_t)info.system_time.seconds * 1000000000ULL) +
        ((uint64_t)info.system_time.microseconds * 1000ULL);

    static uint64_t oldCPU = 0;
    static CFAbsoluteTime oldTime = 0;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    if (oldCPU == 0)
    {
        oldCPU = cpuTime;
        oldTime = now;
        return 0.0;
    }

    uint64_t cpuDifference = cpuTime - oldCPU;
    CFAbsoluteTime timeDifference = now - oldTime;

    oldCPU = cpuTime;
    oldTime = now;

    if (timeDifference <= 0.0)
        return 0.0;

    return ((double)cpuDifference / 1000000000.0) /
           timeDifference * 100.0;
}

static NSUInteger BHFThreads(void)
{
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;

    kern_return_t result = task_threads(
        mach_task_self(),
        &threads,
        &count
    );

    if (result != KERN_SUCCESS)
        return 0;

    NSUInteger number = (NSUInteger)count;

    vm_deallocate(
        mach_task_self(),
        (vm_address_t)threads,
        count * sizeof(thread_act_t)
    );

    return number;
}

static double BHFMemory(void)
{
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;

    kern_return_t result = task_info(
        mach_task_self(),
        TASK_VM_INFO,
        (task_info_t)&info,
        &count
    );

    if (result != KERN_SUCCESS)
        return -1.0;

    return (double)info.phys_footprint /
           (1024.0 * 1024.0);
}

static UIWindow *BHFWindow(void)
{
    UIApplication *application =
        [UIApplication sharedApplication];

    if (@available(iOS 13.0, *))
    {
        for (UIScene *scene in application.connectedScenes)
        {
            if (scene.activationState !=
                UISceneActivationStateForegroundActive)
            {
                continue;
            }

            if (![scene isKindOfClass:[UIWindowScene class]])
                continue;

            UIWindowScene *windowScene =
                (UIWindowScene *)scene;

            for (UIWindow *window in windowScene.windows)
            {
                if (window.isKeyWindow)
                    return window;
            }

            if (windowScene.windows.count > 0)
                return windowScene.windows.firstObject;
        }
    }

    return nil;
}

static void BHFUpdate(void)
{
    if (BHFLabel == nil)
        return;

    double cpu = BHFCPU();
    NSUInteger threads = BHFThreads();
    double memory = BHFMemory();

    BHFLabel.text = [NSString stringWithFormat:
        @"BumbleHeatFix\n"
         "CPU MONITOR\n\n"
         "Dylib: LOADED\n"
         "CPU: %.1f%%\n"
         "Threads: %lu\n"
         "Memory: %.0f MB",
         cpu,
         (unsigned long)threads,
         memory
    ];

    BHFLog(
        @"CPU %.1f%% | Threads %lu | Memory %.0f MB",
        cpu,
        (unsigned long)threads,
        memory
    );
}

static void BHFCreateOverlay(void)
{
    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (BHFLabel != nil)
                return;

            UIWindow *window = BHFWindow();

            if (window == nil)
            {
                BHFLog(@"Window not found");

                dispatch_after(
                    dispatch_time(
                        DISPATCH_TIME_NOW,
                        2 * NSEC_PER_SEC
                    ),
                    dispatch_get_main_queue(),
                    ^{
                        BHFCreateOverlay();
                    }
                );

                return;
            }

            BHFLabel = [[UILabel alloc]
                initWithFrame:CGRectMake(
                    15,
                    80,
                    280,
                    170
                )
            ];

            BHFLabel.numberOfLines = 0;

            BHFLabel.textColor =
                [UIColor whiteColor];

            BHFLabel.backgroundColor =
                [[UIColor blackColor]
                    colorWithAlphaComponent:0.80];

            BHFLabel.font =
                [UIFont monospacedSystemFontOfSize:13.0
                                            weight:UIFontWeightRegular];

            BHFLabel.layer.cornerRadius = 10.0;
            BHFLabel.layer.masksToBounds = YES;

            BHFLabel.textAlignment =
                NSTextAlignmentLeft;

            BHFLabel.userInteractionEnabled = NO;

            BHFLabel.text =
                @"BumbleHeatFix\n"
                 "CPU MONITOR\n\n"
                 "Dylib: LOADED\n"
                 "Starting...";

            [window addSubview:BHFLabel];

            BHFLog(@"Overlay created");

            BHFUpdate();

            BHFTimer =
                [NSTimer scheduledTimerWithTimeInterval:1.0
                                                 repeats:YES
                                                   block:
                ^(NSTimer *timer)
                {
                    BHFUpdate();
                }];
        }
    );
}

%ctor
{
    @autoreleasepool
    {
        BHFLog(@"================================");
        BHFLog(@"BumbleHeatFix CPU monitor loaded");
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
                BHFCreateOverlay();
            }
        );
    }
}
```
