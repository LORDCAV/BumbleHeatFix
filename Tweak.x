#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#import <mach/mach.h>
#import <mach/thread_info.h>
#import <mach/thread_act.h>
#import <mach/arm/thread_status.h>

#import <dlfcn.h>
#import <mach-o/dyld.h>

#include <stdint.h>
#include <string.h>

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

    uint64_t pc;

} BHFThreadSample;


#pragma mark - Thread PC

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


        BHFGetThreadPC(
            threadList[i],
            &sample.pc
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


#pragma mark - Image Information

typedef struct {

    BOOL found;

    uint64_t imageBase;

    uint64_t imageEnd;

    const char *imagePath;

} BHFImageInfo;


static BHFImageInfo BHFFindImage(
    uint64_t address
)
{
    BHFImageInfo result;

    memset(
        &result,
        0,
        sizeof(result)
    );


    uint32_t imageCount =
        _dyld_image_count();


    for (uint32_t i = 0;
         i < imageCount;
         i++) {

        const struct mach_header_64 *header =
            (const struct mach_header_64 *)
                _dyld_get_image_header(i);


        if (header == NULL) {
            continue;
        }


        intptr_t slide =
            _dyld_get_image_vmaddr_slide(i);


        const uint8_t *cursor =
            (const uint8_t *)header +
            sizeof(struct mach_header_64);


        for (uint32_t commandIndex = 0;
             commandIndex <
                 header->ncmds;
             commandIndex++) {

            const struct load_command *command =
                (const struct load_command *)
                    cursor;


            if (command->cmd ==
                LC_SEGMENT_64) {

                const struct
                    segment_command_64 *segment =
                    (const struct
                        segment_command_64 *)
                        command;


                uint64_t runtimeStart =
                    ((uint64_t)
                        segment->vmaddr) +
                    (uint64_t)slide;


                uint64_t runtimeEnd =
                    runtimeStart +
                    (uint64_t)
                        segment->vmsize;


                if (address >=
                        runtimeStart &&
                    address <
                        runtimeEnd) {

                    result.found =
                        YES;

                    result.imageBase =
                        runtimeStart;

                    result.imageEnd =
                        runtimeEnd;

                    result.imagePath =
                        _dyld_get_image_name(i);

                    return result;
                }
            }


            cursor +=
                command->cmdsize;
        }
    }


    return result;
}


#pragma mark - Image Name

static NSString *BHFImageName(
    const char *path
)
{
    if (path == NULL) {
        return @"unknown";
    }


    NSString *full =
        [NSString
            stringWithUTF8String:path];


    if (full == nil) {
        return @"unknown";
    }


    return
        [full lastPathComponent];
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
             "IMAGE TARGET v2.7.1\n\n"
             "CPU: measuring...\n"
             "Peak: measuring...\n"
             "Finding hottest thread...";


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
         "IMAGE TARGET v2.7.1\n\n"
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


        BHFUpdateOverlay(
            output
        );

        return;
    }


    BHFThreadSample hot =
        samples[0];


    BHFImageInfo image =
        BHFFindImage(
            hot.pc
        );


    NSString *imageName =
        BHFImageName(
            image.imagePath
        );


    uint64_t offset =
        0;


    if (image.found &&
        hot.pc >=
            image.imageBase) {

        offset =
            hot.pc -
            image.imageBase;
    }


    [output appendFormat:
        @"HOT THREAD\n"
         "T%u  %.1f%%  %@\n"
         "PC: 0x%llx\n"
         "IMAGE: %@\n"
         "BASE: 0x%llx\n"
         "OFFSET: +0x%llx\n\n",

        hot.thread,

        hot.cpu,

        BHFRunStateName(
            hot.runState
        ),

        hot.pc,

        imageName,

        image.imageBase,

        offset
    ];


    if (image.found &&
        image.imagePath != NULL) {

        [output appendFormat:
            @"PATH:\n%@\n\n",

            [NSString
                stringWithUTF8String:
                    image.imagePath]];
    }


    [output appendString:
        @"OTHER HOT THREADS\n"];


    for (NSUInteger i = 1;
         i < count;
         i++) {

        BHFThreadSample sample =
            samples[i];


        BHFImageInfo otherImage =
            BHFFindImage(
                sample.pc
            );


        NSString *otherName =
            BHFImageName(
                otherImage.imagePath
            );


        uint64_t otherOffset =
            0;


        if (otherImage.found &&
            sample.pc >=
                otherImage.imageBase) {

            otherOffset =
                sample.pc -
                otherImage.imageBase;
        }


        [output appendFormat:
            @"%lu. T%u %.1f%% %@\n"
             "    %@ + 0x%llx\n",

            (unsigned long)(i + 1),

            sample.thread,

            sample.cpu,

            BHFRunStateName(
                sample.runState
            ),

            otherName,

            otherOffset
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
             "Image Target v2.7.1 loaded"
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
