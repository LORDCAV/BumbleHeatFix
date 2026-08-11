#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <mach/thread_info.h>

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

    integer_t sleepTime;

} BHFThreadSample;


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


    BHFThreadSample temp[128];

    NSUInteger tempCount = 0;


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
         * Ignore threads doing
         * practically no CPU work.
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

        temp[tempCount].sleepTime =
            info.sleep_time;

        tempCount++;
    }


    /*
     * Sort threads by CPU usage.
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
                        375,
                        350
                    )];


        BHFLabel.numberOfLines =
            0;


        BHFLabel.textAlignment =
            NSTextAlignmentLeft;


        BHFLabel.font =
            [UIFont
                monospacedSystemFontOfSize:10.5
                weight:UIFontWeightMedium];


        BHFLabel.textColor =
            [UIColor whiteColor];


        BHFLabel.backgroundColor =
            [[UIColor blackColor]
                colorWithAlphaComponent:0.86];


        BHFLabel.layer.cornerRadius =
            8.0;


        BHFLabel.layer.masksToBounds =
            YES;


        BHFLabel.text =
            @"BumbleHeatFix\n"
             "PROFILER v2.3.1\n\n"
             "CPU: measuring...\n"
             "Peak CPU: measuring...\n"
             "State: starting...\n\n"
             "Top CPU threads:\n"
             "Collecting...";


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
    CFTimeInterval now =
        CACurrentMediaTime();


    double currentCPU =
        BHFProcessCPUTime();


    /*
     * Calculate CPU percentage.
     */

    if (BHFPreviousTime > 0.0 &&
        now > BHFPreviousTime &&
        currentCPU >= BHFPreviousCPUTime) {

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
     * Idle state.
     *
     * This profiler intentionally
     * does NOT modify threads.
     */

    static CFTimeInterval idleStart =
        0.0;


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
     * Collect top CPU threads.
     */

    BHFThreadSample samples[
        BHF_MAX_TOP_THREADS];


    NSUInteger count =
        BHFCollectThreads(
            samples,
            BHF_MAX_TOP_THREADS
        );


    NSMutableString *threadText =
        [NSMutableString string];


    for (NSUInteger i = 0;
         i < count;
         i++) {

        BHFThreadSample sample =
            samples[i];


        [threadText appendFormat:
            @"%lu. %u  %.1f%% %@ "
             "S%d F0x%x\n",

            (unsigned long)(i + 1),

            sample.thread,

            sample.cpu,

            BHFRunStateName(
                sample.runState
            ),

            sample.suspendCount,

            sample.flags
        ];
    }


    if (count == 0) {

        [threadText
            appendString:
                @"No active threads\n"];
    }


    NSUInteger memory =
        BHFMemoryMB();


    NSString *state =
        BHFIdle
        ? @"IDLE - PROFILING"
        : @"ACTIVE";


    NSString *output =
        [NSString stringWithFormat:

            @"BumbleHeatFix\n"
             "PROFILER v2.3.1\n\n"

             "CPU: %.1f%%\n"
             "Peak CPU: %.1f%%\n"
             "Memory: %lu MB\n"
             "State: %@\n\n"

             "Top CPU threads:\n"
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


#pragma mark - UIApplication Hook

%hook UIApplication

- (void)sendEvent:(UIEvent *)event
{
    /*
     * This hook is observation-only.
     *
     * We do not alter Bumble's
     * behavior here.
     */

    %orig;
}

%end


#pragma mark - Constructor

%ctor
{
    @autoreleasepool {

        NSLog(
            @"[BumbleHeatFix] "
             "Profiler v2.3.1 loaded"
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
