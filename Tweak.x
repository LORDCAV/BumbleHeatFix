```objc
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#import <mach/mach.h>
#import <mach/thread_info.h>
#import <mach/thread_act.h>
#import <mach/arm/thread_status.h>

#import <dlfcn.h>

#include <stdint.h>

static UILabel *BHFLabel = nil;
static NSTimer *BHFMonitorTimer = nil;

static double BHFPreviousCPUTime = 0.0;
static CFTimeInterval BHFPreviousTime = 0.0;

static double BHFCPUPercent = 0.0;
static double BHFPeakCPU = 0.0;

#define BHF_MAX_THREADS 6


#pragma mark - Window

static UIWindow *BHFGetWindow(void)
{
    UIWindow *result = nil;

    if (@available(iOS 13.0, *)) {

        NSSet<UIScene *> *scenes =
            [UIApplication sharedApplication].connectedScenes;

        for (UIScene *scene in scenes) {

            if (scene.activationState !=
                UISceneActivationStateForegroundActive) {
                continue;
            }

            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }

            UIWindowScene *windowScene =
                (UIWindowScene *)scene;

            for (UIWindow *window in windowScene.windows) {

                if (window.isKeyWindow) {
                    result = window;
                    break;
                }
            }

            if (result != nil) {
                break;
            }
        }
    }

    return result;
}


#pragma mark - Thread State

static NSString *BHFRunStateName(integer_t state)
{
    switch (state) {

        case TH_STATE_RUNNING:
            return @"RUNNING";

        case TH_STATE_WAITING:
            return @"WAITING";

        case TH_STATE_STOPPED:
            return @"STOPPED";

        case TH_STATE_UNINTERRUPTIBLE:
            return @"UNINTERRUPTIBLE";

        case TH_STATE_HALTED:
            return @"HALTED";

        default:
            return @"UNKNOWN";
    }
}


#pragma mark - Process CPU

static double BHFProcessCPUTime(void)
{
    task_thread_times_info_data_t info;

    mach_msg_type_number_t count =
        TASK_THREAD_TIMES_INFO_COUNT;

    kern_return_t kr =
        task_info(
            mach_task_self(),
            TASK_THREAD_TIMES_INFO,
            (task_info_t)&info,
            &count
        );

    if (kr != KERN_SUCCESS) {
        return 0.0;
    }

    uint64_t userTime =
        ((uint64_t)info.user_time.seconds *
         1000000000ULL) +
        ((uint64_t)info.user_time.microseconds *
         1000ULL);

    uint64_t systemTime =
        ((uint64_t)info.system_time.seconds *
         1000000000ULL) +
        ((uint64_t)info.system_time.microseconds *
         1000ULL);

    return
        (double)(userTime + systemTime) /
        1000000000.0;
}


#pragma mark - Memory

static NSUInteger BHFMemoryMB(void)
{
    task_vm_info_data_t info;

    mach_msg_type_number_t count =
        TASK_VM_INFO_COUNT;

    kern_return_t kr =
        task_info(
            mach_task_self(),
            TASK_VM_INFO,
            (task_info_t)&info,
            &count
        );

    if (kr != KERN_SUCCESS) {
        return 0;
    }

    return
        (NSUInteger)(
            info.phys_footprint /
            (1024ULL * 1024ULL)
        );
}


#pragma mark - Thread Sample

typedef struct {
    thread_t thread;
    double cpu;
    integer_t runState;
    uint64_t pc;
} BHFThreadSample;


#pragma mark - Get Thread PC

static BOOL BHFGetThreadPC(
    thread_t thread,
    uint64_t *pcOut
)
{
    if (pcOut == NULL) {
        return NO;
    }

    *pcOut = 0;

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
        return NO;
    }

    *pcOut =
        arm_thread_state64_get_pc(state);

    return YES;
}


#pragma mark - Collect Threads

static NSUInteger BHFCollectThreads(
    BHFThreadSample *samples,
    NSUInteger maximum
)
{
    thread_act_array_t threadList = NULL;
    mach_msg_type_number_t threadCount = 0;

    kern_return_t kr =
        task_threads(
            mach_task_self(),
            &threadList,
            &threadCount
        );

    if (kr != KERN_SUCCESS ||
        threadList == NULL) {
        return 0;
    }

    BHFThreadSample temp[64];

    NSUInteger tempCount = 0;

    for (NSUInteger i = 0;
         i < threadCount &&
         tempCount < 64;
         i++) {

        thread_basic_info_data_t info;

        mach_msg_type_number_t count =
            THREAD_BASIC_INFO_COUNT;

        kr =
            thread_info(
                threadList[i],
                THREAD_BASIC_INFO,
                (thread_info_t)&info,
                &count
            );

        if (kr != KERN_SUCCESS) {
            continue;
        }

        double cpu =
            ((double)info.cpu_usage /
             (double)TH_USAGE_SCALE) *
            100.0;

        if (cpu < 0.1) {
            continue;
        }

        BHFThreadSample sample = {
            threadList[i],
            cpu,
            info.run_state,
            0
        };

        BHFGetThreadPC(
            threadList[i],
            &sample.pc
        );

        temp[tempCount++] = sample;
    }


    /*
     * Sort hottest threads first.
     */

    for (NSUInteger i = 0;
         i < tempCount;
         i++) {

        for (NSUInteger j = i + 1;
             j < tempCount;
             j++) {

            if (temp[j].cpu >
                temp[i].cpu) {

                BHFThreadSample swap =
                    temp[i];

                temp[i] =
                    temp[j];

                temp[j] =
                    swap;
            }
        }
    }


    NSUInteger resultCount =
        MIN(tempCount, maximum);


    for (NSUInteger i = 0;
         i < resultCount;
         i++) {

        samples[i] =
            temp[i];
    }


    vm_deallocate(
        mach_task_self(),
        (vm_address_t)threadList,
        threadCount * sizeof(thread_t)
    );

    return resultCount;
}


#pragma mark - Address Resolver

typedef struct {
    BOOL found;

    NSString *imageName;
    NSString *imagePath;
    NSString *symbolName;

    uint64_t imageBase;
    uint64_t symbolAddress;

    uint64_t imageOffset;
    uint64_t symbolOffset;
} BHFResolvedAddress;


static BHFResolvedAddress
BHFResolveAddress(uint64_t address)
{
    /*
     * Do NOT use memset() here because this
     * structure contains Objective-C objects.
     */

    BHFResolvedAddress result = {
        NO,
        nil,
        nil,
        nil,
        0,
        0,
        0,
        0
    };

    if (address == 0) {
        return result;
    }

    Dl_info info = {0};

    int success =
        dladdr(
            (const void *)(uintptr_t)address,
            &info
        );

    if (!success) {
        return result;
    }

    result.found = YES;


    /*
     * Image path/name
     */

    if (info.dli_fname != NULL) {

        result.imagePath =
            [NSString stringWithUTF8String:
                info.dli_fname];

        if (result.imagePath != nil) {

            result.imageName =
                [result.imagePath lastPathComponent];
        }
    }

    if (result.imageName == nil) {
        result.imageName = @"unknown";
    }


    /*
     * Image base
     */

    if (info.dli_fbase != NULL) {

        result.imageBase =
            (uint64_t)(uintptr_t)
                info.dli_fbase;
    }


    /*
     * Symbol
     */

    if (info.dli_sname != NULL) {

        result.symbolName =
            [NSString stringWithUTF8String:
                info.dli_sname];
    }

    if (result.symbolName == nil) {
        result.symbolName = @"<no symbol>";
    }


    /*
     * Symbol address
     */

    if (info.dli_saddr != NULL) {

        result.symbolAddress =
            (uint64_t)(uintptr_t)
                info.dli_saddr;
    }


    /*
     * Address relative to image
     */

    if (result.imageBase != 0 &&
        address >= result.imageBase) {

        result.imageOffset =
            address -
            result.imageBase;
    }


    /*
     * Address relative to symbol
     */

    if (result.symbolAddress != 0 &&
        address >= result.symbolAddress) {

        result.symbolOffset =
            address -
            result.symbolAddress;
    }

    return result;
}


#pragma mark - Overlay

static void BHFCreateOverlay(void)
{
    dispatch_async(
        dispatch_get_main_queue(),
        ^{

        if (BHFLabel != nil) {
            return;
        }

        UIWindow *window =
            BHFGetWindow();

        if (window == nil) {
            return;
        }

        BHFLabel =
            [[UILabel alloc]
                initWithFrame:
                    CGRectMake(
                        6,
                        45,
                        405,
                        700
                    )];

        BHFLabel.numberOfLines = 0;

        BHFLabel.textAlignment =
            NSTextAlignmentLeft;

        BHFLabel.font =
            [UIFont
                monospacedSystemFontOfSize:9.0
                weight:UIFontWeightMedium];

        BHFLabel.textColor =
            [UIColor whiteColor];

        BHFLabel.backgroundColor =
            [[UIColor blackColor]
                colorWithAlphaComponent:0.90];

        BHFLabel.layer.cornerRadius = 8.0;
        BHFLabel.layer.masksToBounds = YES;

        BHFLabel.text =
            @"BumbleHeatFix\n"
             "SYMBOL RESOLVER v2.8\n\n"
             "CPU: measuring...\n"
             "Peak: measuring...\n"
             "Resolving hottest thread...";

        [window addSubview:BHFLabel];
    });
}


static void BHFUpdateOverlay(
    NSString *text
)
{
    dispatch_async(
        dispatch_get_main_queue(),
        ^{

        if (BHFLabel == nil) {
            BHFCreateOverlay();
        }

        if (BHFLabel != nil) {
            BHFLabel.text = text;
        }
    });
}


#pragma mark - Statistics

static void BHFCollectStats(void)
{
    CFTimeInterval currentTime =
        CACurrentMediaTime();

    double currentCPUTime =
        BHFProcessCPUTime();


    if (BHFPreviousTime > 0.0 &&
        currentTime > BHFPreviousTime &&
        currentCPUTime >= BHFPreviousCPUTime) {

        double elapsed =
            currentTime -
            BHFPreviousTime;

        double delta =
            currentCPUTime -
            BHFPreviousCPUTime;

        if (elapsed > 0.0) {

            BHFCPUPercent =
                (delta / elapsed) *
                100.0;
        }
    }


    BHFPreviousTime =
        currentTime;

    BHFPreviousCPUTime =
        currentCPUTime;


    if (BHFCPUPercent >
        BHFPeakCPU) {

        BHFPeakCPU =
            BHFCPUPercent;
    }


    BHFThreadSample samples[
        BHF_MAX_THREADS];

    NSUInteger count =
        BHFCollectThreads(
            samples,
            BHF_MAX_THREADS
        );

    NSUInteger memory =
        BHFMemoryMB();


    NSMutableString *output =
        [NSMutableString string];


    [output appendFormat:
        @"BumbleHeatFix\n"
         "SYMBOL RESOLVER v2.8\n\n"
         "CPU: %.1f%%\n"
         "Peak: %.1f%%\n"
         "Memory: %lu MB\n\n",

        BHFCPUPercent,
        BHFPeakCPU,
        (unsigned long)memory
    ];


    if (count == 0) {

        [output appendString:
            @"No active CPU threads.\n"];

        BHFUpdateOverlay(output);

        return;
    }


    /*
     * Hottest thread
     */

    BHFThreadSample hot =
        samples[0];

    BHFResolvedAddress resolved =
        BHFResolveAddress(
            hot.pc
        );


    [output appendString:
        @"HOT THREAD\n"];


    [output appendFormat:
        @"T%u %.1f%% %@\n",

        hot.thread,
        hot.cpu,

        BHFRunStateName(
            hot.runState
        )
    ];


    [output appendFormat:
        @"PC: 0x%llx\n",

        hot.pc
    ];


    if (resolved.found) {

        [output appendFormat:
            @"IMAGE: %@\n"
             "BASE: 0x%llx\n"
             "OFFSET: +0x%llx\n",

            resolved.imageName,
            resolved.imageBase,
            resolved.imageOffset
        ];


        [output appendFormat:
            @"SYMBOL: %@\n",

            resolved.symbolName
        ];


        if (resolved.symbolAddress != 0) {

            [output appendFormat:
                @"SYMBOL ADDR: 0x%llx\n"
                 "SYMBOL + OFFSET: +0x%llx\n",

                resolved.symbolAddress,
                resolved.symbolOffset
            ];
        }


        if (resolved.imagePath != nil) {

            [output appendFormat:
                @"PATH:\n%@\n",

                resolved.imagePath
            ];
        }

    }
    else {

        [output appendString:
            @"IMAGE: <unresolved>\n"
             "SYMBOL: <unresolved>\n"];
    }


    [output appendString:
        @"\nOTHER HOT THREADS\n"];


    for (NSUInteger i = 1;
         i < count;
         i++) {

        BHFThreadSample sample =
            samples[i];

        BHFResolvedAddress other =
            BHFResolveAddress(
                sample.pc
            );


        NSString *image =
            other.found
                ? other.imageName
                : @"unknown";

        NSString *symbol =
            other.found
                ? other.symbolName
                : @"<none>";

        uint64_t offset =
            other.found
                ? other.imageOffset
                : 0;


        [output appendFormat:
            @"%lu. T%u %.1f%% %@\n"
             "    %@ + 0x%llx\n"
             "    %@\n",

            (unsigned long)(i + 1),

            sample.thread,
            sample.cpu,

            BHFRunStateName(
                sample.runState
            ),

            image,
            offset,
            symbol
        ];
    }


    BHFUpdateOverlay(output);
}


#pragma mark - Constructor

%ctor
{
    @autoreleasepool {

        NSLog(
            @"[BumbleHeatFix] "
             "Symbol Resolver v2.8 loaded"
        );


        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                2 * NSEC_PER_SEC
            ),

            dispatch_get_main_queue(),

            ^{

                BHFPreviousTime =
                    CACurrentMediaTime();

                BHFPreviousCPUTime =
                    BHFProcessCPUTime();

                BHFCreateOverlay();


                BHFMonitorTimer =
                    [NSTimer
                        scheduledTimerWithTimeInterval:
                            2.0

                        repeats:YES

                        block:^(NSTimer *timer) {

                    BHFCollectStats();

                }];
            }
        );
    }
}
```
