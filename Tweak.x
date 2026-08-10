```objc
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <mach/mach_host.h>
#import <mach/task_info.h>
#import <mach/thread_info.h>
#import <mach/thread_act.h>
#import <pthread.h>

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

#pragma mark - CPU Measurement

static double BHFGetProcessCPUUsage(void)
{
    task_t task = mach_task_self();

    task_thread_times_info_data_t taskTime;
    mach_msg_type_number_t count = TASK_THREAD_TIMES_INFO_COUNT;

    kern_return_t kr =
        task_info(
            task,
            TASK_THREAD_TIMES_INFO,
            (task_info_t)&taskTime,
            &count
        );

    if (kr != KERN_SUCCESS)
        return -1.0;

    uint64_t totalNanoseconds =
        ((uint64_t)taskTime.user_time.seconds * NSEC_PER_SEC) +
        taskTime.user_time.microseconds * 1000ULL +
        ((uint64_t)taskTime.system_time.seconds * NSEC_PER_SEC) +
        taskTime.system_time.microseconds * 1000ULL;

    static uint64_t previousTime = 0;
    static CFAbsoluteTime previousTimestamp = 0;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    if (previousTime == 0)
    {
        previousTime = totalNanoseconds;
        previousTimestamp = now;
        return 0.0;
    }

    uint64_t deltaCPU = totalNanoseconds - previousTime;
    CFAbsoluteTime deltaTime = now - previousTimestamp;

    previousTime = totalNanoseconds;
    previousTimestamp = now;

    if (deltaTime <= 0.0)
        return 0.0;

    /*
     * One fully utilized CPU core = approximately 100%.
     * Multiple busy cores can therefore produce values
     * greater than 100%.
     */
    double cpu =
        ((double)deltaCPU / 1000000000.0) /
        deltaTime *
        100.0;

    return cpu;
}

#pragma mark - Thread Count

static NSUInteger BHFGetThreadCount(void)
{
    task_t task = mach_task_self();

    thread_act_array_t threads = NULL;
    mach_msg_type_number_t threadCount = 0;

    kern_return_t kr =
        task_threads(
            task,
            &threads,
            &threadCount
        );

    if (kr != KERN_SUCCESS)
        return 0;

    NSUInteger count = (NSUInteger)threadCount;

    vm_deallocate(
        mach_task_self(),
        (vm_address_t)threads,
        threadCount * sizeof(thread_act_t)
    );

    return count;
}

#pragma mark - Memory

static double BHFGetMemoryMB(void)
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
        return -1.0;

    return (double)vmInfo.phys_footprint /
           (1024.0 * 1024.0);
}

#pragma mark - Overlay

static UILabel *BHFOverlayLabel = nil;
static NSTimer *BHFMonitorTimer = nil;

static void BHFUpdateOverlay(void)
{
    if (!BHFOverlayLabel)
        return;

    double cpu = BHFGetProcessCPUUsage();
    NSUInteger threads = BHFGetThreadCount();
    double memory = BHFGetMemoryMB();

    NSString *cpuText;

    if (cpu < 0.0)
    {
        cpuText = @"CPU: unavailable";
    }
    else
    {
        cpuText =
            [NSString stringWithFormat:@"CPU: %.1f%%", cpu];
    }

    NSString *memoryText;

    if (memory < 0.0)
    {
        memoryText = @"Memory: unavailable";
    }
    else
    {
        memoryText =
            [NSString stringWithFormat:@"Memory: %.0f MB", memory];
    }

    BHFOverlayLabel.text =
        [NSString stringWithFormat:
            @"BumbleHeatFix\n"
             "CPU MONITOR\n\n"
             "Dylib: LOADED\n"
             "%@\n"
             "Threads: %lu\n"
             "%@",
             cpuText,
             (unsigned long)threads,
             memoryText
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
            if (BHFOverlayLabel)
                return;

            UIWindow *targetWindow = nil;

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

                    if (![scene isKindOfClass:[UIWindowScene class]])
                        continue;

                    UIWindowScene *windowScene =
                        (UIWindowScene *)scene;

                    for (UIWindow *window in windowScene.windows)
                    {
                        if (window.isKeyWindow)
                        {
                            targetWindow = window;
                            break;
                        }
                    }

                    if (targetWindow)
                        break;
                }
            }
            else
            {
                targetWindow =
                    [UIApplication sharedApplication].keyWindow;
            }

            if (!targetWindow)
            {
                BHFLog(@"Unable to find application window");
                return;
            }

            BHFOverlayLabel =
                [[UILabel alloc]
                    initWithFrame:
                        CGRectMake(15, 80, 260, 150)];

            BHFOverlayLabel.numberOfLines = 0;

            BHFOverlayLabel.text =
                @"BumbleHeatFix\n"
                 "CPU MONITOR\n\n"
                 "Dylib: LOADED\n"
                 "Starting monitor...";

            BHFOverlayLabel.textColor =
                [UIColor whiteColor];

            BHFOverlayLabel.backgroundColor =
                [[UIColor blackColor]
                    colorWithAlphaComponent:0.75];

            BHFOverlayLabel.font =
                [UIFont monospacedSystemFontOfSize:13
                                            weight:UIFontWeightRegular];

            BHFOverlayLabel.layer.cornerRadius = 10.0;
            BHFOverlayLabel.layer.masksToBounds = YES;

            BHFOverlayLabel.textAlignment =
                NSTextAlignmentLeft;

            BHFOverlayLabel.userInteractionEnabled = NO;

            [targetWindow addSubview:BHFOverlayLabel];

            BHFLog(@"CPU monitoring overlay created");

            BHFUpdateOverlay();

            BHFMonitorTimer =
                [NSTimer scheduledTimerWithTimeInterval:1.0
                                                 repeats:YES
                                                   block:
                ^(NSTimer *timer)
                {
                    BHFUpdateOverlay();
                }];
        }
    );
}

#pragma mark - Constructor

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
