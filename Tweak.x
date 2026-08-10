#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <mach/mach_host.h>
#import <mach/thread_info.h>
#import <mach/thread_act.h>
#import <pthread.h>

static UILabel *BHFOverlayLabel = nil;
static NSTimer *BHFMonitorTimer = nil;

static NSString *BHFFormatBytes(uint64_t bytes)
{
    double mb = (double)bytes / (1024.0 * 1024.0);
    return [NSString stringWithFormat:@"%.0f MB", mb];
}

static double BHFProcessCPUUsage(void)
{
    task_basic_info_data_t taskInfo;
    mach_msg_type_number_t count = TASK_BASIC_INFO_COUNT;

    kern_return_t kr = task_info(
        mach_task_self(),
        TASK_BASIC_INFO,
        (task_info_t)&taskInfo,
        &count
    );

    if (kr != KERN_SUCCESS)
        return 0.0;

    /*
     * task_basic_info does not provide a direct process CPU percentage.
     * We calculate CPU usage from the sum of thread CPU usage below.
     */

    thread_act_array_t threads = NULL;
    mach_msg_type_number_t threadCount = 0;

    kr = task_threads(
        mach_task_self(),
        &threads,
        &threadCount
    );

    if (kr != KERN_SUCCESS)
        return 0.0;

    double totalCPU = 0.0;

    for (mach_msg_type_number_t i = 0; i < threadCount; i++)
    {
        thread_basic_info_data_t threadInfo;
        mach_msg_type_number_t threadInfoCount =
            THREAD_BASIC_INFO_COUNT;

        kr = thread_info(
            threads[i],
            THREAD_BASIC_INFO,
            (thread_info_t)&threadInfo,
            &threadInfoCount
        );

        if (kr == KERN_SUCCESS)
        {
            if (!(threadInfo.flags & TH_FLAGS_IDLE))
            {
                totalCPU +=
                    ((double)threadInfo.cpu_usage /
                     (double)TH_USAGE_SCALE) * 100.0;
            }
        }
    }

    vm_deallocate(
        mach_task_self(),
        (vm_address_t)threads,
        threadCount * sizeof(thread_t)
    );

    return totalCPU;
}

static NSUInteger BHFThreadCount(void)
{
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t threadCount = 0;

    kern_return_t kr = task_threads(
        mach_task_self(),
        &threads,
        &threadCount
    );

    if (kr != KERN_SUCCESS)
        return 0;

    vm_deallocate(
        mach_task_self(),
        (vm_address_t)threads,
        threadCount * sizeof(thread_t)
    );

    return threadCount;
}

static uint64_t BHFMemoryUsage(void)
{
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;

    kern_return_t kr = task_info(
        mach_task_self(),
        TASK_VM_INFO,
        (task_info_t)&vmInfo,
        &count
    );

    if (kr != KERN_SUCCESS)
        return 0;

    return vmInfo.phys_footprint;
}

static NSString *BHFTopThreads(void)
{
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t threadCount = 0;

    kern_return_t kr = task_threads(
        mach_task_self(),
        &threads,
        &threadCount
    );

    if (kr != KERN_SUCCESS || threadCount == 0)
        return @"Unable to inspect threads";

    NSMutableArray *threadEntries = [NSMutableArray array];

    for (mach_msg_type_number_t i = 0; i < threadCount; i++)
    {
        thread_basic_info_data_t info;
        mach_msg_type_number_t infoCount =
            THREAD_BASIC_INFO_COUNT;

        kr = thread_info(
            threads[i],
            THREAD_BASIC_INFO,
            (thread_info_t)&info,
            &infoCount
        );

        if (kr != KERN_SUCCESS)
            continue;

        if (info.flags & TH_FLAGS_IDLE)
            continue;

        double cpu =
            ((double)info.cpu_usage /
             (double)TH_USAGE_SCALE) * 100.0;

        if (cpu < 1.0)
            continue;

        NSString *name = @"unnamed";

        char threadName[256] = {0};

        pthread_t pthread =
            pthread_from_mach_thread_np(threads[i]);

        if (pthread != NULL)
        {
            int result =
                pthread_getname_np(
                    pthread,
                    threadName,
                    sizeof(threadName)
                );

            if (result == 0 && threadName[0] != '\0')
            {
                name =
                    [NSString stringWithUTF8String:threadName];
            }
        }

        NSString *entry =
            [NSString stringWithFormat:
                @"%.1f%%  %@",
                cpu,
                name];

        [threadEntries addObject:
            @{
                @"cpu": @(cpu),
                @"text": entry
            }];
    }

    [threadEntries sortUsingComparator:
        ^NSComparisonResult(NSDictionary *a,
                            NSDictionary *b)
        {
            double cpuA =
                [a[@"cpu"] doubleValue];

            double cpuB =
                [b[@"cpu"] doubleValue];

            if (cpuA > cpuB)
                return NSOrderedAscending;

            if (cpuA < cpuB)
                return NSOrderedDescending;

            return NSOrderedSame;
        }
    ];

    NSMutableString *result =
        [NSMutableString string];

    NSUInteger maximum =
        MIN((NSUInteger)6, threadEntries.count);

    for (NSUInteger i = 0; i < maximum; i++)
    {
        [result appendFormat:
            @"%@\n",
            threadEntries[i][@"text"]];
    }

    if (result.length == 0)
        return @"No significant CPU threads";

    return [result copy];
}

static UIWindow *BHFFindWindow(void)
{
    if (@available(iOS 13.0, *))
    {
        for (UIScene *scene
             in [UIApplication sharedApplication].connectedScenes)
        {
            if (scene.activationState !=
                UISceneActivationStateForegroundActive)
            {
                continue;
            }

            if (![scene isKindOfClass:
                    [UIWindowScene class]])
            {
                continue;
            }

            UIWindowScene *windowScene =
                (UIWindowScene *)scene;

            for (UIWindow *window
                 in windowScene.windows)
            {
                if (window.isKeyWindow)
                    return window;
            }

            if (windowScene.windows.count > 0)
                return windowScene.windows.firstObject;
        }
    }
    else
    {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

        UIWindow *window =
            [UIApplication sharedApplication].keyWindow;

#pragma clang diagnostic pop

        if (window)
            return window;
    }

    return nil;
}

static void BHFCreateOverlay(void)
{
    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (BHFOverlayLabel != nil)
                return;

            UIWindow *window = BHFFindWindow();

            if (!window)
            {
                NSLog(@"[BumbleHeatFix] No foreground window found");
                return;
            }

            BHFOverlayLabel =
                [[UILabel alloc]
                    initWithFrame:
                        CGRectMake(10, 55, 370, 280)];

            BHFOverlayLabel.numberOfLines = 0;

            BHFOverlayLabel.font =
                [UIFont monospacedSystemFontOfSize:11.0
                                            weight:UIFontWeightRegular];

            BHFOverlayLabel.textColor =
                [UIColor whiteColor];

            BHFOverlayLabel.backgroundColor =
                [[UIColor blackColor]
                    colorWithAlphaComponent:0.78];

            BHFOverlayLabel.layer.cornerRadius = 8.0;
            BHFOverlayLabel.layer.masksToBounds = YES;

            BHFOverlayLabel.text =
                @"BumbleHeatFix\nStarting diagnostics...";

            [window addSubview:BHFOverlayLabel];

            NSLog(
                @"[BumbleHeatFix] Diagnostic overlay created"
            );
        }
    );
}

static void BHFUpdateOverlay(void)
{
    double cpu = BHFProcessCPUUsage();

    NSUInteger threads =
        BHFThreadCount();

    uint64_t memory =
        BHFMemoryUsage();

    NSString *topThreads =
        BHFTopThreads();

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (!BHFOverlayLabel)
                return;

            NSString *text =
                [NSString stringWithFormat:
                    @"BumbleHeatFix\n"
                     "────────────────────\n"
                     "CPU:      %.1f%%\n"
                     "Memory:   %@\n"
                     "Threads:  %lu\n"
                     "\n"
                     "Top CPU Threads\n"
                     "────────────────────\n"
                     "%@",
                     cpu,
                     BHFFormatBytes(memory),
                     (unsigned long)threads,
                     topThreads];

            BHFOverlayLabel.text = text;
        }
    );

    NSLog(
        @"[BumbleHeatFix] CPU %.1f%% | Memory %@ | Threads %lu",
        cpu,
        BHFFormatBytes(memory),
        (unsigned long)threads
    );
}

static void BHFStartMonitoring(void)
{
    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            BHFCreateOverlay();

            if (BHFMonitorTimer)
                return;

            BHFMonitorTimer =
                [NSTimer scheduledTimerWithTimeInterval:1.0
                                                 repeats:YES
                                                   block:
                ^(NSTimer *timer)
                {
                    BHFUpdateOverlay();
                }];

            NSLog(
                @"[BumbleHeatFix] Diagnostic monitoring started"
            );
        }
    );
}

%ctor
{
    @autoreleasepool
    {
        NSLog(
            @"================================"
        );

        NSLog(
            @"[BumbleHeatFix] Loaded"
        );

        NSLog(
            @"[BumbleHeatFix] Process: %@",
            [[NSProcessInfo processInfo] processName]
        );

        NSLog(
            @"[BumbleHeatFix] iOS: %@",
            [[UIDevice currentDevice] systemVersion]
        );

        NSLog(
            @"[BumbleHeatFix] Device: %@",
            [[UIDevice currentDevice] model]
        );

        NSLog(
            @"================================"
        );

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                3 * NSEC_PER_SEC
            ),
            dispatch_get_main_queue(),
            ^{
                BHFStartMonitoring();
            }
        );
    }
}
