#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <mach/thread_info.h>
#import <mach/task_info.h>
#import <pthread.h>
#import <unistd.h>
#import <stdarg.h>

#pragma mark - Configuration

#define BHF_SAMPLE_INTERVAL 1.0

#pragma mark - Logging

static void BHFLog(NSString *format, ...)
{
    va_list args;
    va_start(args, format);

    NSString *message =
        [[NSString alloc] initWithFormat:format arguments:args];

    va_end(args);

    NSLog(@"[BumbleHeatFix] %@", message);
}

#pragma mark - CPU

static double BHFThreadCPUUsage(thread_act_t thread)
{
    thread_basic_info_data_t info;
    mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;

    kern_return_t kr =
        thread_info(
            thread,
            THREAD_BASIC_INFO,
            (thread_info_t)&info,
            &count
        );

    if (kr != KERN_SUCCESS)
        return -1.0;

    if (info.flags & TH_FLAGS_IDLE)
        return 0.0;

    /*
     * 100% approximately represents one fully
     * utilized CPU core.
     */
    return ((double)info.cpu_usage * 100.0)
        / (double)TH_USAGE_SCALE;
}

#pragma mark - Thread Name

static NSString *BHFThreadName(thread_act_t thread)
{
    /*
     * A Mach thread port cannot safely be converted
     * into a pthread_t for pthread_getname_np().
     *
     * Therefore, unnamed Mach threads are reported
     * as <unnamed>.
     */
    (void)thread;

    return @"<unnamed>";
}

#pragma mark - Thread Collection

static void BHFCollectThreads(void)
{
    mach_port_t task = mach_task_self();

    thread_act_array_t threadList = NULL;
    mach_msg_type_number_t threadCount = 0;

    kern_return_t kr =
        task_threads(
            task,
            &threadList,
            &threadCount
        );

    if (kr != KERN_SUCCESS)
    {
        BHFLog(
            @"task_threads failed: %d",
            kr
        );

        return;
    }

    NSMutableArray *samples =
        [NSMutableArray arrayWithCapacity:threadCount];

    for (mach_msg_type_number_t i = 0;
         i < threadCount;
         i++)
    {
        thread_act_t thread = threadList[i];

        thread_identifier_info_data_t identifierInfo;
        mach_msg_type_number_t identifierCount =
            THREAD_IDENTIFIER_INFO_COUNT;

        kern_return_t identifierKR =
            thread_info(
                thread,
                THREAD_IDENTIFIER_INFO,
                (thread_info_t)&identifierInfo,
                &identifierCount
            );

        uint64_t threadID;

        if (identifierKR == KERN_SUCCESS)
        {
            threadID = identifierInfo.thread_id;
        }
        else
        {
            threadID = (uint64_t)thread;
        }

        double cpu =
            BHFThreadCPUUsage(thread);

        if (cpu < 0.0)
            continue;

        NSString *name =
            BHFThreadName(thread);

        NSDictionary *sample = @{
            @"tid": @(threadID),
            @"cpu": @(cpu),
            @"name": name
        };

        [samples addObject:sample];
    }

    /*
     * Sort from highest CPU to lowest CPU.
     */
    [samples sortUsingComparator:^NSComparisonResult(
        NSDictionary *a,
        NSDictionary *b
    ) {
        double cpuA =
            [a[@"cpu"] doubleValue];

        double cpuB =
            [b[@"cpu"] doubleValue];

        if (cpuA > cpuB)
            return NSOrderedAscending;

        if (cpuA < cpuB)
            return NSOrderedDescending;

        return NSOrderedSame;
    }];

    BHFLog(@"----------------------------------------");

    BHFLog(
        @"THREAD SAMPLE — %lu threads",
        (unsigned long)samples.count
    );

    /*
     * Print the top 8 threads.
     */
    NSUInteger displayCount =
        MIN((NSUInteger)8, samples.count);

    for (NSUInteger i = 0;
         i < displayCount;
         i++)
    {
        NSDictionary *sample =
            samples[i];

        BHFLog(
            @"#%lu  TID=%@  CPU=%.1f%%  %@",
            (unsigned long)(i + 1),
            sample[@"tid"],
            [sample[@"cpu"] doubleValue],
            sample[@"name"]
        );
    }

    /*
     * Highlight the hottest thread.
     */
    if (samples.count > 0)
    {
        NSDictionary *top =
            samples[0];

        double topCPU =
            [top[@"cpu"] doubleValue];

        if (topCPU >= 80.0)
        {
            BHFLog(
                @"HIGH CPU THREAD: TID=%@ CPU=%.1f%%",
                top[@"tid"],
                topCPU
            );
        }

        if (topCPU >= 95.0)
        {
            BHFLog(
                @"POSSIBLE FULL-CORE THREAD: TID=%@ CPU=%.1f%%",
                top[@"tid"],
                topCPU
            );
        }
    }

    /*
     * Release the array allocated by task_threads().
     */
    if (threadList != NULL)
    {
        vm_deallocate(
            mach_task_self(),
            (vm_address_t)threadList,
            threadCount * sizeof(thread_act_t)
        );
    }
}

#pragma mark - Memory

static void BHFCollectMemory(void)
{
    task_vm_info_data_t vmInfo;

    mach_msg_type_number_t count =
        TASK_VM_INFO_COUNT;

    kern_return_t kr =
        task_info(
            mach_task_self(),
            TASK_VM_INFO,
            (task_info_t)&vmInfo,
            &count
        );

    if (kr != KERN_SUCCESS)
        return;

    double memoryMB =
        (double)vmInfo.phys_footprint
        / (1024.0 * 1024.0);

    BHFLog(
        @"Memory footprint: %.1f MB",
        memoryMB
    );
}

#pragma mark - Diagnostic Loop

static void BHFStartDiagnostics(void)
{
    dispatch_queue_t queue =
        dispatch_queue_create(
            "com.bumble.heatfix.diagnostics",
            DISPATCH_QUEUE_SERIAL
        );

    dispatch_async(queue, ^{
        NSUInteger sampleNumber = 0;

        while (YES)
        {
            @autoreleasepool
            {
                sampleNumber++;

                BHFLog(
                    @"========== SAMPLE %lu ==========",
                    (unsigned long)sampleNumber
                );

                BHFCollectThreads();

                BHFCollectMemory();

                BHFLog(
                    @"Next sample in %.1f seconds",
                    BHF_SAMPLE_INTERVAL
                );
            }

            [NSThread sleepForTimeInterval:
                BHF_SAMPLE_INTERVAL];
        }
    });
}

#pragma mark - Overlay

static UILabel *BHFOverlayLabel = nil;

static UIWindow *BHFFindApplicationWindow(void)
{
    UIWindow *targetWindow = nil;

    if (@available(iOS 13.0, *))
    {
        NSSet<UIScene *> *scenes =
            [UIApplication sharedApplication].connectedScenes;

        for (UIScene *scene in scenes)
        {
            if (scene.activationState !=
                UISceneActivationStateForegroundActive)
            {
                continue;
            }

            if (![scene isKindOfClass:[UIWindowScene class]])
            {
                continue;
            }

            UIWindowScene *windowScene =
                (UIWindowScene *)scene;

            for (UIWindow *window in windowScene.windows)
            {
                if (window.hidden)
                    continue;

                if (window.alpha <= 0.0)
                    continue;

                if (window.windowLevel !=
                    UIWindowLevelNormal)
                {
                    continue;
                }

                targetWindow = window;

                if (window.isKeyWindow)
                    return window;
            }

            if (targetWindow)
                return targetWindow;
        }
    }
    else
    {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

        targetWindow =
            [UIApplication sharedApplication].keyWindow;

#pragma clang diagnostic pop
    }

    return targetWindow;
}

static void BHFCreateOverlay(void)
{
    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            UIWindow *targetWindow =
                BHFFindApplicationWindow();

            if (!targetWindow)
            {
                BHFLog(
                    @"Could not find application window"
                );

                return;
            }

            if (BHFOverlayLabel)
            {
                [BHFOverlayLabel removeFromSuperview];
                BHFOverlayLabel = nil;
            }

            UILabel *label =
                [[UILabel alloc]
                    initWithFrame:
                        CGRectMake(
                            8,
                            50,
                            280,
                            120
                        )];

            label.numberOfLines = 0;

            label.font =
                [UIFont monospacedSystemFontOfSize:
                    11.0
                    weight:UIFontWeightMedium];

            label.textColor =
                UIColor.whiteColor;

            label.backgroundColor =
                [[UIColor blackColor]
                    colorWithAlphaComponent:0.78];

            label.layer.cornerRadius = 8.0;
            label.layer.masksToBounds = YES;

            label.text =
                @"BumbleHeatFix v2\n"
                 "DIAGNOSTIC MODE\n"
                 "Monitoring CPU threads...\n"
                 "Sampling every 1 second\n"
                 "See console/log output.";

            [targetWindow addSubview:label];

            BHFOverlayLabel = label;

            BHFLog(
                @"Diagnostic overlay created successfully"
            );
        }
    );
}

#pragma mark - Constructor

%ctor
{
    @autoreleasepool
    {
        BHFLog(@"========================================");
        BHFLog(@"BumbleHeatFix v2 loaded");
        BHFLog(@"DIAGNOSTIC MODE");
        BHFLog(
            @"Process: %@",
            [[NSProcessInfo processInfo] processName]
        );
        BHFLog(
            @"PID: %d",
            getpid()
        );
        BHFLog(
            @"iOS: %@",
            [[UIDevice currentDevice] systemVersion]
        );
        BHFLog(
            @"Device: %@",
            [[UIDevice currentDevice] model]
        );
        BHFLog(@"========================================");

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

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                3 * NSEC_PER_SEC
            ),
            dispatch_get_main_queue(),
            ^{
                BHFStartDiagnostics();
            }
        );
    }
}
