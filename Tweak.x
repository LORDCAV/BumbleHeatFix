#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#import <mach/mach.h>
#import <mach/thread_info.h>
#import <mach/thread_act.h>

#include <stdint.h>

static UILabel *BHFLabel = nil;
static NSTimer *BHFMonitorTimer = nil;

static double BHFPreviousCPUTime = 0.0;
static CFTimeInterval BHFPreviousTime = 0.0;

static double BHFCPUPercent = 0.0;
static double BHFPeakCPU = 0.0;

static NSUInteger BHFHotSamples = 0;

#define BHF_HOT_THRESHOLD 85.0
#define BHF_REQUIRED_HOT_SAMPLES 3


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


#pragma mark - Thread Sample

typedef struct {
    thread_t thread;
    double cpu;
    integer_t runState;
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
            info.run_state
        };

        temp[tempCount++] = sample;
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
                        520
                    )];

        BHFLabel.numberOfLines = 0;

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
                colorWithAlphaComponent:0.90];

        BHFLabel.layer.cornerRadius = 8.0;
        BHFLabel.layer.masksToBounds = YES;

        BHFLabel.text =
            @"BumbleHeatFix\n"
             "TARGET MONITOR v2.9.1\n\n"
             "CPU: measuring...\n"
             "Peak: measuring...\n"
             "Governor: OBSERVATION ONLY";

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


    BHFThreadSample samples[6];

    NSUInteger count =
        BHFCollectThreads(
            samples,
            6
        );


    NSUInteger memory =
        BHFMemoryMB();


    if (count > 0 &&
        samples[0].cpu >=
            BHF_HOT_THRESHOLD) {

        BHFHotSamples++;

    } else {

        BHFHotSamples = 0;
    }


    NSMutableString *output =
        [NSMutableString string];


    [output appendFormat:
        @"BumbleHeatFix\n"
         "TARGET MONITOR v2.9.1\n\n"
         "CPU: %.1f%%\n"
         "Peak: %.1f%%\n"
         "Memory: %lu MB\n"
         "Governor: OBSERVATION ONLY\n"
         "Hot samples: %lu\n\n",

        BHFCPUPercent,
        BHFPeakCPU,
        (unsigned long)memory,
        (unsigned long)BHFHotSamples
    ];


    if (count == 0) {

        [output appendString:
            @"No active CPU threads.\n"];

        BHFUpdateOverlay(output);

        return;
    }


    BHFThreadSample hot =
        samples[0];


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


    [output appendString:
        @"\nTARGET STATUS\n"
         "No thread priority changes\n"
         "No thread suspension\n"
         "No thread termination\n"
         "Monitoring only\n\n"];


    [output appendString:
        @"OTHER HOT THREADS\n"];


    for (NSUInteger i = 1;
         i < count;
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


    BHFUpdateOverlay(output);
}


#pragma mark - Constructor

%ctor
{
    @autoreleasepool {

        NSLog(
            @"[BumbleHeatFix] "
             "Target Monitor v2.9.1 loaded"
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
