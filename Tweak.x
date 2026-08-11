#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <mach/thread_policy.h>

static UILabel *BHFLabel = nil;
static NSTimer *BHFMonitorTimer = nil;

static CFTimeInterval BHFStartTime = 0.0;
static CFTimeInterval BHFLastTouchTime = 0.0;
static CFTimeInterval BHFPreviousTime = 0.0;

static double BHFPreviousCPUTime = 0.0;
static double BHFCPUPercent = 0.0;
static double BHFPeakCPUPercent = 0.0;

static BOOL BHFIdleMode = NO;

#define BHF_IDLE_DELAY 15.0
#define BHF_CPU_TRIGGER 70.0
#define BHF_THREAD_TRIGGER 20.0
#define BHF_MAX_TRACKED 32

typedef struct {
    thread_t thread;
    BOOL modified;
} BHFTrackedThread;

static BHFTrackedThread BHFThreads[ BHF_MAX_TRACKED ];
static NSUInteger BHFTrackedCount = 0;

static NSUInteger BHFSuccessfulChanges = 0;
static NSUInteger BHFFailedChanges = 0;


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


#pragma mark - Lower Thread Priority

static BOOL BHFLowerThreadPriority(thread_t thread)
{
    thread_precedence_policy_data_t policy;

    policy.importance = -5;

    kern_return_t kr =
        thread_policy_set(
            thread,
            THREAD_PRECEDENCE_POLICY,
            (thread_policy_t)&policy,
            THREAD_PRECEDENCE_POLICY_COUNT
        );

    return kr == KERN_SUCCESS;
}


#pragma mark - Restore Thread Priority

static BOOL BHFRestoreThreadPriority(thread_t thread)
{
    thread_precedence_policy_data_t policy;

    policy.importance = 0;

    kern_return_t kr =
        thread_policy_set(
            thread,
            THREAD_PRECEDENCE_POLICY,
            (thread_policy_t)&policy,
            THREAD_PRECEDENCE_POLICY_COUNT
        );

    return kr == KERN_SUCCESS;
}


#pragma mark - Restore Modified Threads

static void BHFRestoreThreads(void)
{
    NSUInteger restored = 0;

    for (NSUInteger i = 0;
         i < BHFTrackedCount;
         i++) {

        if (!BHFThreads[i].modified) {
            continue;
        }

        if (BHFThreads[i].thread ==
            MACH_PORT_NULL) {
            continue;
        }

        if (BHFRestoreThreadPriority(
                BHFThreads[i].thread)) {

            restored++;
        }
    }

    NSLog(
        @"[BumbleHeatFix] "
         "Restored %lu thread priorities",
         (unsigned long)restored
    );

    BHFTrackedCount = 0;
}


#pragma mark - Governor

static void BHFApplyGovernor(void)
{
    if (!BHFIdleMode) {
        return;
    }

    if (BHFCPUPercent <
        BHF_CPU_TRIGGER) {

        return;
    }

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

        NSLog(
            @"[BumbleHeatFix] "
             "task_threads failed: %d",
             kr
        );

        return;
    }

    NSUInteger changed = 0;
    NSUInteger failed = 0;


    for (NSUInteger i = 0;
         i < threadCount;
         i++) {

        if (BHFTrackedCount >=
            BHF_MAX_TRACKED) {

            break;
        }

        thread_basic_info_data_t info;

        mach_msg_type_number_t infoCount =
            THREAD_BASIC_INFO_COUNT;

        kr =
            thread_info(
                threadList[i],
                THREAD_BASIC_INFO,
                (thread_info_t)&info,
                &infoCount
            );

        if (kr != KERN_SUCCESS) {
            continue;
        }


        double threadCPU =
            ((double)info.cpu_usage /
             (double)TH_USAGE_SCALE) *
            100.0;


        /*
         * Only touch genuinely busy threads.
         */

        if (threadCPU <
            BHF_THREAD_TRIGGER) {

            continue;
        }


        /*
         * Don't modify the same thread
         * repeatedly.
         */

        BOOL alreadyTracked = NO;

        for (NSUInteger j = 0;
             j < BHFTrackedCount;
             j++) {

            if (BHFThreads[j].thread ==
                threadList[i]) {

                alreadyTracked = YES;
                break;
            }
        }

        if (alreadyTracked) {
            continue;
        }


        /*
         * Attempt mild priority reduction.
         */

        if (BHFLowerThreadPriority(
                threadList[i])) {

            BHFThreads[
                BHFTrackedCount
            ].thread =
                threadList[i];

            BHFThreads[
                BHFTrackedCount
            ].modified =
                YES;

            BHFTrackedCount++;

            changed++;

        } else {

            failed++;
        }
    }


    BHFSuccessfulChanges +=
        changed;

    BHFFailedChanges +=
        failed;


    NSLog(
        @"[BumbleHeatFix] "
         "Governor: "
         "%lu changed, %lu failed",
         (unsigned long)changed,
         (unsigned long)failed
    );


    vm_deallocate(
        mach_task_self(),
        (vm_address_t)threadList,
        threadCount * sizeof(thread_t)
    );
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
                        355,
                        275
                    )];

        BHFLabel.numberOfLines = 0;

        BHFLabel.textAlignment =
            NSTextAlignmentLeft;

        BHFLabel.font =
            [UIFont
                monospacedSystemFontOfSize:11.5
                weight:UIFontWeightMedium];

        BHFLabel.textColor =
            [UIColor whiteColor];

        BHFLabel.backgroundColor =
            [[UIColor blackColor]
                colorWithAlphaComponent:0.84];

        BHFLabel.layer.cornerRadius = 8.0;

        BHFLabel.layer.masksToBounds = YES;

        BHFLabel.text =
            @"BumbleHeatFix\n"
             "EXPERIMENT v2.2\n\n"
             "CPU: measuring...\n"
             "Idle timer: starting...\n"
             "Governor: OFF\n\n"
             "Tracked: 0\n"
             "Successful: 0\n"
             "Failed: 0";

        [window addSubview:BHFLabel];
    });
}


static void BHFUpdateOverlay(NSString *text)
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


#pragma mark - Touch Detection

%hook UIApplication

- (void)sendEvent:(UIEvent *)event
{
    if (event != nil &&
        event.type == UIEventTypeTouches) {

        NSSet *touches =
            [event allTouches];

        if (touches.count > 0) {

            BHFLastTouchTime =
                CACurrentMediaTime();

            if (BHFIdleMode) {

                BHFIdleMode = NO;

                BHFRestoreThreads();

                NSLog(
                    @"[BumbleHeatFix] "
                     "Touch detected - "
                     "governor OFF"
                );
            }
        }
    }

    %orig;
}

%end


#pragma mark - Monitor

static void BHFCollectStats(void)
{
    CFTimeInterval now =
        CACurrentMediaTime();

    double currentCPU =
        BHFProcessCPUTime();


    /*
     * CPU percentage.
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
        BHFPeakCPUPercent) {

        BHFPeakCPUPercent =
            BHFCPUPercent;
    }


    /*
     * Calculate idle duration.
     */

    double idleTime =
        now -
        BHFLastTouchTime;


    /*
     * Enter governor after
     * 15 seconds without touch.
     */

    if (!BHFIdleMode &&
        idleTime >= BHF_IDLE_DELAY) {

        BHFIdleMode = YES;

        NSLog(
            @"[BumbleHeatFix] "
             "GOVERNOR ON"
        );

        NSLog(
            @"[BumbleHeatFix] "
             "CPU at activation: %.1f%%",
             BHFCPUPercent
        );
    }


    /*
     * Apply governor.
     */

    if (BHFIdleMode) {

        BHFApplyGovernor();
    }


    NSUInteger memory =
        BHFMemoryMB();


    NSString *mode;

    if (BHFIdleMode) {

        mode =
            @"GOVERNOR ON";

    } else {

        double remaining =
            MAX(
                0.0,
                BHF_IDLE_DELAY -
                idleTime
            );

        mode =
            [NSString stringWithFormat:
                @"IDLE IN %.0fs",
                remaining
            ];
    }


    NSString *output =
        [NSString stringWithFormat:
            @"BumbleHeatFix\n"
             "EXPERIMENT v2.2\n\n"
             "CPU: %.1f%%\n"
             "Peak CPU: %.1f%%\n"
             "Memory: %lu MB\n\n"
             "Mode: %@\n"
             "Tracked: %lu\n"
             "Successful: %lu\n"
             "Failed: %lu\n\n"
             "Trigger: %.0f%%",
             BHFCPUPercent,
             BHFPeakCPUPercent,
             (unsigned long)memory,
             mode,
             (unsigned long)BHFTrackedCount,
             (unsigned long)BHFSuccessfulChanges,
             (unsigned long)BHFFailedChanges,
             BHF_CPU_TRIGGER
        ];

    BHFUpdateOverlay(output);
}


#pragma mark - Constructor

%ctor
{
    @autoreleasepool {

        NSLog(
            @"[BumbleHeatFix] "
             "Experimental v2.2 loaded"
        );

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                2 * NSEC_PER_SEC
            ),
            dispatch_get_main_queue(),
            ^{

                BHFStartTime =
                    CACurrentMediaTime();

                BHFLastTouchTime =
                    BHFStartTime;

                BHFPreviousTime =
                    BHFStartTime;

                BHFPreviousCPUTime =
                    BHFProcessCPUTime();

                BHFCreateOverlay();

                BHFMonitorTimer =
                    [NSTimer
                        scheduledTimerWithTimeInterval:2.0
                        repeats:YES
                        block:^(NSTimer *timer) {

                    BHFCollectStats();
                }];
            }
        );
    }
}
