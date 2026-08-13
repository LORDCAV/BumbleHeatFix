#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <mach/mach.h>
#import <mach/thread_info.h>

static UIWindow *BHFWindow = nil;
static UILabel *BHFLabel = nil;
static NSTimer *BHFTimer = nil;

static nw_path_monitor_t BHFNetworkMonitor = NULL;

static BOOL BHFNetworkOnline = NO;
static BOOL BHFNetworkExpensive = NO;
static BOOL BHFNetworkConstrained = NO;

static double BHFPeakCPU = 0.0;
static NSUInteger BHFHotSamples = 0;
static NSUInteger BHFTotalSamples = 0;

static thread_t BHFLastHotThread = MACH_PORT_NULL;
static NSUInteger BHFSameHotThreadSamples = 0;

static NSString *BHFNetworkState(void)
{
    if (!BHFNetworkOnline) {
        return @"OFFLINE";
    }

    if (BHFNetworkConstrained) {
        return @"CONSTRAINED";
    }

    if (BHFNetworkExpensive) {
        return @"EXPENSIVE";
    }

    return @"ONLINE";
}

static double BHFCPUUsage(void)
{
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t threadCount = 0;

    kern_return_t kr =
        task_threads(
            mach_task_self(),
            &threads,
            &threadCount
        );

    if (kr != KERN_SUCCESS || threads == NULL) {
        return 0.0;
    }

    double totalCPU = 0.0;

    for (mach_msg_type_number_t i = 0;
         i < threadCount;
         i++) {

        thread_basic_info_data_t info;
        mach_msg_type_number_t count =
            THREAD_BASIC_INFO_COUNT;

        kr =
            thread_info(
                threads[i],
                THREAD_BASIC_INFO,
                (thread_info_t)&info,
                &count
            );

        if (kr != KERN_SUCCESS) {
            continue;
        }

        if (info.flags & TH_FLAGS_IDLE) {
            continue;
        }

        double threadCPU =
            ((double)info.cpu_usage /
             (double)TH_USAGE_SCALE) * 100.0;

        totalCPU += threadCPU;
    }

    vm_deallocate(
        mach_task_self(),
        (vm_address_t)threads,
        (vm_size_t)(threadCount * sizeof(thread_t))
    );

    return totalCPU;
}

static BOOL BHFFindHotThread(thread_t *hotThread,
                             double *hotCPU)
{
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t threadCount = 0;

    kern_return_t kr =
        task_threads(
            mach_task_self(),
            &threads,
            &threadCount
        );

    if (kr != KERN_SUCCESS || threads == NULL) {
        return NO;
    }

    double highestCPU = 0.0;
    thread_t highestThread = MACH_PORT_NULL;

    for (mach_msg_type_number_t i = 0;
         i < threadCount;
         i++) {

        thread_basic_info_data_t info;
        mach_msg_type_number_t count =
            THREAD_BASIC_INFO_COUNT;

        kr =
            thread_info(
                threads[i],
                THREAD_BASIC_INFO,
                (thread_info_t)&info,
                &count
            );

        if (kr != KERN_SUCCESS) {
            continue;
        }

        if (info.flags & TH_FLAGS_IDLE) {
            continue;
        }

        double cpu =
            ((double)info.cpu_usage /
             (double)TH_USAGE_SCALE) * 100.0;

        if (cpu > highestCPU) {
            highestCPU = cpu;
            highestThread = threads[i];
        }
    }

    vm_deallocate(
        mach_task_self(),
        (vm_address_t)threads,
        (vm_size_t)(threadCount * sizeof(thread_t))
    );

    if (highestThread == MACH_PORT_NULL) {
        return NO;
    }

    if (hotThread != NULL) {
        *hotThread = highestThread;
    }

    if (hotCPU != NULL) {
        *hotCPU = highestCPU;
    }

    return YES;
}

static void BHFStartNetworkMonitor(void)
{
    BHFNetworkMonitor =
        nw_path_monitor_create();

    if (BHFNetworkMonitor == NULL) {
        return;
    }

    dispatch_queue_t queue =
        dispatch_get_global_queue(
            QOS_CLASS_UTILITY,
            0
        );

    nw_path_monitor_set_queue(
        BHFNetworkMonitor,
        queue
    );

    nw_path_monitor_set_update_handler(
        BHFNetworkMonitor,
        ^(nw_path_t path) {

            nw_path_status_t status =
                nw_path_get_status(path);

            BHFNetworkOnline =
                (status == nw_path_status_satisfied);

            BHFNetworkExpensive =
                nw_path_is_expensive(path);

            if (@available(iOS 13.0, *)) {
                BHFNetworkConstrained =
                    nw_path_is_constrained(path);
            }
            else {
                BHFNetworkConstrained = NO;
            }
        }
    );

    nw_path_monitor_start(
        BHFNetworkMonitor
    );
}

static void BHFCreateOverlay(void)
{
    if (BHFWindow != nil) {
        return;
    }

    CGRect bounds =
        [UIScreen mainScreen].bounds;

    BHFWindow =
        [[UIWindow alloc]
            initWithFrame:
            CGRectMake(
                10.0,
                45.0,
                bounds.size.width - 20.0,
                255.0
            )];

    BHFWindow.windowLevel =
        UIWindowLevelAlert + 100.0;

    BHFWindow.backgroundColor =
        [UIColor colorWithWhite:0.0
                          alpha:0.90];

    BHFWindow.layer.cornerRadius =
        14.0;

    BHFWindow.clipsToBounds = YES;

    BHFLabel =
        [[UILabel alloc]
            initWithFrame:
            CGRectMake(
                12.0,
                10.0,
                bounds.size.width - 44.0,
                235.0
            )];

    BHFLabel.textColor =
        [UIColor whiteColor];

    BHFLabel.backgroundColor =
        [UIColor clearColor];

    BHFLabel.font =
        [UIFont monospacedSystemFontOfSize:
            13.0
            weight:UIFontWeightRegular];

    BHFLabel.numberOfLines = 0;

    BHFLabel.textAlignment =
        NSTextAlignmentLeft;

    [BHFWindow addSubview:BHFLabel];

    BHFWindow.hidden = NO;

    [BHFWindow makeKeyAndVisible];
}

static void BHFUpdateOverlay(void)
{
    double cpu =
        BHFCPUUsage();

    thread_t hotThread =
        MACH_PORT_NULL;

    double hotThreadCPU = 0.0;

    BOOL haveHotThread =
        BHFFindHotThread(
            &hotThread,
            &hotThreadCPU
        );

    BHFTotalSamples++;

    if (cpu >= 80.0) {
        BHFHotSamples++;
    }

    if (cpu > BHFPeakCPU) {
        BHFPeakCPU = cpu;
    }

    if (haveHotThread) {

        if (hotThread == BHFLastHotThread) {
            BHFSameHotThreadSamples++;
        }
        else {
            BHFLastHotThread =
                hotThread;

            BHFSameHotThreadSamples = 1;
        }
    }

    NSString *network =
        BHFNetworkState();

    NSString *status;

    if (cpu >= 80.0) {
        status = @"HIGH CPU";
    }
    else if (cpu >= 40.0) {
        status = @"ELEVATED";
    }
    else {
        status = @"NORMAL";
    }

    NSString *hotThreadText;

    if (haveHotThread) {
        hotThreadText =
            [NSString stringWithFormat:
                @"Hot thread: %u\n"
                 @"Hot thread CPU: %.1f%%\n"
                 @"Same hot thread samples: %lu",
                 hotThread,
                 hotThreadCPU,
                 (unsigned long)
                    BHFSameHotThreadSamples];
    }
    else {
        hotThreadText =
            @"Hot thread: unavailable\n"
             "Hot thread CPU: unavailable\n"
             "Same hot thread samples: 0";
    }

    NSString *text =
        [NSString stringWithFormat:
            @"BumbleHeatFix\n"
             @"CPU CORRELATION v3.8\n"
             @"\n"
             @"CPU: %.1f%%\n"
             @"Peak CPU: %.1f%%\n"
             @"Hot samples: %lu / %lu\n"
             @"Network: %@\n"
             @"Status: %@\n"
             @"\n"
             @"%@\n"
             @"\n"
             @"YapDatabase reference:\n"
             @"+0xc7178\n"
             @"\n"
             @"OBSERVATION ONLY\n"
             @"No hook / no patch\n"
             @"No database modification",
             cpu,
             BHFPeakCPU,
             (unsigned long)BHFHotSamples,
             (unsigned long)BHFTotalSamples,
             network,
             status,
             hotThreadText];

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (BHFLabel == nil) {
                BHFCreateOverlay();
            }

            BHFLabel.text = text;
        }
    );
}

static void BHFStartMonitoring(void)
{
    dispatch_async(
        dispatch_get_main_queue(),
        ^{

            BHFCreateOverlay();

            BHFTimer =
                [NSTimer
                    scheduledTimerWithTimeInterval:
                        5.0
                        repeats:YES
                        block:^(NSTimer *timer) {

                BHFUpdateOverlay();
            }];

            BHFUpdateOverlay();
        }
    );
}

__attribute__((constructor))
static void BumbleHeatFixInit(void)
{
    @autoreleasepool {

        BHFStartNetworkMonitor();

        BHFStartMonitoring();
    }
}
