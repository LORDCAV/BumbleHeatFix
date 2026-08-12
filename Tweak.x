#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <pthread.h>

static nw_path_monitor_t BHFNetworkMonitor = NULL;
static nw_path_t BHFCurrentPath = NULL;

static BOOL BHFNetworkSatisfied = NO;
static BOOL BHFExpensiveNetwork = NO;
static BOOL BHFConstrainedNetwork = NO;

static NSTimer *BHFMonitorTimer = nil;

static NSUInteger BHFHotSamples = 0;
static double BHFPeakCPU = 0.0;

#pragma mark - CPU

static double BHFProcessCPUUsage(void)
{
    mach_msg_type_number_t threadCount = 0;
    thread_act_array_t threadList = NULL;

    kern_return_t kr = task_threads(
        mach_task_self(),
        &threadList,
        &threadCount
    );

    if (kr != KERN_SUCCESS || threadList == NULL) {
        return 0.0;
    }

    double totalCPU = 0.0;

    for (mach_msg_type_number_t i = 0; i < threadCount; i++) {

        thread_basic_info_data_t info;
        mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;

        kr = thread_info(
            threadList[i],
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

        totalCPU +=
            ((double)info.cpu_usage / (double)TH_USAGE_SCALE) * 100.0;
    }

    vm_deallocate(
        mach_task_self(),
        (vm_address_t)threadList,
        (vm_size_t)(threadCount * sizeof(thread_t))
    );

    return totalCPU;
}

#pragma mark - Network

static NSString *BHFNetworkStateName(void)
{
    if (!BHFNetworkSatisfied) {
        return @"OFFLINE";
    }

    if (BHFConstrainedNetwork) {
        return @"CONSTRAINED";
    }

    if (BHFExpensiveNetwork) {
        return @"EXPENSIVE";
    }

    return @"ONLINE";
}

static void BHFStartNetworkMonitor(void)
{
    BHFNetworkMonitor = nw_path_monitor_create();

    if (BHFNetworkMonitor == NULL) {
        return;
    }

    dispatch_queue_t queue =
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);

    nw_path_monitor_set_queue(
        BHFNetworkMonitor,
        queue
    );

    nw_path_monitor_set_update_handler(
        BHFNetworkMonitor,
        ^(nw_path_t path) {

            BHFCurrentPath = path;

            nw_path_status_t status =
                nw_path_get_status(path);

            BHFNetworkSatisfied =
                (status == nw_path_status_satisfied);

            BHFExpensiveNetwork =
                nw_path_is_expensive(path);

            if (@available(iOS 13.0, *)) {
                BHFConstrainedNetwork =
                    nw_path_is_constrained(path);
            } else {
                BHFConstrainedNetwork = NO;
            }
        }
    );

    nw_path_monitor_start(
        BHFNetworkMonitor
    );
}

#pragma mark - Reporter

static void BHFPrintReport(void)
{
    double cpu = BHFProcessCPUUsage();

    if (cpu > BHFPeakCPU) {
        BHFPeakCPU = cpu;
    }

    if (cpu >= 80.0) {
        BHFHotSamples++;
    }

    NSString *networkState =
        BHFNetworkStateName();

    NSString *status;

    if (cpu >= 80.0) {
        status = @"HIGH CPU";
    } else if (cpu >= 40.0) {
        status = @"ELEVATED CPU";
    } else {
        status = @"NORMAL";
    }

    NSLog(
        @"\n"
        @"==============================\n"
        @"BumbleHeatFix NETWORK v3.7\n"
        @"==============================\n"
        @"CPU: %.1f%%\n"
        @"Peak CPU: %.1f%%\n"
        @"Hot samples: %lu\n"
        @"Network: %@\n"
        @"Status: %@\n"
        @"\n"
        @"NETWORK OBSERVATION ONLY\n"
        @"No request blocking\n"
        @"No network modification\n"
        @"No thread priority changes\n"
        @"No suspension\n"
        @"No termination\n"
        @"No database modification\n"
        @"No executable patching\n"
        @"==============================",
        cpu,
        BHFPeakCPU,
        (unsigned long)BHFHotSamples,
        networkState,
        status
    );
}

#pragma mark - Startup

static void BHFStartMonitoring(void)
{
    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            BHFStartNetworkMonitor();

            BHFMonitorTimer =
                [NSTimer scheduledTimerWithTimeInterval:5.0
                                                 repeats:YES
                                                   block:^(NSTimer *timer) {
                BHFPrintReport();
            }];

            BHFPrintReport();
        }
    );
}

__attribute__((constructor))
static void BumbleHeatFixInit(void)
{
    @autoreleasepool {
        BHFStartMonitoring();
    }
}
