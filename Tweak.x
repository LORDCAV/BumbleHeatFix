#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#import <mach/mach.h>
#import <mach/thread_info.h>
#import <mach/thread_act.h>
#import <mach/arm/thread_status.h>

#import <dlfcn.h>

static UILabel *BHFLabel = nil;
static NSTimer *BHFMonitorTimer = nil;

static double BHFPreviousCPUTime = 0.0;
static CFTimeInterval BHFPreviousTime = 0.0;

static double BHFCPUPercent = 0.0;
static double BHFPeakCPU = 0.0;

static BOOL BHFIdle = NO;

#define BHF_IDLE_DELAY 15.0
#define BHF_MAX_TOP_THREADS 5


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


#pragma mark - CPU Time

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

    uint64_t programCounter;

} BHFThreadSample;


#pragma mark - Program Counter

static BOOL BHFGetThreadPC(
    thread_t thread,
    uint64_t *pcOut
)
{
    if (pcOut == NULL) {
        return NO;
    }

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


#pragma mark - Image Information

static NSString *BHFImageForAddress(
    uint64_t address,
    NSString **symbolOut,
    intptr_t *slideOut
)
{
    if (symbolOut != NULL) {
        *symbolOut = @"unknown";
    }

    if (slideOut != NULL) {
        *slideOut = 0;
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


    NSString *image =
        info.dli_fname
        ? [NSString
            stringWithUTF8String:
                info.dli_fname]
        : @"unknown";


    if (symbolOut != NULL &&
        info.dli_sname != NULL) {

        *symbolOut =
            [NSString
                stringWithUTF8String:
                    info.dli_sname];
    }


    if (slideOut != NULL) {

        if (info.dli_fbase != NULL) {

            *slideOut =
                (intptr_t)
                address -
                (intptr_t)
                info.dli_saddr;
        }
    }


    return image;
}


#pragma mark - Thread Collection

static NSUInteger BHFCollectThreads(
    BHFThreadSample *samples,
    NSUInteger maximum
)
{
    thread_act_array_t threadList =
        NULL;

    mach_msg_type_number_t threadCount =
        0;


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


    BHFThreadSample temp[128];

    NSUInteger tempCount =
        0;


    for (NSUInteger i = 0;
         i < threadCount &&
         tempCount < 128;
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


        /*
         * Ignore practically idle threads.
         */

        if (cpu < 0.1) {
            continue;
        }


        temp[tempCount].thread =
            threadList[i];

        temp[tempCount].cpu =
            cpu;

        temp[tempCount].runState =
            info.run_state;

        temp[tempCount].flags =
            info.flags;

        temp[tempCount].suspendCount =
            info.suspend_count;


        uint64_t pc = 0;

        if (BHFGetThreadPC(
                threadList[i],
                &pc
            )) {

            temp[tempCount].programCounter =
                pc;

        } else {

            temp[tempCount].programCounter =
                0;
        }


        tempCount++;
    }


    /*
     * Sort by CPU usage.
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
                        8,
                        50,
                        380,
                        430
                    )];


        BHFLabel.numberOfLines =
            0;


        BHFLabel.textAlignment =
            NSTextAlignmentLeft;


        BHFLabel.font =
            [UIFont
                monospacedSystemFontOfSize:10.0
                weight:UIFontWeightMedium];


        BHFLabel.textColor =
            [UIColor whiteColor];


        BHFLabel.backgroundColor =
            [[UIColor blackColor]
                colorWithAlphaComponent:0.88];


        BHFLabel.layer.cornerRadius =
            8.0;


        BHFLabel.layer.masksToBounds =
            YES;


        BHFLabel.text =
            @"BumbleHeatFix\n"
             "STACK TARGET v2.4\n\n"
             "CPU: measuring...\n"
             "Peak: measuring...\n"
             "State: starting...\n\n"
             "Top CPU thread:\n"
             "Collecting PC...";


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


#pragma mark - Monitor

static void BHFCollectStats(void)
{
    CFTimeInterval now =
        CACurrentMediaTime();


    double currentCPU =
        BHFProcessCPUTime();


    /*
     * Process CPU percentage.
     */

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


    /*
     * Idle timer.
     */

    static CFTimeInterval
        idleStart = 0.0;


    if (idleStart == 0.0) {

        idleStart =
            now;
    }


    double idleTime =
        now -
        idleStart;


    if (idleTime >=
        BHF_IDLE_DELAY) {

        BHFIdle = YES;
    }


    /*
     * Collect threads.
     */

    BHFThreadSample samples[
        BHF_MAX_TOP_THREADS];


    NSUInteger count =
        BHFCollectThreads(
            samples,
            BHF_MAX_TOP_THREADS
        );


    NSUInteger memory =
        BHFMemoryMB();


    NSMutableString *threadText =
        [NSMutableString string];


    for (NSUInteger i = 0;
         i < count;
         i++) {

        BHFThreadSample sample =
            samples[i];


        NSString *symbol =
            @"unknown";


        intptr_t slide =
            0;


        NSString *image =
            BHFImageForAddress(
                sample.programCounter,
                &symbol,
                &slide
            );


        /*
         * Shorten common framework
         * paths to make the overlay
         * readable.
         */

        NSString *imageName =
            [image lastPathComponent];


        [threadText appendFormat:
            @"%lu. T%u %.1f%% %@\n"
             "   PC: 0x%llx\n"
             "   Image: %@\n"
             "   Symbol: %@\n",

            (unsigned long)(i + 1),

            sample.thread,

            sample.cpu,

            BHFRunStateName(
                sample.runState
            ),

            sample.programCounter,

            imageName,

            symbol
        ];
    }


    if (count == 0) {

        [threadText
            appendString:
                @"No active threads\n"];
    }


    NSString *state =
        BHFIdle
        ? @"IDLE - TARGETING"
        : @"ACTIVE";


    NSString *output =
        [NSString stringWithFormat:

            @"BumbleHeatFix\n"
             "STACK TARGET v2.4\n\n"

             "CPU: %.1f%%\n"
             "Peak: %.1f%%\n"
             "Memory: %lu MB\n"
             "State: %@\n\n"

             "TOP THREADS\n"
             "%@",

            BHFCPUPercent,

            BHFPeakCPU,

            (unsigned long)memory,

            state,

            threadText
        ];


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
             "Stack target profiler v2.4 loaded"
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
