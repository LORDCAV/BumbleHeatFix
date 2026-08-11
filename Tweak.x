#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#import <mach/mach.h>
#import <mach/thread_info.h>
#import <mach/thread_act.h>
#import <mach/arm/thread_status.h>

#import <dlfcn.h>
#import <stdint.h>
#import <string.h>

static UILabel *BHFLabel = nil;
static NSTimer *BHFMonitorTimer = nil;

static double BHFPreviousCPUTime = 0.0;
static CFTimeInterval BHFPreviousTime = 0.0;

static double BHFCPUPercent = 0.0;
static double BHFPeakCPU = 0.0;

#define BHF_MAX_THREADS 5
#define BHF_MAX_STACK_FRAMES 10


#pragma mark - Window

static UIWindow *BHFGetWindow(void)
{
    UIWindow *result = nil;

    if (@available(iOS 13.0, *)) {

        for (UIScene *scene in
             [UIApplication sharedApplication].connectedScenes) {

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

    uint64_t user =
        ((uint64_t)info.user_time.seconds *
         1000000000ULL) +
        ((uint64_t)info.user_time.microseconds *
         1000ULL);

    uint64_t system =
        ((uint64_t)info.system_time.seconds *
         1000000000ULL) +
        ((uint64_t)info.system_time.microseconds *
         1000ULL);

    return
        (double)(user + system) /
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

    integer_t flags;

    integer_t suspendCount;

    uint64_t pc;

    uint64_t fp;

} BHFThreadSample;


#pragma mark - Thread State

static BOOL BHFGetThreadState(
    thread_t thread,
    uint64_t *pcOut,
    uint64_t *fpOut
)
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
        return NO;
    }

    if (pcOut != NULL) {

        *pcOut =
            arm_thread_state64_get_pc(state);
    }

    if (fpOut != NULL) {

        *fpOut =
            arm_thread_state64_get_fp(state);
    }

    return YES;
}


#pragma mark - Run State

static NSString *BHFRunStateName(
    integer_t state
)
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


#pragma mark - Thread Collection

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

        memset(
            &sample,
            0,
            sizeof(sample)
        );


        sample.thread =
            threadList[i];

        sample.cpu =
            cpu;

        sample.runState =
            info.run_state;

        sample.flags =
            info.flags;

        sample.suspendCount =
            info.suspend_count;


        BHFGetThreadState(
            threadList[i],
            &sample.pc,
            &sample.fp
        );


        temp[tempCount++] =
            sample;
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
        threadCount *
        sizeof(thread_t)
    );


    return resultCount;
}


#pragma mark - Symbol Information

static NSString *BHFImageNameForAddress(
    uint64_t address,
    NSString **symbolOut,
    uint64_t *offsetOut
)
{
    if (symbolOut != NULL) {
        *symbolOut = @"unknown";
    }

    if (offsetOut != NULL) {
        *offsetOut = 0;
    }


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
            &info
        ) == 0) {

        return @"unknown";
    }


    NSString *imageName =
        @"unknown";


    if (info.dli_fname != NULL) {

        imageName =
            [NSString
                stringWithUTF8String:
                    info.dli_fname];
    }


    if (symbolOut != NULL &&
        info.dli_sname != NULL) {

        *symbolOut =
            [NSString
                stringWithUTF8String:
                    info.dli_sname];
    }


    if (offsetOut != NULL &&
        info.dli_saddr != NULL) {

        *offsetOut =
            address -
            (uint64_t)(uintptr_t)
                info.dli_saddr;
    }


    return imageName;
}


#pragma mark - Frame Reader

static BOOL BHFReadFrame(
    uint64_t framePointer,
    uint64_t *nextFrame,
    uint64_t *returnAddress
)
{
    if (framePointer == 0 ||
        nextFrame == NULL ||
        returnAddress == NULL) {

        return NO;
    }


    /*
     * ARM64 frame record:
     *
     * +0  previous FP
     * +8  saved LR
     */


    if (framePointer & 0x7) {
        return NO;
    }


    /*
     * Avoid following obviously
     * unreasonable frame pointers.
     */

    if (framePointer < 0x100000000ULL) {
        return NO;
    }


    uint64_t *frame =
        (uint64_t *)(uintptr_t)
            framePointer;


    uint64_t previousFP =
        frame[0];

    uint64_t savedLR =
        frame[1];


    if (previousFP == 0 ||
        savedLR == 0) {

        return NO;
    }


    /*
     * Frame chains normally move
     * toward higher addresses.
     */

    if (previousFP <= framePointer) {
        return NO;
    }


    /*
     * Don't follow a suspiciously
     * huge jump.
     */

    if ((previousFP -
         framePointer) >
        (1024ULL * 1024ULL)) {

        return NO;
    }


    *nextFrame =
        previousFP;

    *returnAddress =
        savedLR;


    return YES;
}


#pragma mark - Stack Collection

static NSUInteger BHFCollectStack(
    BHFThreadSample sample,
    uint64_t *addresses,
    NSUInteger maximum
)
{
    if (addresses == NULL ||
        maximum == 0) {

        return 0;
    }


    NSUInteger count = 0;


    /*
     * Frame zero = current PC.
     */

    if (sample.pc != 0) {

        addresses[count++] =
            sample.pc;
    }


    uint64_t fp =
        sample.fp;


    while (count < maximum) {

        uint64_t nextFP = 0;

        uint64_t returnAddress = 0;


        if (!BHFReadFrame(
                fp,
                &nextFP,
                &returnAddress
            )) {

            break;
        }


        addresses[count++] =
            returnAddress;


        fp =
            nextFP;
    }


    return count;
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
                monospacedSystemFontOfSize:9.0
                weight:UIFontWeightMedium];


        BHFLabel.textColor =
            [UIColor whiteColor];


        BHFLabel.backgroundColor =
            [[UIColor blackColor]
                colorWithAlphaComponent:0.90];


        BHFLabel.layer.cornerRadius =
            8.0;


        BHFLabel.layer.masksToBounds =
            YES;


        BHFLabel.text =
            @"BumbleHeatFix\n"
             "CALLER TARGET v2.6\n\n"
             "CPU: measuring...\n"
             "Peak: measuring...\n"
             "Finding hot thread...";


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


    double currentCPU =
        BHFProcessCPUTime();


    if (BHFPreviousTime > 0.0 &&
        now > BHFPreviousTime &&
        currentCPU >=
            BHFPreviousCPUTime) {

        double elapsed =
            now -
            BHFPreviousTime;


        double delta =
            currentCPU -
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
        currentCPU;


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
         "CALLER TARGET v2.6\n\n"
         "CPU: %.1f%%\n"
         "Peak: %.1f%%\n"
         "Memory: %lu MB\n\n",

        BHFCPUPercent,

        BHFPeakCPU,

        (unsigned long)memory
    ];


    if (count == 0) {

        [output appendString:
            @"No active threads.\n"];

        BHFUpdateOverlay(
            output
        );

        return;
    }


    BHFThreadSample hot =
        samples[0];


    [output appendFormat:
        @"HOT THREAD\n"
         "T%u  %.1f%%  %@\n"
         "PC: 0x%llx\n"
         "FP: 0x%llx\n\n",

        hot.thread,

        hot.cpu,

        BHFRunStateName(
            hot.runState
        ),

        hot.pc,

        hot.fp
    ];


    uint64_t stack[
        BHF_MAX_STACK_FRAMES];


    memset(
        stack,
        0,
        sizeof(stack)
    );


    NSUInteger stackCount =
        BHFCollectStack(
            hot,
            stack,
            BHF_MAX_STACK_FRAMES
        );


    [output appendString:
        @"TARGET STACK\n"];


    if (stackCount == 0) {

        [output appendString:
            @"Unable to read stack.\n"];

    } else {

        for (NSUInteger i = 0;
             i < stackCount;
             i++) {

            NSString *symbol =
                @"unknown";


            uint64_t offset = 0;


            NSString *image =
                BHFImageNameForAddress(
                    stack[i],
                    &symbol,
                    &offset
                );


            NSString *imageName =
                [image lastPathComponent];


            /*
             * For Bumble itself,
             * the useful value is the
             * module-relative offset.
             */

            BOOL isBumble =
                [imageName
                    caseInsensitiveCompare:
                        @"Bumble"] == NSOrderedSame;


            if (isBumble) {

                [output appendFormat:
                    @"#%lu 0x%llx\n"
                     "    BUMBLE + 0x%llx\n"
                     "    %@\n",

                    (unsigned long)i,

                    stack[i],

                    offset,

                    symbol
                ];

            } else {

                [output appendFormat:
                    @"#%lu 0x%llx\n"
                     "    %@ + 0x%llx\n"
                     "    %@\n",

                    (unsigned long)i,

                    stack[i],

                    imageName,

                    offset,

                    symbol
                ];
            }
        }
    }


    /*
     * Other hot threads.
     */

    if (count > 1) {

        [output appendString:
            @"\nOTHER THREADS\n"];


        for (NSUInteger i = 1;
             i < count;
             i++) {

            BHFThreadSample sample =
                samples[i];


            NSString *symbol =
                @"unknown";


            uint64_t offset = 0;


            NSString *image =
                BHFImageNameForAddress(
                    sample.pc,
                    &symbol,
                    &offset
                );


            NSString *imageName =
                [image lastPathComponent];


            [output appendFormat:
                @"%lu. T%u %.1f%% %@\n"
                 "    %@ + 0x%llx\n",

                (unsigned long)(i + 1),

                sample.thread,

                sample.cpu,

                BHFRunStateName(
                    sample.runState
                ),

                imageName,

                offset
            ];
        }
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
             "Caller Target v2.6 loaded"
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
