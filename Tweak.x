#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <mach/thread_act.h>
#import <mach-o/dyld.h>

#pragma mark - BumbleHeatFix v3.6
#pragma mark - CALLER CAPTURE
#pragma mark - READ ONLY

static UILabel *BHFLabel = nil;
static NSTimer *BHFTimer = nil;

static NSString *BHFYapPath = nil;
static uintptr_t BHFYapBase = 0;
static uintptr_t BHFYapTarget = 0;

static thread_t BHFHotThread = MACH_PORT_NULL;
static double BHFHotCPU = 0.0;

#pragma mark - Overlay

static UIWindow *BHFWindow(void)
{
    if (@available(iOS 13.0, *)) {
        NSSet *scenes =
            [UIApplication sharedApplication].connectedScenes;

        for (UIScene *scene in scenes) {
            if (scene.activationState !=
                UISceneActivationStateForegroundActive) {
                continue;
            }

            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }

            UIWindowScene *ws =
                (UIWindowScene *)scene;

            for (UIWindow *window in ws.windows) {
                if (window.isKeyWindow) {
                    return window;
                }
            }
        }
    }

    return nil;
}

static void BHFCreateOverlay(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (BHFLabel != nil) {
            return;
        }

        UIWindow *window = BHFWindow();

        if (window == nil) {
            return;
        }

        BHFLabel =
            [[UILabel alloc]
                initWithFrame:CGRectMake(
                    6,
                    45,
                    410,
                    760
                )];

        BHFLabel.numberOfLines = 0;
        BHFLabel.textAlignment = NSTextAlignmentLeft;

        BHFLabel.font =
            [UIFont monospacedSystemFontOfSize:8.0
                                         weight:UIFontWeightMedium];

        BHFLabel.textColor = UIColor.whiteColor;

        BHFLabel.backgroundColor =
            [UIColor.blackColor colorWithAlphaComponent:0.94];

        BHFLabel.layer.cornerRadius = 8.0;
        BHFLabel.layer.masksToBounds = YES;

        BHFLabel.text =
            @"BumbleHeatFix\n"
             "CALLER CAPTURE v3.6\n\n"
             "Waiting for hot thread...";

        [window addSubview:BHFLabel];
    });
}

static void BHFUpdate(NSString *text)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (BHFLabel == nil) {
            BHFCreateOverlay();
        }

        if (BHFLabel != nil) {
            BHFLabel.text = text;
        }
    });
}

#pragma mark - Find YapDatabase

static BOOL BHFFindYapDatabase(void)
{
    uint32_t count = _dyld_image_count();

    for (uint32_t i = 0; i < count; i++) {

        const char *name =
            _dyld_get_image_name(i);

        if (name == NULL) {
            continue;
        }

        NSString *imageName =
            [NSString stringWithUTF8String:name];

        if (imageName == nil) {
            continue;
        }

        if ([imageName rangeOfString:@"YapDatabase"
                             options:NSCaseInsensitiveSearch].location
            == NSNotFound) {
            continue;
        }

        const struct mach_header_64 *header =
            (const struct mach_header_64 *)
                _dyld_get_image_header(i);

        if (header == NULL) {
            continue;
        }

        intptr_t slide =
            _dyld_get_image_vmaddr_slide(i);

        BHFYapBase =
            (uintptr_t)header +
            (uintptr_t)slide;

        BHFYapPath = imageName;

        /*
         * Previously verified framework-relative
         * location.
         */
        BHFYapTarget =
            BHFYapBase +
            (uintptr_t)0xC7178;

        return YES;
    }

    return NO;
}

#pragma mark - CPU Information

static BOOL BHFGetThreadCPU(
    thread_t thread,
    double *cpu
)
{
    thread_basic_info_data_t info;
    mach_msg_type_number_t count =
        THREAD_BASIC_INFO_COUNT;

    kern_return_t kr =
        thread_info(
            thread,
            THREAD_BASIC_INFO,
            (thread_info_t)&info,
            &count
        );

    if (kr != KERN_SUCCESS) {
        return NO;
    }

    if (info.flags & TH_FLAGS_IDLE) {
        *cpu = 0.0;
        return YES;
    }

    /*
     * This is a diagnostic CPU percentage
     * based on the current thread snapshot.
     */
    *cpu =
        ((double)info.cpu_usage /
         (double)TH_USAGE_SCALE) * 100.0;

    return YES;
}

#pragma mark - Find Hot Thread

static thread_t BHFFindHotThread(
    double *highestCPU
)
{
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t threadCount = 0;

    kern_return_t kr =
        task_threads(
            mach_task_self(),
            &threads,
            &threadCount
        );

    if (kr != KERN_SUCCESS) {
        return MACH_PORT_NULL;
    }

    thread_t hottest =
        MACH_PORT_NULL;

    double hottestCPU = 0.0;

    for (mach_msg_type_number_t i = 0;
         i < threadCount;
         i++) {

        double cpu = 0.0;

        if (!BHFGetThreadCPU(
                threads[i],
                &cpu)) {
            continue;
        }

        if (cpu > hottestCPU) {
            hottestCPU = cpu;
            hottest = threads[i];
        }
    }

    /*
     * We only read thread information.
     * We do not alter the thread.
     */
    for (mach_msg_type_number_t i = 0;
         i < threadCount;
         i++) {

        mach_port_deallocate(
            mach_task_self(),
            threads[i]
        );
    }

    vm_deallocate(
        mach_task_self(),
        (vm_address_t)threads,
        threadCount * sizeof(thread_t)
    );

    *highestCPU = hottestCPU;

    return hottest;
}

#pragma mark - Thread State

static BOOL BHFGetPC(
    thread_t thread,
    uintptr_t *pc
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

    *pc =
        (uintptr_t)
            arm_thread_state64_get_pc(state);

    return YES;
}

#pragma mark - Image Resolver

static NSString *BHFImageForAddress(
    uintptr_t address,
    uintptr_t *baseOut
)
{
    uint32_t count =
        _dyld_image_count();

    for (uint32_t i = 0;
         i < count;
         i++) {

        const struct mach_header *header =
            _dyld_get_image_header(i);

        if (header == NULL) {
            continue;
        }

        intptr_t slide =
            _dyld_get_image_vmaddr_slide(i);

        uintptr_t base =
            (uintptr_t)header +
            (uintptr_t)slide;

        /*
         * We don't know the exact image size
         * here, so use a conservative address
         * neighborhood for identifying the
         * loaded image.
         */
        if (address >= base &&
            address < base + 0x20000000ULL) {

            const char *name =
                _dyld_get_image_name(i);

            if (name == NULL) {
                continue;
            }

            if (baseOut != NULL) {
                *baseOut = base;
            }

            return
                [NSString
                    stringWithUTF8String:name];
        }
    }

    return @"unknown";
}

#pragma mark - Memory Read

static BOOL BHFReadWord(
    uintptr_t address,
    uint32_t *word
)
{
    if (address == 0 ||
        word == NULL) {
        return NO;
    }

    /*
     * We only read a single aligned
     * instruction-sized value.
     */
    if ((address & 0x3) != 0) {
        return NO;
    }

    *word =
        *(volatile uint32_t *)address;

    return YES;
}

#pragma mark - Caller Analysis

static NSString *BHFAnalyze(void)
{
    double cpu = 0.0;

    thread_t hot =
        BHFFindHotThread(&cpu);

    if (hot == MACH_PORT_NULL) {
        return
            @"BumbleHeatFix\n"
             "CALLER CAPTURE v3.6\n\n"
             "STATUS:\n"
             "No readable hot thread.";
    }

    BHFHotThread = hot;
    BHFHotCPU = cpu;

    uintptr_t pc = 0;

    if (!BHFGetPC(hot, &pc)) {
        return
            [NSString stringWithFormat:
                @"BumbleHeatFix\n"
                 "CALLER CAPTURE v3.6\n\n"
                 "HOT THREAD:\n"
                 "CPU: %.1f%%\n\n"
                 "PC: unavailable\n\n"
                 "TARGET STATUS\n"
                 "Observation only\n"
                 "No thread modification",
                cpu];
    }

    uintptr_t imageBase = 0;

    NSString *image =
        BHFImageForAddress(
            pc,
            &imageBase
        );

    uintptr_t imageOffset = 0;

    if (imageBase != 0 &&
        pc >= imageBase) {
        imageOffset =
            pc - imageBase;
    }

    uint32_t word0 = 0;
    uint32_t word1 = 0;
    uint32_t word2 = 0;

    BOOL read0 =
        BHFReadWord(
            pc,
            &word0
        );

    BOOL read1 =
        BHFReadWord(
            pc + 4,
            &word1
        );

    BOOL read2 =
        BHFReadWord(
            pc + 8,
            &word2
        );

    NSMutableString *text =
        [NSMutableString
            stringWithFormat:
                @"BumbleHeatFix\n"
                 "CALLER CAPTURE v3.6\n\n"
                 "HOT THREAD\n"
                 "CPU: %.1f%%\n"
                 "THREAD: %u\n\n"
                 "CURRENT PC:\n"
                 "0x%llx\n\n"
                 "CURRENT IMAGE:\n"
                 "%@\n\n"
                 "IMAGE BASE:\n"
                 "0x%llx\n\n"
                 "IMAGE OFFSET:\n"
                 "+0x%llx\n\n",

                cpu,

                (unsigned int)hot,

                (unsigned long long)pc,

                image,

                (unsigned long long)imageBase,

                (unsigned long long)imageOffset
        ];

    if (BHFYapBase != 0) {

        [text appendFormat:
            @"VERIFIED YAPDATABASE TARGET\n"
             "YAP BASE:\n"
             "0x%llx\n\n"
             "TARGET:\n"
             "0x%llx\n\n"
             "TARGET OFFSET:\n"
             "+0xc7178\n\n",

            (unsigned long long)BHFYapBase,

            (unsigned long long)BHFYapTarget
        ];
    }

    [text appendString:
        @"CURRENT PC INSTRUCTIONS\n"];

    if (read0) {
        [text appendFormat:
            @"+0x00  0x%08x\n",
            word0];
    } else {
        [text appendString:
            @"+0x00  unreadable\n"];
    }

    if (read1) {
        [text appendFormat:
            @"+0x04  0x%08x\n",
            word1];
    } else {
        [text appendString:
            @"+0x04  unreadable\n"];
    }

    if (read2) {
        [text appendFormat:
            @"+0x08  0x%08x\n",
            word2];
    } else {
        [text appendString:
            @"+0x08  unreadable\n"];
    }

    [text appendString:
        @"\nINTERPRETATION\n"
         "Current hot-thread PC captured.\n"
         "This build does not modify execution.\n\n"
         "TARGET STATUS\n"
         "Observation only\n"
         "No hook\n"
         "No patch\n"
         "No priority changes\n"
         "No suspension\n"
         "No termination"];

    return text;
}

#pragma mark - Run

static void BHFRun(void)
{
    if (BHFYapBase == 0) {
        BHFFindYapDatabase();
    }

    BHFUpdate(
        BHFAnalyze()
    );
}

#pragma mark - Constructor

%ctor
{
    @autoreleasepool {

        NSLog(
            @"[BumbleHeatFix] "
             "CALLER CAPTURE v3.6 loaded"
        );

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                2 * NSEC_PER_SEC
            ),
            dispatch_get_main_queue(),
            ^{

                BHFCreateOverlay();

                BHFRun();

                BHFTimer =
                    [NSTimer
                        scheduledTimerWithTimeInterval:
                            3.0
                        repeats:YES
                        block:^(NSTimer *timer) {

                            BHFRun();
                        }];
            }
        );
    }
}
