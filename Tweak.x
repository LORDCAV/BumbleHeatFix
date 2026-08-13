#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Network/Network.h>

#import <mach/mach.h>
#import <mach/mach_init.h>
#import <mach/thread_info.h>

#import <mach-o/dyld.h>
#import <mach-o/loader.h>

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
static NSUInteger BHFSameThreadSamples = 0;

static NSUInteger BHFBumbleSamples = 0;
static NSUInteger BHFYapSamples = 0;
static NSUInteger BHFObjCSamples = 0;
static NSUInteger BHFFoundationSamples = 0;
static NSUInteger BHFCoreFoundationSamples = 0;
static NSUInteger BHFSystemSamples = 0;
static NSUInteger BHFOtherSamples = 0;

static uintptr_t BHFLastPC = 0;
static uintptr_t BHFLastImageBase = 0;
static uintptr_t BHFLastImageOffset = 0;

static NSString *BHFLastImage = @"unknown";

#pragma mark - Network

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

#pragma mark - CPU

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

        double cpu =
            ((double)info.cpu_usage /
             (double)TH_USAGE_SCALE) * 100.0;

        totalCPU += cpu;
    }

    vm_deallocate(
        mach_task_self(),
        (vm_address_t)threads,
        (vm_size_t)(
            threadCount * sizeof(thread_t)
        )
    );

    return totalCPU;
}

static BOOL BHFGetHotThread(thread_t *resultThread,
                            double *resultCPU)
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
        (vm_size_t)(
            threadCount * sizeof(thread_t)
        )
    );

    if (highestThread == MACH_PORT_NULL) {
        return NO;
    }

    if (resultThread != NULL) {
        *resultThread = highestThread;
    }

    if (resultCPU != NULL) {
        *resultCPU = highestCPU;
    }

    return YES;
}

#pragma mark - Image lookup

static const struct mach_header_64 *
BHFHeaderForImageIndex(uint32_t index)
{
    const struct mach_header *header =
        _dyld_get_image_header(index);

    if (header == NULL) {
        return NULL;
    }

    if (header->magic != MH_MAGIC_64) {
        return NULL;
    }

    return (const struct mach_header_64 *)header;
}

static NSString *BHFImageForAddress(
    uintptr_t address,
    uintptr_t *baseOut,
    uintptr_t *offsetOut
)
{
    uint32_t count =
        _dyld_image_count();

    for (uint32_t i = 0;
         i < count;
         i++) {

        const struct mach_header_64 *header =
            BHFHeaderForImageIndex(i);

        if (header == NULL) {
            continue;
        }

        intptr_t slide =
            _dyld_get_image_vmaddr_slide(i);

        uintptr_t base =
            (uintptr_t)header +
            (uintptr_t)slide;

        const char *name =
            _dyld_get_image_name(i);

        if (name == NULL) {
            continue;
        }

        uintptr_t imageEnd =
            base;

        const uint8_t *commandPtr =
            (const uint8_t *)(header + 1);

        for (uint32_t commandIndex = 0;
             commandIndex < header->ncmds;
             commandIndex++) {

            const struct load_command *command =
                (const struct load_command *)commandPtr;

            if (command->cmdsize <
                sizeof(struct load_command)) {
                break;
            }

            if (command->cmd ==
                LC_SEGMENT_64) {

                const struct segment_command_64 *segment =
                    (const struct segment_command_64 *)command;

                uintptr_t segmentStart =
                    (uintptr_t)segment->vmaddr +
                    (uintptr_t)slide;

                uintptr_t segmentEnd =
                    segmentStart +
                    (uintptr_t)segment->vmsize;

                if (segmentEnd > imageEnd) {
                    imageEnd = segmentEnd;
                }
            }

            commandPtr += command->cmdsize;
        }

        if (address >= base &&
            address < imageEnd) {

            if (baseOut != NULL) {
                *baseOut = base;
            }

            if (offsetOut != NULL) {
                *offsetOut =
                    address - base;
            }

            return
                [NSString stringWithUTF8String:name];
        }
    }

    if (baseOut != NULL) {
        *baseOut = 0;
    }

    if (offsetOut != NULL) {
        *offsetOut = 0;
    }

    return @"unknown";
}

#pragma mark - Classification

static void BHFClassifyImage(NSString *image)
{
    if (image == nil) {
        BHFOtherSamples++;
        return;
    }

    NSString *lower =
        [image lowercaseString];

    if ([lower containsString:@"yapdatabase"]) {

        BHFYapSamples++;
        return;
    }

    if ([lower containsString:@"libobjc"]) {

        BHFObjCSamples++;
        return;
    }

    if ([lower containsString:@"foundation.framework"]) {

        BHFFoundationSamples++;
        return;
    }

    if ([lower containsString:@"corefoundation.framework"]) {

        BHFCoreFoundationSamples++;
        return;
    }

    if ([lower containsString:@"/bumble.app/bumble"]) {

        BHFBumbleSamples++;
        return;
    }

    if ([lower containsString:@"libsystem"]) {

        BHFSystemSamples++;
        return;
    }

    BHFOtherSamples++;
}

#pragma mark - Overlay

static void BHFCreateOverlay(void)
{
    if (BHFWindow != nil) {
        return;
    }

    CGRect screen =
        [UIScreen mainScreen].bounds;

    CGFloat width =
        screen.size.width - 16.0;

    BHFWindow =
        [[UIWindow alloc]
            initWithFrame:
            CGRectMake(
                8.0,
                35.0,
                width,
                420.0
            )];

    BHFWindow.windowLevel =
        UIWindowLevelAlert + 100.0;

    BHFWindow.backgroundColor =
        [UIColor colorWithWhite:0.0
                          alpha:0.94];

    BHFWindow.layer.cornerRadius =
        14.0;

    BHFWindow.clipsToBounds = YES;

    BHFLabel =
        [[UILabel alloc]
            initWithFrame:
            CGRectMake(
                12.0,
                10.0,
                width - 24.0,
                400.0
            )];

    BHFLabel.textColor =
        [UIColor whiteColor];

    BHFLabel.font =
        [UIFont monospacedSystemFontOfSize:
            11.5
            weight:UIFontWeightRegular];

    BHFLabel.numberOfLines = 0;

    BHFLabel.textAlignment =
        NSTextAlignmentLeft;

    [BHFWindow addSubview:BHFLabel];

    BHFWindow.hidden = NO;

    [BHFWindow makeKeyAndVisible];
}

#pragma mark - Sampling

static void BHFUpdateOverlay(void)
{
    double cpu =
        BHFCPUUsage();

    thread_t hotThread =
        MACH_PORT_NULL;

    double hotThreadCPU = 0.0;

    BOOL found =
        BHFGetHotThread(
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

    if (found) {

        if (hotThread ==
            BHFLastHotThread) {

            BHFSameThreadSamples++;
        }
        else {

            BHFLastHotThread =
                hotThread;

            BHFSameThreadSamples = 1;
        }

        BHFLastPC =
            0;

        mach_msg_type_number_t count =
            ARM_THREAD_STATE64_COUNT;

        arm_thread_state64_t state;

        kern_return_t kr =
            thread_get_state(
                hotThread,
                ARM_THREAD_STATE64,
                (thread_state_t)&state,
                &count
            );

        if (kr == KERN_SUCCESS) {

            BHFLastPC =
                (uintptr_t)state.__pc;
        }

        BHFLastImage =
            BHFImageForAddress(
                BHFLastPC,
                &BHFLastImageBase,
                &BHFLastImageOffset
            );

        BHFClassifyImage(
            BHFLastImage
        );
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
             @"CPU SOURCE TRACKER v4.0\n"
             @"\n"
             @"CPU: %.1f%%\n"
             @"Peak: %.1f%%\n"
             @"Hot samples: %lu / %lu\n"
             @"Network: %@\n"
             @"Status: %@\n"
             @"\n"
             @"HOT THREAD\n"
             @"TID: %u\n"
             @"CPU: %.1f%%\n"
             @"Same thread: %lu\n"
             @"\n"
             @"CURRENT IMAGE\n"
             @"%@\n"
             @"BASE: 0x%llx\n"
             @"OFFSET: +0x%llx\n"
             @"PC: 0x%llx\n"
             @"\n"
             @"SOURCE SAMPLES\n"
             @"Bumble: %lu\n"
             @"YapDatabase: %lu\n"
             @"libobjc: %lu\n"
             @"Foundation: %lu\n"
             @"CoreFoundation: %lu\n"
             @"libsystem: %lu\n"
             @"Other: %lu\n"
             @"\n"
             @"TARGET STATUS\n"
             @"Observation only\n"
             @"No hook\n"
             @"No patch\n"
             @"No priority changes\n"
             @"No suspension\n"
             @"No termination",
             cpu,
             BHFPeakCPU,
             (unsigned long)BHFHotSamples,
             (unsigned long)BHFTotalSamples,
             network,
             status,
             found ? hotThread : 0,
             found ? hotThreadCPU : 0.0,
             (unsigned long)BHFSameThreadSamples,
             BHFLastImage,
             (unsigned long long)BHFLastImageBase,
             (unsigned long long)BHFLastImageOffset,
             (unsigned long long)BHFLastPC,
             (unsigned long)BHFBumbleSamples,
             (unsigned long)BHFYapSamples,
             (unsigned long)BHFObjCSamples,
             (unsigned long)BHFFoundationSamples,
             (unsigned long)BHFCoreFoundationSamples,
             (unsigned long)BHFSystemSamples,
             (unsigned long)BHFOtherSamples
        ];

    dispatch_async(
        dispatch_get_main_queue(),
        ^{

            if (BHFWindow == nil) {
                BHFCreateOverlay();
            }

            BHFLabel.text = text;
        }
    );
}

#pragma mark - Start

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
