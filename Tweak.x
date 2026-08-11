#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#import <mach/mach.h>
#import <mach/thread_act.h>
#import <mach/thread_info.h>

#import <dlfcn.h>

static UILabel *BHFLabel = nil;
static NSTimer *BHFMonitorTimer = nil;

static double BHFPreviousCPUTime = 0.0;
static CFTimeInterval BHFPreviousTime = 0.0;

static double BHFCPUPercent = 0.0;
static double BHFPeakCPU = 0.0;

static NSUInteger BHFHotSamples = 0;
static thread_t BHFLastHotThread = MACH_PORT_NULL;


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


#pragma mark - Run State

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


#pragma mark - Resolve PC

static NSString *BHFResolveImage(uint64_t address)
{
    if (address == 0) {
        return @"unknown";
    }

    Dl_info info;

    memset(
        &info,
        0,
        sizeof(info)
    );

    if (dladdr(
            (const void *)(uintptr_t)address,
            &info)) {

        if (info.dli_fname != NULL) {
            return
                [NSString
                    stringWithUTF8String:
                        info.dli_fname];
        }
    }

    return @"unknown";
}


static NSString *BHFResolveSymbol(uint64_t address)
{
    if (address == 0) {
        return @"unknown";
    }

    Dl_info info;

    memset(
        &info,
        0,
        sizeof(info)
    );

    if (dladdr(
            (const void *)(uintptr_t)address,
            &info)) {

        if (info.dli_sname != NULL) {
            return
                [NSString
                    stringWithUTF8String:
                        info.dli_sname];
        }
    }

    return @"unknown";
}


static uint64_t BHFResolveSymbolAddress(
    uint64_t address
)
{
    if (address == 0) {
        return 0;
    }

    Dl_info info;

    memset(
        &info,
        0,
        sizeof(info)
    );

    if (dladdr(
            (const void *)(uintptr_t)address,
            &info)) {

        if (info.dli_saddr != NULL) {
            return
                (uint64_t)(uintptr_t)
                    info.dli_saddr;
        }
    }

    return 0;
}


#pragma mark - Thread PC

static uint64_t BHFThreadPC(
    thread_t thread
)
{
#if defined(__arm64__)

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

    return
        (uint64_t)state.__pc;

#else

    return 0;

#endif
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


        BHFThreadSample sample;

        sample.thread =
            threadList[i];

        sample.cpu =
            cpu;

        sample.runState =
            info.run_state;

        sample.pc =
            BHFThreadPC(
                threadList[i]
            );


        temp[tempCount] =
            sample;

        tempCount++;
    }


    /*
     Sort hottest thread first.
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
        MIN(
            tempCount,
            maximum
        );


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
                        560
                    )];


        BHFLabel.numberOfLines =
            0;


        BHFLabel.textAlignment =
            NSTextAlignmentLeft;


        BHFLabel.font =
            [UIFont
                monospacedSystemFontOfSize:
                    10.0
                weight:
                    UIFontWeightMedium];


        BHFLabel.textColor =
            [UIColor whiteColor];


        BHFLabel.backgroundColor =
            [[UIColor blackColor]
                colorWithAlphaComponent:
                    0.90];


        BHFLabel.layer.cornerRadius =
            8.0;


        BHFLabel.layer.masksToBounds =
            YES;


        BHFLabel.text =
            @"BumbleHeatFix\n"
             "HOT THREAD RESOLVER v3.0\n\n"
             "CPU: measuring...\n"
             "Peak: measuring...\n"
             "Hot thread: searching...\n"
             "PC: searching...\n"
             "Image: searching...\n"
             "Symbol: searching...";


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
            BHFLabel.text =
                text;
        }
    });
}


#pragma mark - Collect Statistics

static void BHFCollectStats(void)
{
    CFTimeInterval currentTime =
        CACurrentMediaTime();


    double currentCPUTime =
        BHFProcessCPUTime();


    if (BHFPreviousTime > 0.0 &&
        currentTime > BHFPreviousTime &&
        currentCPUTime >=
            BHFPreviousCPUTime) {

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


    BHFThreadSample samples[6];


    NSUInteger count =
        BHFCollectThreads(
            samples,
            6
        );


    NSUInteger memory =
        BHFMemoryMB();


    BOOL hot =
        NO;


    if (count > 0 &&
        samples[0].cpu >= 85.0) {

        hot = YES;
    }


    if (hot) {

        BHFHotSamples++;

    } else {

        BHFHotSamples = 0;
    }


    NSMutableString *output =
        [NSMutableString string];


    [output appendFormat:
        @"BumbleHeatFix\n"
         "HOT THREAD RESOLVER v3.0\n\n"
         "CPU: %.1f%%\n"
         "Peak: %.1f%%\n"
         "Memory: %lu MB\n"
         "Hot samples: %lu\n\n",

        BHFCPUPercent,
        BHFPeakCPU,
        (unsigned long)memory,
        (unsigned long)BHFHotSamples
    ];


    if (count == 0) {

        [output appendString:
            @"No active CPU threads.\n"];


        BHFUpdateOverlay(
            output
        );

        return;
    }


    BHFThreadSample hotThread =
        samples[0];


    BHFLastHotThread =
        hotThread.thread;


    NSString *image =
        BHFResolveImage(
            hotThread.pc
        );


    NSString *symbol =
        BHFResolveSymbol(
            hotThread.pc
        );


    uint64_t symbolAddress =
        BHFResolveSymbolAddress(
            hotThread.pc
        );


    uint64_t symbolOffset = 0;


    if (symbolAddress != 0 &&
        hotThread.pc >=
            symbolAddress) {

        symbolOffset =
            hotThread.pc -
            symbolAddress;
    }


    [output appendString:
        @"HOT THREAD\n"];


    [output appendFormat:
        @"T%u %.1f%% %@\n",

        hotThread.thread,
        hotThread.cpu,

        BHFRunStateName(
            hotThread.runState
        )
    ];


    [output appendFormat:
        @"PC: 0x%llx\n",

        (unsigned long long)
            hotThread.pc
    ];


    [output appendFormat:
        @"IMAGE: %@\n",

        image
    ];


    [output appendFormat:
        @"SYMBOL: %@\n",

        symbol
    ];


    if (symbolAddress != 0) {

        [output appendFormat:
            @"SYMBOL OFFSET: +0x%llx\n",

            (unsigned long long)
                symbolOffset
        ];

    } else {

        [output appendString:
            @"SYMBOL OFFSET: unavailable\n"];
    }


    [output appendString:
        @"\n"
         "TARGET STATUS\n"
         "Observation only\n"
         "No priority changes\n"
         "No suspension\n"
         "No termination\n\n"];


    [output appendString:
        @"OTHER HOT THREADS\n"];


    NSUInteger otherCount =
        MIN(count, (NSUInteger)5);


    for (NSUInteger i = 1;
         i < otherCount;
         i++) {

        BHFThreadSample sample =
            samples[i];


        [output appendFormat:
            @"%lu. T%u %.1f%% %@\n",

            (unsigned long)(i + 1),

            sample.thread,
            sample.cpu,

            BHFRunStateName(
                sample.runState
            )
        ];
    }


    BHFUpdateOverlay(
        output
    );
}


#pragma mark - Constructor

%ctor
{
    @autoreleasepool {

        NSLog(
            @"[BumbleHeatFix] "
             "Hot Thread Resolver v3.0 loaded"
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