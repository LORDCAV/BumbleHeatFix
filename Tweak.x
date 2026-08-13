#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Network/Network.h>

#import <mach/mach.h>
#import <mach/mach_init.h>
#import <mach/mach_vm.h>
#import <mach/thread_info.h>
#import <mach/arm/thread_status.h>

#import <dlfcn.h>

#pragma mark - Configuration

#define BHF_MAX_STACK_FRAMES 8
#define BHF_SAMPLE_INTERVAL 5.0

#pragma mark - UI

static UIWindow *BHFWindow = nil;
static UILabel *BHFLabel = nil;
static NSTimer *BHFTimer = nil;

#pragma mark - Network

static nw_path_monitor_t BHFNetworkMonitor = NULL;

static BOOL BHFNetworkOnline = NO;
static BOOL BHFNetworkExpensive = NO;
static BOOL BHFNetworkConstrained = NO;

#pragma mark - CPU

static double BHFPeakCPU = 0.0;

static NSUInteger BHFHotSamples = 0;
static NSUInteger BHFTotalSamples = 0;

static thread_t BHFLastHotThread = MACH_PORT_NULL;
static NSUInteger BHFSameThreadSamples = 0;

#pragma mark - Current hot thread

static uintptr_t BHFCurrentPC = 0;
static uintptr_t BHFCurrentSP = 0;
static uintptr_t BHFCurrentFP = 0;

static double BHFCurrentThreadCPU = 0.0;

#pragma mark - Current PC resolver

static NSString *BHFCurrentImage = @"unknown";
static NSString *BHFCurrentSymbol = @"unknown";

static uintptr_t BHFCurrentImageBase = 0;
static uintptr_t BHFCurrentImageOffset = 0;

#pragma mark - Stack

static NSUInteger BHFStackCount = 0;

static uintptr_t BHFStackAddresses[BHF_MAX_STACK_FRAMES];
static uintptr_t BHFStackOffsets[BHF_MAX_STACK_FRAMES];

static NSString *BHFStackImages[BHF_MAX_STACK_FRAMES];
static NSString *BHFStackSymbols[BHF_MAX_STACK_FRAMES];

#pragma mark - Source counters

static NSUInteger BHFBumbleSamples = 0;
static NSUInteger BHFYapSamples = 0;
static NSUInteger BHFObjCSamples = 0;
static NSUInteger BHFFoundationSamples = 0;
static NSUInteger BHFCoreFoundationSamples = 0;
static NSUInteger BHFSwiftSamples = 0;
static NSUInteger BHFSystemSamples = 0;
static NSUInteger BHFOtherSamples = 0;

#pragma mark - Network state

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
    BHFNetworkMonitor = nw_path_monitor_create();

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

static BOOL BHFGetHotThread(
    thread_t *resultThread,
    double *resultCPU
)
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

#pragma mark - Address resolver

static void BHFResolveAddress(
    uintptr_t address,
    NSString **image,
    NSString **symbol,
    uintptr_t *base,
    uintptr_t *offset
)
{
    if (image != NULL) {
        *image = @"unknown";
    }

    if (symbol != NULL) {
        *symbol = @"unknown";
    }

    if (base != NULL) {
        *base = 0;
    }

    if (offset != NULL) {
        *offset = 0;
    }

    if (address == 0) {
        return;
    }

    Dl_info info;

    memset(
        &info,
        0,
        sizeof(info)
    );

    int result =
        dladdr(
            (const void *)address,
            &info
        );

    if (result == 0) {
        return;
    }

    uintptr_t imageBase = 0;

    if (info.dli_fbase != NULL) {
        imageBase =
            (uintptr_t)info.dli_fbase;
    }

    if (image != NULL &&
        info.dli_fname != NULL) {

        *image =
            [NSString stringWithUTF8String:
                info.dli_fname];

        if (*image == nil) {
            *image = @"unknown";
        }
    }

    if (symbol != NULL &&
        info.dli_sname != NULL) {

        *symbol =
            [NSString stringWithUTF8String:
                info.dli_sname];

        if (*symbol == nil) {
            *symbol = @"unknown";
        }
    }

    if (base != NULL) {
        *base = imageBase;
    }

    if (offset != NULL &&
        imageBase != 0 &&
        address >= imageBase) {

        *offset =
            address - imageBase;
    }
}

#pragma mark - Source classification

static void BHFClassifyImage(
    NSString *image
)
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

    if ([lower containsString:@"libswift"]) {

        BHFSwiftSamples++;
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

#pragma mark - Stack reset

static void BHFResetStack(void)
{
    BHFStackCount = 0;

    for (NSUInteger i = 0;
         i < BHF_MAX_STACK_FRAMES;
         i++) {

        BHFStackAddresses[i] = 0;
        BHFStackOffsets[i] = 0;

        BHFStackImages[i] = @"unknown";
        BHFStackSymbols[i] = @"unknown";
    }
}

#pragma mark - Read another thread's frame

static BOOL BHFReadFrame(
    uintptr_t address,
    uintptr_t *previousFP,
    uintptr_t *returnAddress
)
{
    if (address == 0) {
        return NO;
    }

    /*
     ARM64 frame records are normally:

     [FP + 0]  = previous frame pointer
     [FP + 8]  = saved link register / return address
    */

    uint64_t frame[2] = {0, 0};

    vm_size_t dataSize =
        sizeof(frame);

    kern_return_t kr =
        vm_read_overwrite(
            mach_task_self(),
            (vm_address_t)address,
            (vm_size_t)sizeof(frame),
            (vm_address_t)frame,
            &dataSize
        );

    if (kr != KERN_SUCCESS) {
        return NO;
    }

    if (dataSize < sizeof(frame)) {
        return NO;
    }

    if (previousFP != NULL) {
        *previousFP =
            (uintptr_t)frame[0];
    }

    if (returnAddress != NULL) {
        *returnAddress =
            (uintptr_t)frame[1];
    }

    return YES;
}

#pragma mark - ARM64 frame walk

static void BHFCollectStack(
    thread_t thread
)
{
    BHFResetStack();

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
        return;
    }

    BHFCurrentPC =
        (uintptr_t)state.__pc;

    BHFCurrentSP =
        (uintptr_t)state.__sp;

    BHFCurrentFP =
        (uintptr_t)state.__fp;

    BHFResolveAddress(
        BHFCurrentPC,
        &BHFCurrentImage,
        &BHFCurrentSymbol,
        &BHFCurrentImageBase,
        &BHFCurrentImageOffset
    );

    BHFClassifyImage(
        BHFCurrentImage
    );

    /*
     Frame #0 is the current PC.
    */

    BHFStackAddresses[0] =
        BHFCurrentPC;

    BHFStackImages[0] =
        BHFCurrentImage;

    BHFStackSymbols[0] =
        BHFCurrentSymbol;

    BHFStackOffsets[0] =
        BHFCurrentImageOffset;

    BHFStackCount = 1;

    /*
     Walk saved frame pointers.

     We deliberately limit this to a small number
     of frames and perform read-only memory access.
    */

    uintptr_t fp =
        BHFCurrentFP;

    uintptr_t previousFP = 0;
    uintptr_t returnAddress = 0;

    for (NSUInteger i = 1;
         i < BHF_MAX_STACK_FRAMES;
         i++) {

        if (fp == 0) {
            break;
        }

        /*
         Basic ARM64 alignment check.
        */

        if ((fp & 0x7) != 0) {
            break;
        }

        if (!BHFReadFrame(
                fp,
                &previousFP,
                &returnAddress
            )) {

            break;
        }

        if (returnAddress == 0) {
            break;
        }

        /*
         Prevent obvious loops.
        */

        if (previousFP == fp) {
            break;
        }

        if (previousFP < fp &&
            (fp - previousFP) > (1024 * 1024)) {

            break;
        }

        if (previousFP > fp &&
            (previousFP - fp) > (1024 * 1024)) {

            break;
        }

        NSString *image = @"unknown";
        NSString *symbol = @"unknown";

        uintptr_t base = 0;
        uintptr_t offset = 0;

        BHFResolveAddress(
            returnAddress,
            &image,
            &symbol,
            &base,
            &offset
        );

        BHFStackAddresses[i] =
            returnAddress;

        BHFStackImages[i] =
            image;

        BHFStackSymbols[i] =
            symbol;

        BHFStackOffsets[i] =
            offset;

        BHFStackCount++;

        /*
         Continue through the previous frame.
        */

        fp = previousFP;
    }
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
                    560.0
                )];

    BHFWindow.windowLevel =
        UIWindowLevelAlert + 100.0;

    BHFWindow.backgroundColor =
        [UIColor colorWithWhite:0.0
                          alpha:0.94];

    BHFWindow.layer.cornerRadius =
        14.0;

    BHFWindow.clipsToBounds = YES;

    UIScrollView *scroll =
        [[UIScrollView alloc]
            initWithFrame:
                BHFWindow.bounds];

    scroll.autoresizingMask =
        UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;

    UILabel *label =
        [[UILabel alloc]
            initWithFrame:
                CGRectMake(
                    12.0,
                    10.0,
                    width - 24.0,
                    1000.0
                )];

    BHFLabel = label;

    BHFLabel.textColor =
        [UIColor whiteColor];

    BHFLabel.font =
        [UIFont monospacedSystemFontOfSize:
            10.0
            weight:UIFontWeightRegular];

    BHFLabel.numberOfLines = 0;

    BHFLabel.textAlignment =
        NSTextAlignmentLeft;

    [scroll addSubview:BHFLabel];

    scroll.contentSize =
        CGSizeMake(
            width,
            1000.0
        );

    [BHFWindow addSubview:scroll];

    BHFWindow.hidden = NO;

    [BHFWindow makeKeyAndVisible];
}

#pragma mark - Stack text

static NSString *BHFStackText(void)
{
    NSMutableString *result =
        [NSMutableString string];

    for (NSUInteger i = 0;
         i < BHFStackCount;
         i++) {

        NSString *image =
            BHFStackImages[i];

        NSString *symbol =
            BHFStackSymbols[i];

        if (image == nil) {
            image = @"unknown";
        }

        if (symbol == nil) {
            symbol = @"unknown";
        }

        NSString *shortImage =
            image;

        /*
         Make system paths easier to read.
        */

        if ([image hasPrefix:@"/usr/lib/"]) {

            shortImage =
                [image substringFromIndex:9];
        }
        else if ([image hasPrefix:@"/System/Library/"]) {

            shortImage =
                [image substringFromIndex:16];
        }

        [result appendFormat:
            @"#%lu %@\n"
             @"   %@\n"
             @"   +0x%llx\n",
             (unsigned long)i,
             symbol,
             shortImage,
             (unsigned long long)
                 BHFStackOffsets[i]
        ];
    }

    return result;
}

#pragma mark - Update

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

        BHFCurrentThreadCPU =
            hotThreadCPU;

        BHFCollectStack(
            hotThread
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

    NSString *stack =
        BHFStackText();

    NSString *text =
        [NSString stringWithFormat:
            @"BumbleHeatFix\n"
             @"ARM64 CALLER TRACKER v6.0\n"
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
             @"CURRENT PC\n"
             @"0x%llx\n"
             @"\n"
             @"CURRENT IMAGE\n"
             @"%@\n"
             @"BASE: 0x%llx\n"
             @"OFFSET: +0x%llx\n"
             @"SYMBOL: %@\n"
             @"\n"
             @"CALL STACK\n"
             @"%@"
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
             (unsigned long long)BHFCurrentPC,
             BHFCurrentImage,
             (unsigned long long)BHFCurrentImageBase,
             (unsigned long long)BHFCurrentImageOffset,
             BHFCurrentSymbol,
             stack
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
                        BHF_SAMPLE_INTERVAL
                        repeats:YES
                        block:^(NSTimer *timer) {

                BHFUpdateOverlay();
            }];

            BHFUpdateOverlay();
        }
    );
}

#pragma mark - Constructor

__attribute__((constructor))
static void BumbleHeatFixInit(void)
{
    @autoreleasepool {

        BHFStartNetworkMonitor();

        BHFStartMonitoring();
    }
}
