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
static NSUInteger BHFSameHotThreadSamples = 0;

static NSUInteger BHFYapSamples = 0;

static uintptr_t BHFLastPC = 0;
static uintptr_t BHFLastImageBase = 0;
static intptr_t BHFLastImageOffset = 0;

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

        double cpu =
            ((double)info.cpu_usage /
             (double)TH_USAGE_SCALE) * 100.0;

        totalCPU += cpu;
    }

    vm_deallocate(
        mach_task_self(),
        (vm_address_t)threads,
        (vm_size_t)(threadCount * sizeof(thread_t))
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
        (vm_size_t)(threadCount * sizeof(thread_t))
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

static uintptr_t BHFGetThreadPC(thread_t thread)
{
    arm_thread_state64_t state;
    mach_msg_type_number_t count =
        ARM_THREAD_STATE64_COUNT;

    kern_return_t kr =
        thread_get_state(
            thread,
            ARM_THREAD_STATE64,
            (thread_state_t)&state,
            &count
        );

    if (kr != KERN_SUCCESS) {
        return 0;
    }

    return (uintptr_t)state.__pc;
}

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

static NSString *BHFImageNameForAddress(uintptr_t address,
                                         uintptr_t *base,
                                         intptr_t *offset)
{
    uint32_t count =
        _dyld_image_count();

    for (uint32_t i = 0; i < count; i++) {

        const struct mach_header_64 *header =
            BHFHeaderForImageIndex(i);

        if (header == NULL) {
            continue;
        }

        intptr_t slide =
            _dyld_get_image_vmaddr_slide(i);

        uintptr_t imageBase =
            (uintptr_t)header +
            (uintptr_t)slide;

        const char *name =
            _dyld_get_image_name(i);

        if (name == NULL) {
            continue;
        }

        const uint8_t *commandPtr =
            (const uint8_t *)(header + 1);

        uintptr_t imageEnd =
            imageBase;

        for (uint32_t commandIndex = 0;
             commandIndex < header->ncmds;
             commandIndex++) {

            const struct load_command *command =
                (const struct load_command *)commandPtr;

            if (command->cmdsize <
                sizeof(struct load_command)) {
                break;
            }

            if (command->cmd == LC_SEGMENT_64) {

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

        if (address >= imageBase &&
            address < imageEnd) {

            if (base != NULL) {
                *base = imageBase;
            }

            if (offset != NULL) {
                *offset =
                    (intptr_t)(address - imageBase);
            }

            return [NSString
                stringWithUTF8String:name];
        }
    }

    if (base != NULL) {
        *base = 0;
    }

    if (offset != NULL) {
        *offset = 0;
    }

    return @"unknown";
}

static BOOL BHFIsYapDatabaseImage(NSString *imageName)
{
    if (imageName == nil) {
        return NO;
    }

    return
        [imageName rangeOfString:
            @"YapDatabase.framework/YapDatabase"
            options:NSCaseInsensitiveSearch].location
        != NSNotFound;
}

static uintptr_t BHFCurrentYapTarget(void)
{
    uint32_t count =
        _dyld_image_count();

    for (uint32_t i = 0; i < count; i++) {

        const char *name =
            _dyld_get_image_name(i);

        if (name == NULL) {
            continue;
        }

        NSString *imageName =
            [NSString stringWithUTF8String:name];

        if (!BHFIsYapDatabaseImage(imageName)) {
            continue;
        }

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

        return base + 0xc7178;
    }

    return 0;
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

    CGRect screen =
        [UIScreen mainScreen].bounds;

    BHFWindow =
        [[UIWindow alloc]
            initWithFrame:
            CGRectMake(
                8.0,
                40.0,
                screen.size.width - 16.0,
                360.0
            )];

    BHFWindow.windowLevel =
        UIWindowLevelAlert + 100.0;

    BHFWindow.backgroundColor =
        [UIColor colorWithWhite:0.0
                          alpha:0.92];

    BHFWindow.layer.cornerRadius =
        14.0;

    BHFWindow.clipsToBounds = YES;

    BHFLabel =
        [[UILabel alloc]
            initWithFrame:
            CGRectMake(
                12.0,
                10.0,
                screen.size.width - 40.0,
                340.0
            )];

    BHFLabel.textColor =
        [UIColor whiteColor];

    BHFLabel.font =
        [UIFont monospacedSystemFontOfSize:
            12.5
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

    BOOL foundHotThread =
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

    if (foundHotThread) {

        if (hotThread == BHFLastHotThread) {
            BHFSameHotThreadSamples++;
        }
        else {
            BHFLastHotThread =
                hotThread;

            BHFSameHotThreadSamples = 1;
        }

        BHFLastPC =
            BHFGetThreadPC(hotThread);

        uintptr_t imageBase = 0;
        intptr_t imageOffset = 0;

        NSString *image =
            BHFImageNameForAddress(
                BHFLastPC,
                &imageBase,
                &imageOffset
            );

        BHFLastImageBase =
            imageBase;

        BHFLastImageOffset =
            imageOffset;

        if (BHFIsYapDatabaseImage(image)) {
            BHFYapSamples++;
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

    NSString *currentImage =
        @"unknown";

    if (BHFLastPC != 0) {

        uintptr_t dummyBase = 0;
        intptr_t dummyOffset = 0;

        currentImage =
            BHFImageNameForAddress(
                BHFLastPC,
                &dummyBase,
                &dummyOffset
            );
    }

    uintptr_t yapTarget =
        BHFCurrentYapTarget();

    NSString *yapTargetText =
        yapTarget != 0
        ?
        [NSString stringWithFormat:
            @"0x%llx",
            (unsigned long long)yapTarget]
        :
        @"NOT FOUND";

    NSString *text =
        [NSString stringWithFormat:
            @"BumbleHeatFix\n"
             @"YAP PATH SAMPLER v3.9\n"
             @"\n"
             @"CPU: %.1f%%\n"
             @"Peak CPU: %.1f%%\n"
             @"Hot samples: %lu / %lu\n"
             @"Network: %@\n"
             @"Status: %@\n"
             @"\n"
             @"HOT THREAD\n"
             @"TID: %u\n"
             @"CPU: %.1f%%\n"
             @"Same hot thread: %lu samples\n"
             @"\n"
             @"CURRENT PC\n"
             @"0x%llx\n"
             @"CURRENT IMAGE\n"
             @"%@\n"
             @"IMAGE BASE\n"
             @"0x%llx\n"
             @"IMAGE OFFSET\n"
             @"+0x%llx\n"
             @"\n"
             @"YapDatabase target\n"
             @"%@\n"
             @"\n"
             @"Yap path samples: %lu / %lu\n"
             @"\n"
             @"TARGET STATUS\n"
             @"Read-only observation\n"
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
             foundHotThread ? hotThread : 0,
             foundHotThread ? hotThreadCPU : 0.0,
             (unsigned long)BHFSameHotThreadSamples,
             (unsigned long long)BHFLastPC,
             currentImage,
             (unsigned long long)BHFLastImageBase,
             (unsigned long long)BHFLastImageOffset,
             yapTargetText,
             (unsigned long)BHFYapSamples,
             (unsigned long)BHFTotalSamples];

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
