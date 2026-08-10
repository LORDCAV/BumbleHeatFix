#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <string.h>

static UILabel *BHFLabel = nil;
static NSTimer *BHFUpdateTimer = nil;

static CFTimeInterval BHFPreviousTime = 0.0;
static double BHFPreviousCPUTime = 0.0;

static double BHFPeakCPUPercent = 0.0;
static NSUInteger BHFPeakThreads = 0;
static NSUInteger BHFPeakMemoryMB = 0;

#define BHF_MAX_THREAD_SAMPLES 128
#define BHF_TOP_THREADS 5

typedef struct {
    uint64_t threadID;
    double cpuTime;
} BHFThreadSample;

typedef struct {
    uint64_t threadID;
    double cpuPercent;
} BHFThreadCPU;

static UIWindow *BHFGetWindow(void)
{
    UIWindow *result = nil;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {

            if (scene.activationState != UISceneActivationStateForegroundActive) {
                continue;
            }

            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }

            UIWindowScene *windowScene = (UIWindowScene *)scene;

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

static double BHFProcessCPUTime(void)
{
    task_thread_times_info_data_t taskInfo;
    mach_msg_type_number_t count = TASK_THREAD_TIMES_INFO_COUNT;

    kern_return_t kr = task_info(
        mach_task_self(),
        TASK_THREAD_TIMES_INFO,
        (task_info_t)&taskInfo,
        &count
    );

    if (kr != KERN_SUCCESS) {
        return 0.0;
    }

    uint64_t userTime =
        ((uint64_t)taskInfo.user_time.seconds * 1000000000ULL) +
        ((uint64_t)taskInfo.user_time.microseconds * 1000ULL);

    uint64_t systemTime =
        ((uint64_t)taskInfo.system_time.seconds * 1000000000ULL) +
        ((uint64_t)taskInfo.system_time.microseconds * 1000ULL);

    return (double)(userTime + systemTime) / 1000000000.0;
}

static NSUInteger BHFMemoryMB(void)
{
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;

    kern_return_t kr = task_info(
        mach_task_self(),
        TASK_VM_INFO,
        (task_info_t)&vmInfo,
        &count
    );

    if (kr != KERN_SUCCESS) {
        return 0;
    }

    return (NSUInteger)(
        vmInfo.phys_footprint /
        (1024ULL * 1024ULL)
    );
}

static NSUInteger BHFThreadCount(void)
{
    thread_act_array_t threadList = NULL;
    mach_msg_type_number_t threadCount = 0;

    kern_return_t kr = task_threads(
        mach_task_self(),
        &threadList,
        &threadCount
    );

    if (kr != KERN_SUCCESS) {
        return 0;
    }

    NSUInteger result = (NSUInteger)threadCount;

    if (threadList != NULL) {
        vm_deallocate(
            mach_task_self(),
            (vm_address_t)threadList,
            threadCount * sizeof(thread_t)
        );
    }

    return result;
}

static BOOL BHFGetThreadSamples(
    BHFThreadSample *samples,
    NSUInteger *sampleCount
)
{
    thread_act_array_t threadList = NULL;
    mach_msg_type_number_t threadCount = 0;

    kern_return_t kr = task_threads(
        mach_task_self(),
        &threadList,
        &threadCount
    );

    if (kr != KERN_SUCCESS || threadList == NULL) {
        *sampleCount = 0;
        return NO;
    }

    NSUInteger count =
        MIN(
            (NSUInteger)threadCount,
            (NSUInteger)BHF_MAX_THREAD_SAMPLES
        );

    for (NSUInteger i = 0; i < count; i++) {

        thread_basic_info_data_t threadInfo;
        mach_msg_type_number_t infoCount =
            THREAD_BASIC_INFO_COUNT;

        kr = thread_info(
            threadList[i],
            THREAD_BASIC_INFO,
            (thread_info_t)&threadInfo,
            &infoCount
        );

        if (kr == KERN_SUCCESS) {

            uint64_t cpuTime =
                ((uint64_t)threadInfo.user_time.seconds *
                 1000000000ULL) +
                ((uint64_t)threadInfo.user_time.microseconds *
                 1000ULL);

            cpuTime +=
                ((uint64_t)threadInfo.system_time.seconds *
                 1000000000ULL) +
                ((uint64_t)threadInfo.system_time.microseconds *
                 1000ULL);

            samples[i].threadID =
                (uint64_t)threadList[i];

            samples[i].cpuTime =
                (double)cpuTime / 1000000000.0;
        }
    }

    *sampleCount = count;

    vm_deallocate(
        mach_task_self(),
        (vm_address_t)threadList,
        threadCount * sizeof(thread_t)
    );

    return YES;
}

static void BHFFindTopThreads(
    BHFThreadSample *previous,
    NSUInteger previousCount,
    BHFThreadSample *current,
    NSUInteger currentCount,
    double elapsed,
    BHFThreadCPU *output,
    NSUInteger *outputCount
)
{
    NSUInteger resultCount = 0;

    if (elapsed <= 0.0) {
        *outputCount = 0;
        return;
    }

    for (NSUInteger i = 0; i < currentCount; i++) {

        uint64_t tid =
            current[i].threadID;

        double previousCPU = 0.0;
        BOOL found = NO;

        for (NSUInteger j = 0; j < previousCount; j++) {

            if (previous[j].threadID == tid) {
                previousCPU =
                    previous[j].cpuTime;
                found = YES;
                break;
            }
        }

        if (!found) {
            continue;
        }

        double delta =
            current[i].cpuTime - previousCPU;

        if (delta < 0.0) {
            continue;
        }

        double percent =
            (delta / elapsed) * 100.0;

        if (percent <= 0.0) {
            continue;
        }

        if (resultCount < BHF_TOP_THREADS) {

            output[resultCount].threadID = tid;
            output[resultCount].cpuPercent = percent;
            resultCount++;

        } else {

            NSUInteger lowestIndex = 0;

            for (NSUInteger k = 1;
                 k < BHF_TOP_THREADS;
                 k++) {

                if (output[k].cpuPercent <
                    output[lowestIndex].cpuPercent) {

                    lowestIndex = k;
                }
            }

            if (percent >
                output[lowestIndex].cpuPercent) {

                output[lowestIndex].threadID = tid;
                output[lowestIndex].cpuPercent = percent;
            }
        }
    }

    *outputCount = resultCount;
}

static void BHFSortTopThreads(
    BHFThreadCPU *threads,
    NSUInteger count
)
{
    for (NSUInteger i = 0; i < count; i++) {

        for (NSUInteger j = i + 1;
             j < count;
             j++) {

            if (threads[j].cpuPercent >
                threads[i].cpuPercent) {

                BHFThreadCPU temp =
                    threads[i];

                threads[i] =
                    threads[j];

                threads[j] =
                    temp;
            }
        }
    }
}

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
                        340,
                        285
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
                colorWithAlphaComponent:0.82];

        BHFLabel.layer.cornerRadius = 8.0;
        BHFLabel.layer.masksToBounds = YES;

        BHFLabel.text =
            @"BumbleHeatFix\n"
             "MONITOR v1.1\n\n"
             "CPU: measuring...\n"
             "Threads: measuring...\n"
             "Memory: measuring...\n\n"
             "Top CPU threads:\n"
             "Collecting samples...";

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

static void BHFCollectStats(void)
{
    static BHFThreadSample previousThreads[
        BHF_MAX_THREAD_SAMPLES];

    static NSUInteger previousThreadCount = 0;

    BHFThreadSample currentThreads[
        BHF_MAX_THREAD_SAMPLES];

    NSUInteger currentThreadCount = 0;

    CFTimeInterval currentTime =
        CACurrentMediaTime();

    double currentCPUTime =
        BHFProcessCPUTime();

    double elapsed = 0.0;
    double cpuDelta = 0.0;
    double cpuPercent = 0.0;

    if (BHFPreviousTime > 0.0 &&
        currentTime > BHFPreviousTime &&
        currentCPUTime >= BHFPreviousCPUTime) {

        elapsed =
            currentTime -
            BHFPreviousTime;

        cpuDelta =
            currentCPUTime -
            BHFPreviousCPUTime;

        if (elapsed > 0.0) {
            cpuPercent =
                (cpuDelta / elapsed) * 100.0;
        }
    }

    BHFPreviousCPUTime =
        currentCPUTime;

    BHFPreviousTime =
        currentTime;

    NSUInteger threadCount =
        BHFThreadCount();

    NSUInteger memory =
        BHFMemoryMB();

    if (cpuPercent >
        BHFPeakCPUPercent) {

        BHFPeakCPUPercent =
            cpuPercent;
    }

    if (threadCount >
        BHFPeakThreads) {

        BHFPeakThreads =
            threadCount;
    }

    if (memory >
        BHFPeakMemoryMB) {

        BHFPeakMemoryMB =
            memory;
    }

    BHFThreadCPU topThreads[
        BHF_TOP_THREADS];

    NSUInteger topCount = 0;

    if (BHFGetThreadSamples(
            currentThreads,
            &currentThreadCount)) {

        if (previousThreadCount > 0 &&
            elapsed > 0.0) {

            BHFFindTopThreads(
                previousThreads,
                previousThreadCount,
                currentThreads,
                currentThreadCount,
                elapsed,
                topThreads,
                &topCount
            );

            BHFSortTopThreads(
                topThreads,
                topCount
            );
        }

        memcpy(
            previousThreads,
            currentThreads,
            sizeof(currentThreads)
        );

        previousThreadCount =
            currentThreadCount;
    }

    NSMutableString *threadText =
        [NSMutableString string];

    for (NSUInteger i = 0;
         i < topCount;
         i++) {

        [threadText appendFormat:
            @"%lu. %llu  %.1f%%\n",
            (unsigned long)(i + 1),
            topThreads[i].threadID,
            topThreads[i].cpuPercent
        ];
    }

    if (topCount == 0) {
        [threadText appendString:
            @"Collecting samples..."];
    }

    NSString *output =
        [NSString stringWithFormat:
            @"BumbleHeatFix\n"
             "MONITOR v1.1\n\n"
             "CPU: %.1f%%\n"
             "Peak CPU: %.1f%%\n"
             "Threads: %lu (peak %lu)\n"
             "Memory: %lu MB (peak %lu MB)\n\n"
             "Top CPU threads:\n%@",
             cpuPercent,
             BHFPeakCPUPercent,
             (unsigned long)threadCount,
             (unsigned long)BHFPeakThreads,
             (unsigned long)memory,
             (unsigned long)BHFPeakMemoryMB,
             threadText
        ];

    BHFUpdateOverlay(output);
}

%ctor
{
    @autoreleasepool {

        NSLog(
            @"[BumbleHeatFix] "
             "Monitor v1.1 loaded"
        );

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                2 * NSEC_PER_SEC
            ),
            dispatch_get_main_queue(),
            ^{

                BHFCreateOverlay();

                BHFUpdateTimer =
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
 