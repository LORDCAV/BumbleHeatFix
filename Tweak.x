#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <mach/mach.h>

static UIWindow *BHFOverlayWindow = nil;
static UILabel *BHFOverlayLabel = nil;

static nw_path_monitor_t BHFNetworkMonitor = NULL;

static BOOL BHFNetworkAvailable = NO;
static BOOL BHFNetworkExpensive = NO;
static BOOL BHFNetworkConstrained = NO;

static double BHFPeakCPU = 0.0;
static NSUInteger BHFHotSamples = 0;

static double BHFGetCPUUsage(void)
{
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t threadCount = 0;

    kern_return_t result =
        task_threads(
            mach_task_self(),
            &threads,
            &threadCount
        );

    if (result != KERN_SUCCESS || threads == NULL) {
        return 0.0;
    }

    double totalCPU = 0.0;

    for (mach_msg_type_number_t i = 0;
         i < threadCount;
         i++) {

        thread_basic_info_data_t info;
        mach_msg_type_number_t count =
            THREAD_BASIC_INFO_COUNT;

        kern_return_t threadResult =
            thread_info(
                threads[i],
                THREAD_BASIC_INFO,
                (thread_info_t)&info,
                &count
            );

        if (threadResult != KERN_SUCCESS) {
            continue;
        }

        if (info.flags & TH_FLAGS_IDLE) {
            continue;
        }

        totalCPU +=
            ((double)info.cpu_usage /
             (double)TH_USAGE_SCALE) * 100.0;
    }

    vm_deallocate(
        mach_task_self(),
        (vm_address_t)threads,
        (vm_size_t)(threadCount * sizeof(thread_t))
    );

    return totalCPU;
}

static NSString *BHFNetworkState(void)
{
    if (!BHFNetworkAvailable) {
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

            BHFNetworkAvailable =
                (status == nw_path_status_satisfied);

            BHFNetworkExpensive =
                nw_path_is_expensive(path);

            if (@available(iOS 13.0, *)) {
                BHFNetworkConstrained =
                    nw_path_is_constrained(path);
            } else {
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
    dispatch_async(
        dispatch_get_main_queue(),
        ^{

            if (BHFOverlayWindow != nil) {
                return;
            }

            CGRect screenBounds =
                [UIScreen mainScreen].bounds;

            BHFOverlayWindow =
                [[UIWindow alloc]
                    initWithFrame:
                    CGRectMake(
                        10.0,
                        50.0,
                        screenBounds.size.width - 20.0,
                        190.0
                    )];

            BHFOverlayWindow.windowLevel =
                UIWindowLevelAlert + 100.0;

            BHFOverlayWindow.backgroundColor =
                [UIColor colorWithWhite:0.0
                                  alpha:0.88];

            BHFOverlayWindow.layer.cornerRadius =
                12.0;

            BHFOverlayWindow.clipsToBounds = YES;

            BHFOverlayLabel =
                [[UILabel alloc]
                    initWithFrame:
                    CGRectMake(
                        12.0,
                        10.0,
                        screenBounds.size.width - 44.0,
                        170.0
                    )];

            BHFOverlayLabel.textColor =
                [UIColor whiteColor];

            BHFOverlayLabel.backgroundColor =
                [UIColor clearColor];

            BHFOverlayLabel.font =
                [UIFont monospacedSystemFontOfSize:
                    13.0
                    weight:UIFontWeightRegular];

            BHFOverlayLabel.numberOfLines = 0;

            BHFOverlayLabel.textAlignment =
                NSTextAlignmentLeft;

            [BHFOverlayWindow
                addSubview:BHFOverlayLabel];

            BHFOverlayWindow.hidden = NO;

            [BHFOverlayWindow
                makeKeyAndVisible];
        }
    );
}

static void BHFUpdateOverlay(void)
{
    double cpu =
        BHFGetCPUUsage();

    if (cpu > BHFPeakCPU) {
        BHFPeakCPU = cpu;
    }

    if (cpu >= 80.0) {
        BHFHotSamples++;
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

    NSString *text =
        [NSString stringWithFormat:
            @"BumbleHeatFix\n"
             @"NETWORK OBSERVER v3.7\n"
             @"\n"
             @"CPU: %.1f%%\n"
             @"Peak CPU: %.1f%%\n"
             @"Hot samples: %lu\n"
             @"Network: %@\n"
             @"Status: %@\n"
             @"\n"
             @"OBSERVATION ONLY\n"
             @"No network blocking\n"
             @"No thread changes\n"
             @"No suspension / termination",
             cpu,
             BHFPeakCPU,
             (unsigned long)BHFHotSamples,
             network,
             status];

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (BHFOverlayLabel == nil) {
                BHFCreateOverlay();
            }

            BHFOverlayLabel.text = text;
        }
    );
}

static void BHFStartTimer(void)
{
    dispatch_async(
        dispatch_get_main_queue(),
        ^{

            BHFCreateOverlay();

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

        BHFStartTimer();
    }
}
