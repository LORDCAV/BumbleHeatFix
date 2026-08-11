#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#import <mach/mach.h>
#import <mach/thread_act.h>
#import <mach/thread_info.h>
#import <mach/vm_map.h>

#import <dlfcn.h>
#import <stdint.h>
#import <string.h>

static UILabel *BHFLabel = nil;
static NSTimer *BHFMonitorTimer = nil;

static double BHFPreviousCPUTime = 0.0;
static CFTimeInterval BHFPreviousTime = 0.0;

static double BHFCPUPercent = 0.0;
static double BHFPeakCPU = 0.0;

static NSUInteger BHFHotSamples = 0;

#define BHF_MAX_THREADS 32
#define BHF_MAX_FRAMES 8


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


#pragma mark - CPU

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


#pragma mark - Thread Info

typedef struct {

    thread_t thread;
    double cpu;
    integer_t runState;

} BHFThreadSample;


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

    BHFThreadSample temp[BHF_MAX_THREADS];

    NSUInteger tempCount = 0;


    for (NSUInteger i = 0;
         i < threadCount &&
         tempCount < BHF_MAX_THREADS;
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

        temp[tempCount++] =
            sample;
    }


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
        (vm_size_t)(
            threadCount *
            sizeof(thread_t)
        )
    );


    return resultCount;
}


#pragma mark - Address Resolver

static NSString *BHFImageForAddress(
    uintptr_t address
)
{
    Dl_info info;

    memset(
        &info,
        0,
        sizeof(info)
    );

    if (dladdr(
            (const void *)address,
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


static NSString *BHFSymbolForAddress(
    uintptr_t address
)
{
    Dl_info info;

    memset(
        &info,
        0,
        sizeof(info)
    );

    if (dladdr(
            (const void *)address,
            &info)) {

        if (info.dli_sname != NULL) {

            return
                [NSString
                    stringWithUTF8String:
                        info.dli_sname];
        }
    }

    return @"<redacted/unknown>";
}


static uintptr_t BHFImageBaseForAddress(
    uintptr_t address
)
{
    Dl_info info;

    memset(
        &info,
        0,
        sizeof(info)
    );

    if (dladdr(
            (const void *)address,
            &info)) {

        if (info.dli_fbase != NULL) {

            return
                (uintptr_t)info.dli_fbase;
        }
    }

    return 0;
}


#pragma mark - Thread Registers

typedef struct {

    uint64_t pc;
    uint64_t sp;
    uint64_t fp;

    BOOL valid;

} BHFThreadRegisters;


static BHFThreadRegisters
BHFGetThreadRegisters(thread_t thread)
{
    BHFThreadRegisters result;

    result.pc = 0;
    result.sp = 0;
    result.fp = 0;
    result.valid = NO;


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
        return result;
    }

    result.pc =
        state.__pc;

    result.sp =
        state.__sp;

    result.fp =
        state.__fp;

    result.valid = YES;

#endif


    return result;
}


#pragma mark - Safe Pointer Read

static BOOL BHFReadPointer(
    uintptr_t address,
    uintptr_t *value
)
{
    if (address == 0 ||
        value == NULL) {

        return NO;
    }


    vm_size_t outputSize =
        (vm_size_t)sizeof(uintptr_t);


    kern_return_t kr =
        vm_read_overwrite(
            mach_task_self(),

            (vm_address_t)address,

            (vm_size_t)sizeof(uintptr_t),

            (vm_address_t)value,

            &outputSize
        );


    if (kr != KERN_SUCCESS) {
        return NO;
    }


    if (outputSize !=
        (vm_size_t)sizeof(uintptr_t)) {

        return NO;
    }


    return YES;
}


#pragma mark - Stack Walker

static NSArray<NSString *> *
BHFResolveThreadStack(
    thread_t thread
)
{
    BHFThreadRegisters regs =
        BHFGetThreadRegisters(
            thread
        );


    if (!regs.valid) {

        return @[
            @"Unable to obtain ARM64 registers."
        ];
    }


    NSMutableArray<NSString *> *frames =
        [NSMutableArray array];


    [frames addObject:
        [NSString
            stringWithFormat:
                @"PC: 0x%llx",

                (unsigned long long)
                    regs.pc
        ]
    ];


    [frames addObject:
        [NSString
            stringWithFormat:
                @"SP: 0x%llx",

                (unsigned long long)
                    regs.sp
        ]
    ];


    [frames addObject:
        [NSString
            stringWithFormat:
                @"FP: 0x%llx",

                (unsigned long long)
                    regs.fp
        ]
    ];


#if defined(__arm64__)

    uintptr_t currentFP =
        (uintptr_t)regs.fp;


    for (NSUInteger i = 0;
         i < BHF_MAX_FRAMES;
         i++) {

        if (currentFP == 0) {
            break;
        }


        if ((currentFP &
             0x7) != 0) {

            break;
        }


        uintptr_t previousFP = 0;
        uintptr_t returnAddress = 0;


        if (!BHFReadPointer(
                currentFP,
                &previousFP)) {

            break;
        }


        if (!BHFReadPointer(
                currentFP +
                sizeof(uintptr_t),
                &returnAddress)) {

            break;
        }


        if (returnAddress == 0) {
            break;
        }


        NSString *image =
            BHFImageForAddress(
                returnAddress
            );


        NSString *symbol =
            BHFSymbolForAddress(
                returnAddress
            );


        uintptr_t base =
            BHFImageBaseForAddress(
                returnAddress
            );


        uintptr_t offset = 0;


        if (base != 0 &&
            returnAddress >= base) {

            offset =
                returnAddress -
                base;
        }


        NSString *frame =
            [NSString
                stringWithFormat:
                    @"#%lu 0x%llx\n"
                     "IMAGE: %@\n"
                     "OFFSET: +0x%lx\n"
                     "SYMBOL: %@",

                    (unsigned long)(i + 1),

                    (unsigned long long)
                        returnAddress,

                    image,

                    (unsigned long)offset,

                    symbol
            ];


        [frames addObject:
            frame
        ];


        if (previousFP <= currentFP) {
            break;
        }


        if ((previousFP -
             currentFP) >
            (1024ULL * 1024ULL)) {

            break;
        }


        currentFP =
            previousFP;
    }

#endif


    return frames;
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


        BHFLabel.numberOfLines =
            0;


        BHFLabel.textAlignment =
            NSTextAlignmentLeft;


        BHFLabel.font =
            [UIFont
                monospacedSystemFontOfSize:
                    8.5
                weight:
                    UIFontWeightMedium];


        BHFLabel.textColor =
            [UIColor whiteColor];


        BHFLabel.backgroundColor =
            [[UIColor blackColor]
                colorWithAlphaComponent:
                    0.93];


        BHFLabel.layer.cornerRadius =
            8.0;


        BHFLabel.layer.masksToBounds =
            YES;


        BHFLabel.text =
            @"BumbleHeatFix\n"
             "CALL STACK v3.2\n\n"
             "Waiting for CPU sample...";


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


#pragma mark - Statistics

static void BHFCollectStats(void)
{
    CFTimeInterval now =
        CACurrentMediaTime();


    double cpuTime =
        BHFProcessCPUTime();


    if (BHFPreviousTime > 0.0 &&
        now > BHFPreviousTime &&
        cpuTime >=
            BHFPreviousCPUTime) {

        double elapsed =
            now -
            BHFPreviousTime;


        double delta =
            cpuTime -
            BHFPreviousCPUTime;


        if (elapsed > 0.0) {

            BHFCPUPercent =
                (delta / elapsed) *
                100.0;
        }
    }


    BHFPreviousTime =
        now;


    BHFPreviousCPUTime =
        cpuTime;


    if (BHFCPUPercent >
        BHFPeakCPU) {

        BHFPeakCPU =
            BHFCPUPercent;
    }


    BHFThreadSample samples[8];


    NSUInteger count =
        BHFCollectThreads(
            samples,
            8
        );


    NSUInteger memory =
        BHFMemoryMB();


    if (count == 0) {

        BHFUpdateOverlay(
            [NSString
                stringWithFormat:
                    @"BumbleHeatFix\n"
                     "CALL STACK v3.2\n\n"
                     "CPU: %.1f%%\n"
                     "Peak: %.1f%%\n"
                     "Memory: %lu MB\n\n"
                     "No active CPU threads.",

                    BHFCPUPercent,

                    BHFPeakCPU,

                    (unsigned long)memory
            ]
        );

        return;
    }


    BHFThreadSample hot =
        samples[0];


    if (hot.cpu >= 85.0) {
        BHFHotSamples++;
    } else {
        BHFHotSamples = 0;
    }


    NSArray<NSString *> *stack =
        BHFResolveThreadStack(
            hot.thread
        );


    NSMutableString *output =
        [NSMutableString string];


    [output appendFormat:
        @"BumbleHeatFix\n"
         "CALL STACK v3.2\n\n"
         "CPU: %.1f%%\n"
         "Peak: %.1f%%\n"
         "Memory: %lu MB\n"
         "Hot samples: %lu\n\n",

        BHFCPUPercent,

        BHFPeakCPU,

        (unsigned long)memory,

        (unsigned long)BHFHotSamples
    ];


    [output appendFormat:
        @"HOT THREAD\n"
         "T%u %.1f%% %@\n\n",

        hot.thread,

        hot.cpu,

        BHFRunStateName(
            hot.runState
        )
    ];


    [output appendString:
        @"REGISTERS / CALLERS\n"];


    for (NSString *frame in stack) {

        [output appendFormat:
            @"%@\n",

            frame
        ];
    }


    [output appendString:
        @"\nOTHER HOT THREADS\n"];


    NSUInteger otherCount =
        MIN(
            count,
            (NSUInteger)8
        );


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


    [output appendString:
        @"\nTARGET STATUS\n"
         "Observation only\n"
         "No priority changes\n"
         "No suspension\n"
         "No termination"];


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
             "CALL STACK v3.2 loaded"
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
