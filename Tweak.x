#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <mach/task.h>
#import <mach/thread_act.h>
#import <mach/mach_time.h>

static UIWindow *BHFOverlayWindow = nil;
static UILabel *BHFLabel = nil;

#define BHF_MAX_THREADS 128

typedef struct {
    uint32_t tid;
    double cpu;
} BHFThreadUsage;

static uint64_t BHFNow(void)
{
    return mach_absolute_time();
}

static double BHFSecondsFromAbsolute(uint64_t value)
{
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);

    double nanos =
        (double)value *
        (double)timebase.numer /
        (double)timebase.denom;

    return nanos / 1000000000.0;
}

static double BHFThreadCPUPercent(
    thread_t thread,
    uint64_t previousTime,
    uint64_t currentTime,
    uint64_t previousCPU,
    uint64_t currentCPU)
{
    if (previousTime == 0 ||
        currentTime <= previousTime ||
        currentCPU < previousCPU) {
        return 0.0;
    }

    uint64_t elapsedAbsolute =
        currentTime - previousTime;

    uint64_t cpuAbsolute =
        currentCPU - previousCPU;

    double elapsed =
        BHFSecondsFromAbsolute(elapsedAbsolute);

    double cpu =
        BHFSecondsFromAbsolute(cpuAbsolute);

    if (elapsed <= 0.0) {
        return 0.0;
    }

    return (cpu / elapsed) * 100.0;
}

static NSUInteger BHFMemoryMB(void)
{
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;

    kern_return_t kr = task_info(
        mach_task_self(),
        TASK_VM_INFO,
        (task_info_t)&info,
        &count
    );

    if (kr != KERN_SUCCESS) {
        return 0;
    }

    return (NSUInteger)(
        info.phys_footprint /
        (1024ULL * 1024ULL)
    );
}

static NSString *BHFThreadName(thread_t thread)
{
    char name[256];
    memset(name, 0, sizeof(name));

    thread_identifier_info_data_t identifier;
    mach_msg_type_number_t count =
        THREAD_IDENTIFIER_INFO_COUNT;

    kern_return_t kr = thread_info(
        thread,
        THREAD_IDENTIFIER_INFO,
        (thread_info_t)&identifier,
        &count
    );

    if (kr != KERN_SUCCESS) {
        return @"unknown";
    }

    thread_basic_info_data_t basic;
    count = THREAD_BASIC_INFO_COUNT;

    kr = thread_info(
        thread,
        THREAD_BASIC_INFO,
        (thread_info_t)&basic,
        &count
    );

    if (kr != KERN_SUCCESS) {
        return @"unknown";
    }

    if (basic.flags & TH_FLAGS_IDLE) {
        return @"idle";
    }

    return @"unnamed";
}

static void BHFUpdateOverlay(void)
{
    task_t task = mach_task_self();

    thread_act_array_t threads = NULL;
    mach_msg_type_number_t threadCount = 0;

    kern_return_t kr = task_threads(
        task,
        &threads,
        &threadCount
    );

    if (kr != KERN_SUCCESS || threads == NULL) {
        return;
    }

    static uint64_t previousTime = 0;
    static uint64_t previousCPU[BHF_MAX_THREADS];
    static uint32_t previousTID[BHF_MAX_THREADS];

    uint64_t currentTime = BHFNow();

    BHFThreadUsage usage[BHF_MAX_THREADS];
    NSUInteger usageCount = 0;

    for (mach_msg_type_number_t i = 0;
         i < threadCount && i < BHF_MAX_THREADS;
         i++) {

        thread_t thread = threads[i];

        thread_identifier_info_data_t identifier;
        mach_msg_type_number_t identifierCount =
            THREAD_IDENTIFIER_INFO_COUNT;

        kern_return_t identifierResult =
            thread_info(
                thread,
                THREAD_IDENTIFIER_INFO,
                (thread_info_t)&identifier,
                &identifierCount
            );

        if (identifierResult != KERN_SUCCESS) {
            continue;
        }

        uint32_t tid =
            (uint32_t)identifier.thread_id;

        thread_basic_info_data_t basic;
        mach_msg_type_number_t basicCount =
            THREAD_BASIC_INFO_COUNT;

        kern_return_t basicResult =
            thread_info(
                thread,
                THREAD_BASIC_INFO,
                (thread_info_t)&basic,
                &basicCount
            );

        if (basicResult != KERN_SUCCESS) {
            continue;
        }

        uint64_t currentCPU =
            ((uint64_t)basic.user_time.seconds *
             1000000000ULL) +
            ((uint64_t)basic.user_time.microseconds *
             1000ULL) +
            ((uint64_t)basic.system_time.seconds *
             1000000000ULL) +
            ((uint64_t)basic.system_time.microseconds *
             1000ULL);

        double percent = 0.0;

        for (NSUInteger j = 0;
             j < BHF_MAX_THREADS;
             j++) {

            if (previousTID[j] == tid) {

                percent =
                    BHFThreadCPUPercent(
                        thread,
                        previousTime,
                        currentTime,
                        previousCPU[j],
                        currentCPU
                    );

                break;
            }
        }

        if (usageCount < BHF_MAX_THREADS) {
            usage[usageCount].tid = tid;
            usage[usageCount].cpu = percent;
            usageCount++;
        }
    }

    previousTime = currentTime;

    for (mach_msg_type_number_t i = 0;
         i < threadCount && i < BHF_MAX_THREADS;
         i++) {

        thread_t thread = threads[i];

        thread_identifier_info_data_t identifier;
        mach_msg_type_number_t count =
            THREAD_IDENTIFIER_INFO_COUNT;

        if (thread_info(
                thread,
                THREAD_IDENTIFIER_INFO,
                (thread_info_t)&identifier,
                &count) != KERN_SUCCESS) {
            continue;
        }

        thread_basic_info_data_t basic;
        count = THREAD_BASIC_INFO_COUNT;

        if (thread_info(
                thread,
                THREAD_BASIC_INFO,
                (thread_info_t)&basic,
                &count) != KERN_SUCCESS) {
            continue;
        }

        uint64_t currentCPU =
            ((uint64_t)basic.user_time.seconds *
             1000000000ULL) +
            ((uint64_t)basic.user_time.microseconds *
             1000ULL) +
            ((uint64_t)basic.system_time.seconds *
             1000000000ULL) +
            ((uint64_t)basic.system_time.microseconds *
             1000ULL);

        uint32_t tid =
            (uint32_t)identifier.thread_id;

        previousTID[i] = tid;
        previousCPU[i] = currentCPU;
    }

    if (threads != NULL) {
        vm_deallocate(
            task,
            (vm_address_t)threads,
            threadCount * sizeof(thread_t)
        );
    }

    for (NSUInteger i = 0; i < usageCount; i++) {

        for (NSUInteger j = i + 1;
             j < usageCount;
             j++) {

            if (usage[j].cpu > usage[i].cpu) {

                BHFThreadUsage temp =
                    usage[i];

                usage[i] =
                    usage[j];

                usage[j] =
                    temp;
            }
        }
    }

    double totalCPU = 0.0;

    for (NSUInteger i = 0;
         i < usageCount;
         i++) {
        totalCPU += usage[i].cpu;
    }

    NSMutableString *text =
        [NSMutableString string];

    [text appendString:
        @"BumbleHeatFix\n"
         "THREAD MONITOR\n"
         "──────────────\n"];

    [text appendFormat:
        @"Process CPU: %.1f%%\n",
        totalCPU];

    [text appendFormat:
        @"Threads: %u\n",
        threadCount];

    [text appendFormat:
        @"Memory: %lu MB\n\n",
        (unsigned long)BHFMemoryMB()];

    [text appendString:
        @"TOP THREADS\n"];

    NSUInteger topCount =
        MIN((NSUInteger)3, usageCount);

    for (NSUInteger i = 0;
         i < topCount;
         i++) {

        [text appendFormat:
            @"%lu. TID %u  %.1f%%\n",
            (unsigned long)(i + 1),
            usage[i].tid,
            usage[i].cpu];
    }

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            if (BHFLabel != nil) {
                BHFLabel.text = text;
            }
        }
    );
}

static UIWindow *BHFFindWindow(void)
{
    if (@available(iOS 13.0, *)) {

        for (UIScene *scene
             in [UIApplication sharedApplication].connectedScenes) {

            if (![scene isKindOfClass:
                    [UIWindowScene class]]) {
                continue;
            }

            UIWindowScene *windowScene =
                (UIWindowScene *)scene;

            if (windowScene.activationState !=
                    UISceneActivationStateForegroundActive &&
                windowScene.activationState !=
                    UISceneActivationStateForegroundInactive) {
                continue;
            }

            for (UIWindow *window
                 in windowScene.windows) {

                if (window.hidden) {
                    continue;
                }

                if (window.rootViewController == nil) {
                    continue;
                }

                if (window.windowLevel !=
                    UIWindowLevelNormal) {
                    continue;
                }

                return window;
            }
        }
    }

    return nil;
}

static void BHFCreateOverlay(void)
{
    dispatch_async(
        dispatch_get_main_queue(),
        ^{

        if (BHFOverlayWindow != nil) {
            return;
        }

        UIWindow *hostWindow =
            BHFFindWindow();

        if (hostWindow == nil) {
            NSLog(
                @"[BumbleHeatFix] "
                @"Could not find Bumble window"
            );
            return;
        }

        CGRect bounds =
            hostWindow.bounds;

        CGFloat width =
            MIN(270.0,
                bounds.size.width - 20.0);

        BHFOverlayWindow =
            [[UIWindow alloc]
                initWithFrame:
                    CGRectMake(
                        10.0,
                        55.0,
                        width,
                        170.0
                    )];

        BHFOverlayWindow.windowLevel =
            UIWindowLevelAlert + 100.0;

        BHFOverlayWindow.backgroundColor =
            [UIColor colorWithWhite:0.0
                              alpha:0.85];

        BHFOverlayWindow.layer.cornerRadius =
            12.0;

        BHFOverlayWindow.clipsToBounds =
            YES;

        UIViewController *controller =
            [[UIViewController alloc] init];

        BHFOverlayWindow.rootViewController =
            controller;

        BHFLabel =
            [[UILabel alloc]
                initWithFrame:
                    controller.view.bounds];

        BHFLabel.autoresizingMask =
            UIViewAutoresizingFlexibleWidth |
            UIViewAutoresizingFlexibleHeight;

        BHFLabel.textColor =
            [UIColor whiteColor];

        BHFLabel.backgroundColor =
            [UIColor clearColor];

        BHFLabel.font =
            [UIFont monospacedSystemFontOfSize:
                12.0
                weight:UIFontWeightMedium];

        BHFLabel.numberOfLines = 0;

        BHFLabel.textAlignment =
            NSTextAlignmentLeft;

        BHFLabel.text =
            @"BumbleHeatFix\n"
             "THREAD MONITOR\n"
             "Starting...";

        [controller.view addSubview:BHFLabel];

        BHFOverlayWindow.hidden = NO;

        NSLog(
            @"[BumbleHeatFix] "
            @"Thread monitor started"
        );

        [NSTimer scheduledTimerWithTimeInterval:
            1.0
            repeats:YES
            block:^(NSTimer *timer) {
                BHFUpdateOverlay();
            }];
    });
}

%ctor
{
    @autoreleasepool {

        NSString *processName =
            [[NSProcessInfo processInfo]
                processName];

        NSLog(
            @"[BumbleHeatFix] "
            @"DYLIB LOADED: %@",
            processName
        );

        if (![processName.lowercaseString
                containsString:@"bumble"]) {
            return;
        }

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                (int64_t)(2 * NSEC_PER_SEC)
            ),
            dispatch_get_main_queue(),
            ^{
                BHFCreateOverlay();
            }
        );
    }
}
