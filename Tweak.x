#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <pthread.h>

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
    UIApplication *application = [UIApplication sharedApplication];

    if (@available(iOS 13.0, *))
    {
        for (UIScene *scene in application.connectedScenes)
        {
            if (scene.activationState ==
                    UISceneActivationStateForegroundActive ||
                scene.activationState ==
                    UISceneActivationStateForegroundInactive)
            {
                if ([scene isKindOfClass:[UIWindowScene class]])
                {
                    UIWindowScene *windowScene =
                        (UIWindowScene *)scene;

                    for (UIWindow *window in windowScene.windows)
                    {
                        if (window.isKeyWindow)
                        {
                            return window;
                        }
                    }

                    for (UIWindow *window in windowScene.windows)
                    {
                        if (!window.hidden && window.alpha > 0.0)
                        {
                            return window;
                        }
                    }
                }
            }
        }
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

    return application.keyWindow;

#pragma clang diagnostic pop
}

static double BHFCPUTimeSeconds(void)
{
    task_thread_times_info_data_t info;

    mach_msg_type_number_t count =
        TASK_THREAD_TIMES_INFO_COUNT;

    kern_return_t result =
        task_info(
            mach_task_self(),
            TASK_THREAD_TIMES_INFO,
            (task_info_t)&info,
            &count
        );

    if (result != KERN_SUCCESS)
    {
        return 0.0;
    }

    double user =
        (double)info.user_time.seconds +
        ((double)info.user_time.microseconds / 1000000.0);

    double system =
        (double)info.system_time.seconds +
        ((double)info.system_time.microseconds / 1000000.0);

    return user + system;
}

static NSUInteger BHFThreadCount(void)
{
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t threadCount = 0;

    kern_return_t result =
        task_threads(
            mach_task_self(),
            &threads,
            &threadCount
        );

    if (result != KERN_SUCCESS)
    {
        return 0;
    }

    for (mach_msg_type_number_t i = 0;
         i < threadCount;
         i++)
    {
        mach_port_deallocate(
            mach_task_self(),
            threads[i]
        );
    }

    vm_deallocate(
        mach_task_self(),
        (vm_address_t)threads,
        threadCount * sizeof(thread_act_t)
    );

    return threadCount;
}

static double BHFMemoryMB(void)
{
    task_basic_info_data_t taskInfo;

    mach_msg_type_number_t count =
        TASK_BASIC_INFO_COUNT;

    kern_return_t result =
        task_info(
            mach_task_self(),
            TASK_BASIC_INFO,
            (task_info_t)&taskInfo,
            &count
        );

    if (result != KERN_SUCCESS)
    {
        return 0.0;
    }

    return
        (double)taskInfo.resident_size /
        1024.0 /
        1024.0;
}

static void BHFUpdateOverlay(
    double cpuTime,
    double cpuDelta,
    NSUInteger threads,
    double memory
)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = BHFGetWindow();

        if (!window)
        {
            return;
        }

        UILabel *label =
            (UILabel *)[window viewWithTag:7654321];

        if (!label)
        {
            label = [[UILabel alloc] init];

            label.tag = 7654321;

            label.textColor = [UIColor whiteColor];

            label.backgroundColor =
                [[UIColor blackColor]
                    colorWithAlphaComponent:0.85];

            label.textAlignment =
                NSTextAlignmentCenter;

            label.font =
                [UIFont systemFontOfSize:12.0
                                  weight:UIFontWeightSemibold];

            label.numberOfLines = 0;

            label.layer.cornerRadius = 10.0;
            label.layer.masksToBounds = YES;

            label.translatesAutoresizingMaskIntoConstraints =
                NO;

            [window addSubview:label];

            [NSLayoutConstraint activateConstraints:@[
                [label.centerXAnchor
                    constraintEqualToAnchor:
                        window.centerXAnchor],

                [label.topAnchor
                    constraintEqualToAnchor:
                        window.safeAreaLayoutGuide.topAnchor
                    constant:10.0],

                [label.widthAnchor
                    constraintLessThanOrEqualToAnchor:
                        window.widthAnchor
                    multiplier:0.90],

                [label.heightAnchor
                    constraintGreaterThanOrEqualToConstant:
                        55.0]
            ]];
        }

        NSString *text =
            [NSString stringWithFormat:
                @"BumbleHeatFix\n"
                 "CPU time: %.2fs\n"
                 "CPU Δ/1s: %.2fs\n"
                 "Threads: %lu\n"
                 "Memory: %.0f MB",
                 cpuTime,
                 cpuDelta,
                 (unsigned long)threads,
                 memory];

        label.text = text;
    });
}

static void BHFStartMonitor(void)
{
    __block double previousCPU =
        BHFCPUTimeSeconds();

    dispatch_queue_t queue =
        dispatch_get_global_queue(
            QOS_CLASS_UTILITY,
            0
        );

    dispatch_async(queue, ^{
        while (YES)
        {
            [NSThread sleepForTimeInterval:1.0];

            double currentCPU =
                BHFCPUTimeSeconds();

            double delta =
                currentCPU - previousCPU;

            previousCPU = currentCPU;

            NSUInteger threads =
                BHFThreadCount();

            double memory =
                BHFMemoryMB();

            BHFLog(
                @"CPU %.2fs | Δ %.2fs | Threads %lu | Memory %.0f MB",
                currentCPU,
                delta,
                (unsigned long)threads,
                memory
            );

            BHFUpdateOverlay(
                currentCPU,
                delta,
                threads,
                memory
            );
        }
    });
}

%ctor
{
    @autoreleasepool
    {
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

        dispatch_async(
            dispatch_get_main_queue(),
            ^{
                BHFUpdateOverlay(
                    BHFCPUTimeSeconds(),
                    0.0,
                    BHFThreadCount(),
                    BHFMemoryMB()
                );
            }
        );

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                2 * NSEC_PER_SEC
            ),
            dispatch_get_main_queue(),
            ^{
                BHFStartMonitor();
            }
        );
    }
}
