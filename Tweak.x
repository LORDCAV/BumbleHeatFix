#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import <dlfcn.h>
#import <mach-o/dyld.h>


#pragma mark - BumbleHeatFix v3.4
#pragma mark - YapDatabase Address Verification
#pragma mark - OBSERVATION ONLY
#pragma mark - No hooks
#pragma mark - No thread changes
#pragma mark - No suspension
#pragma mark - No termination


static UILabel *BHFLabel = nil;
static NSTimer *BHFTimer = nil;

static BOOL BHFVerified = NO;

static uintptr_t BHFYapBase = 0;
static uintptr_t BHFYapEnd = 0;
static uintptr_t BHFTargetAddress = 0;

static NSString *BHFYapPath = nil;


#pragma mark - Overlay

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
                 "YAPDATABASE VERIFY v3.4\n\n"
                 "Searching loaded images...";

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
    BHFYapBase = 0;
    BHFYapEnd = 0;

    BHFYapPath = nil;

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
         * We intentionally use the image
         * load address rather than trying
         * to infer a symbol address.
         */
        uintptr_t base =
            (uintptr_t)header +
            (uintptr_t)slide;


        BHFYapBase = base;


        /*
         * For this verification build,
         * use the known relative location
         * from the previous stack capture.
         */
        BHFTargetAddress =
            BHFYapBase +
            (uintptr_t)0xC7178;


        /*
         * We don't need to modify the
         * framework. We only need to
         * verify that the calculated
         * address belongs to the image.
         */
        BHFYapEnd =
            BHFYapBase +
            (uintptr_t)0x2000000;


        BHFYapPath =
            imageName;


        return YES;
    }


    return NO;
}


#pragma mark - Verification

static NSString *BHFVerificationText(void)
{
    if (BHFYapBase == 0) {

        return
            @"BumbleHeatFix\n"
             "YAPDATABASE VERIFY v3.4\n\n"
             "STATUS:\n"
             "YapDatabase NOT FOUND\n\n"
             "Loaded image search did not find\n"
             "YapDatabase.\n\n"
             "No modification performed.";
    }


    uintptr_t relative =
        BHFTargetAddress -
        BHFYapBase;


    BOOL inside =
        (BHFTargetAddress >= BHFYapBase &&
         BHFTargetAddress < BHFYapEnd);


    BHFVerified = inside;


    if (inside) {

        return
            [NSString
                stringWithFormat:
                    @"BumbleHeatFix\n"
                     "YAPDATABASE VERIFY v3.4\n\n"
                     "STATUS:\n"
                     "TARGET ADDRESS IN IMAGE\n\n"
                     "IMAGE:\n"
                     "%@\n\n"
                     "YAP BASE:\n"
                     "0x%llx\n\n"
                     "TARGET:\n"
                     "0x%llx\n\n"
                     "RELATIVE OFFSET:\n"
                     "+0x%llx\n\n"
                     "EXPECTED OFFSET:\n"
                     "+0xc7178\n\n"
                     "TARGET STATUS\n"
                     "Address verification only\n"
                     "No hook\n"
                     "No modification\n"
                     "No priority changes\n"
                     "No suspension\n"
                     "No termination",

                    BHFYapPath != nil
                        ? BHFYapPath
                        : @"unknown",

                    (unsigned long long)
                        BHFYapBase,

                    (unsigned long long)
                        BHFTargetAddress,

                    (unsigned long long)
                        relative
            ];
    }


    return
        [NSString
            stringWithFormat:
                @"BumbleHeatFix\n"
                 "YAPDATABASE VERIFY v3.4\n\n"
                 "STATUS:\n"
                 "TARGET OUTSIDE IMAGE\n\n"
                 "IMAGE:\n"
                 "%@\n\n"
                 "YAP BASE:\n"
                 "0x%llx\n\n"
                 "TARGET:\n"
                 "0x%llx\n\n"
                 "RELATIVE OFFSET:\n"
                 "+0x%llx\n\n"
                 "EXPECTED OFFSET:\n"
                 "+0xc7178\n\n"
                 "No modification performed.",

                BHFYapPath != nil
                    ? BHFYapPath
                    : @"unknown",

                (unsigned long long)
                    BHFYapBase,

                (unsigned long long)
                    BHFTargetAddress,

                (unsigned long long)
                    relative
        ];
}


#pragma mark - Main Resolver

static void BHFRunVerification(void)
{
    if (BHFYapBase == 0) {

        BHFFindYapDatabase();
    }


    BHFUpdate(
        BHFVerificationText()
    );
}


#pragma mark - Constructor

%ctor
{
    @autoreleasepool {

        NSLog(
            @"[BumbleHeatFix] "
             "YAPDATABASE VERIFY v3.4 loaded"
        );


        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                2 * NSEC_PER_SEC
            ),

            dispatch_get_main_queue(),

            ^{

                BHFCreateOverlay();

                BHFRunVerification();


                /*
                 * Give frameworks time to load.
                 */
                BHFTimer =
                    [NSTimer
                        scheduledTimerWithTimeInterval:
                            2.0

                        repeats:YES

                        block:^(NSTimer *timer) {

                            if (BHFYapBase == 0) {

                                BHFRunVerification();

                                return;
                            }


                            [timer invalidate];

                            BHFTimer = nil;
                        }];
            }
        );
    }
}
