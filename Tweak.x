#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import <mach-o/dyld.h>


#pragma mark - BumbleHeatFix v3.5
#pragma mark - YapDatabase Instruction Inspector
#pragma mark - READ ONLY
#pragma mark - No hooks
#pragma mark - No patches
#pragma mark - No thread changes
#pragma mark - No suspension
#pragma mark - No termination


static UILabel *BHFLabel = nil;
static NSTimer *BHFTimer = nil;

static uintptr_t BHFYapBase = 0;
static uintptr_t BHFTarget = 0;

static NSString *BHFYapPath = nil;

static uint32_t BHFInstructions[8];
static BOOL BHFInstructionRead = NO;


#pragma mark - Window

static UIWindow *BHFGetWindow(void)
{
    if (@available(iOS 13.0, *)) {

        NSSet<UIScene *> *scenes =
            [UIApplication sharedApplication].connectedScenes;

        for (UIScene *scene in scenes) {

            if (scene.activationState !=
                UISceneActivationStateForegroundActive) {
                continue;
            }

            if (![scene isKindOfClass:
                    [UIWindowScene class]]) {
                continue;
            }

            UIWindowScene *sceneWindow =
                (UIWindowScene *)scene;

            for (UIWindow *window
                 in sceneWindow.windows) {

                if (window.isKeyWindow) {
                    return window;
                }
            }
        }
    }

    return nil;
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

            BHFLabel.numberOfLines = 0;

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
                        0.94];

            BHFLabel.layer.cornerRadius = 8.0;
            BHFLabel.layer.masksToBounds = YES;

            BHFLabel.text =
                @"BumbleHeatFix\n"
                 "INSTRUCTION INSPECTOR v3.5\n\n"
                 "Locating YapDatabase...";

            [window addSubview:BHFLabel];
        }
    );
}


static void BHFUpdate(
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
        }
    );
}


#pragma mark - Find YapDatabase

static BOOL BHFFindYapDatabase(void)
{
    uint32_t count =
        _dyld_image_count();


    for (uint32_t i = 0;
         i < count;
         i++) {

        const char *name =
            _dyld_get_image_name(i);

        if (name == NULL) {
            continue;
        }


        NSString *imageName =
            [NSString
                stringWithUTF8String:
                    name];

        if (imageName == nil) {
            continue;
        }


        NSRange match =
            [imageName
                rangeOfString:
                    @"YapDatabase"
                options:
                    NSCaseInsensitiveSearch];


        if (match.location ==
            NSNotFound) {

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


        /*
         * Runtime image address.
         */
        BHFYapBase =
            (uintptr_t)header +
            (uintptr_t)slide;


        /*
         * Target obtained from our verified
         * framework-relative offset.
         */
        BHFTarget =
            BHFYapBase +
            (uintptr_t)0xC7178;


        BHFYapPath =
            imageName;


        return YES;
    }


    return NO;
}


#pragma mark - Instruction Read

static BOOL BHFReadInstructions(void)
{
    if (BHFTarget == 0) {
        return NO;
    }


    /*
     * ARM64 instructions are 4-byte aligned.
     */
    if ((BHFTarget & 0x3) != 0) {
        return NO;
    }


    /*
     * Read only the first eight 32-bit
     * instruction words.
     *
     * No instruction is executed.
     */
    const uint32_t *code =
        (const uint32_t *)
            BHFTarget;


    for (NSUInteger i = 0;
         i < 8;
         i++) {

        BHFInstructions[i] =
            code[i];
    }


    BHFInstructionRead = YES;

    return YES;
}


#pragma mark - Instruction Classification

static NSString *BHFInstructionHint(
    uint32_t instruction
)
{
    /*
     * ARM64 common function prologue:
     *
     * STP X29, X30, [SP, #imm]!
     *
     * Encoding family:
     * 0xA9...
     */
    if ((instruction & 0xFFC00000) ==
        0xA9800000) {

        return @"possible STP prologue";
    }


    /*
     * MOV X29, SP
     */
    if (instruction == 0x910003FD) {

        return @"MOV X29, SP";
    }


    /*
     * RET
     */
    if (instruction == 0xD65F03C0) {

        return @"RET";
    }


    /*
     * NOP
     */
    if (instruction == 0xD503201F) {

        return @"NOP";
    }


    /*
     * Generic ARM64 branch.
     */
    if ((instruction & 0x7C000000) ==
        0x14000000) {

        return @"branch";
    }


    return @"unknown";
}


#pragma mark - Output

static NSString *BHFOutput(void)
{
    if (BHFYapBase == 0) {

        return
            @"BumbleHeatFix\n"
             "INSTRUCTION INSPECTOR v3.5\n\n"
             "STATUS:\n"
             "YapDatabase NOT FOUND\n\n"
             "No modification performed.";
    }


    if (!BHFInstructionRead) {

        return
            [NSString
                stringWithFormat:
                    @"BumbleHeatFix\n"
                     "INSTRUCTION INSPECTOR v3.5\n\n"
                     "STATUS:\n"
                     "TARGET LOCATED\n\n"
                     "IMAGE:\n"
                     "%@\n\n"
                     "YAP BASE:\n"
                     "0x%llx\n\n"
                     "TARGET:\n"
                     "0x%llx\n\n"
                     "OFFSET:\n"
                     "+0xc7178\n\n"
                     "INSTRUCTION READ:\n"
                     "FAILED\n\n"
                     "No modification performed.",

                    BHFYapPath != nil
                        ? BHFYapPath
                        : @"unknown",

                    (unsigned long long)
                        BHFYapBase,

                    (unsigned long long)
                        BHFTarget
            ];
    }


    NSMutableString *text =
        [NSMutableString
            stringWithFormat:
                @"BumbleHeatFix\n"
                 "INSTRUCTION INSPECTOR v3.5\n\n"
                 "STATUS:\n"
                 "TARGET INSPECTED\n\n"
                 "IMAGE:\n"
                 "%@\n\n"
                 "YAP BASE:\n"
                 "0x%llx\n\n"
                 "TARGET:\n"
                 "0x%llx\n\n"
                 "OFFSET:\n"
                 "+0xc7178\n\n"
                 "ARM64 WORDS:\n",

                BHFYapPath != nil
                    ? BHFYapPath
                    : @"unknown",

                (unsigned long long)
                    BHFYapBase,

                (unsigned long long)
                    BHFTarget
        ];


    for (NSUInteger i = 0;
         i < 8;
         i++) {

        NSString *hint =
            BHFInstructionHint(
                BHFInstructions[i]
            );


        [text appendFormat:
            @"\n+0x%02llx  0x%08x  %@",

            (unsigned long long)
                (i * 4),

            BHFInstructions[i],

            hint
        ];
    }


    [text appendString:
        @"\n\n"
         "TARGET STATUS\n"
         "Read-only inspection\n"
         "No hook\n"
         "No patch\n"
         "No priority changes\n"
         "No suspension\n"
         "No termination"];


    return text;
}


#pragma mark - Run

static void BHFInspect(void)
{
    if (BHFYapBase == 0) {

        if (!BHFFindYapDatabase()) {

            BHFUpdate(
                BHFOutput()
            );

            return;
        }
    }


    if (!BHFInstructionRead) {

        BHFReadInstructions();
    }


    BHFUpdate(
        BHFOutput()
    );
}


#pragma mark - Constructor

%ctor
{
    @autoreleasepool {

        NSLog(
            @"[BumbleHeatFix] "
             "INSTRUCTION INSPECTOR v3.5 loaded"
        );


        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                2 * NSEC_PER_SEC
            ),

            dispatch_get_main_queue(),

            ^{

                BHFCreateOverlay();

                BHFInspect();


                /*
                 * Retry only while the framework
                 * hasn't appeared yet.
                 */
                BHFTimer =
                    [NSTimer
                        scheduledTimerWithTimeInterval:
                            2.0

                        repeats:YES

                        block:^(NSTimer *timer) {

                            if (BHFYapBase == 0) {

                                BHFInspect();

                                return;
                            }


                            [timer invalidate];

                            BHFTimer = nil;
                        }];
            }
        );
    }
}
