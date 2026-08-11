#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/task_info.h>

#pragma mark - BumbleHeatFix v3.3
#pragma mark - YapDatabase Symbol Resolver
#pragma mark - RESOLUTION ONLY
#pragma mark - No hooks
#pragma mark - No thread changes
#pragma mark - No suspension
#pragma mark - No termination


static UILabel *BHFLabel = nil;
static NSTimer *BHFResolveTimer = nil;

static BOOL BHFResolved = NO;
static uintptr_t BHFResolvedAddress = 0;
static uintptr_t BHFImageBase = 0;

static NSString *BHFResolvedImage = nil;
static NSString *BHFResolvedPath = nil;
static NSString *BHFResolvedSymbol = nil;


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

            UIWindowScene *windowScene =
                (UIWindowScene *)scene;

            for (UIWindow *window
                 in windowScene.windows) {

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
                            680
                        )];

            BHFLabel.numberOfLines =
                0;

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

            BHFLabel.layer.cornerRadius =
                8.0;

            BHFLabel.layer.masksToBounds =
                YES;

            BHFLabel.text =
                @"BumbleHeatFix\n"
                 "SYMBOL RESOLVER v3.3\n\n"
                 "Searching for YapRowidSetEnumerate...";

            [window addSubview:BHFLabel];
        }
    );
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
        }
    );
}


#pragma mark - Address Information

static void BHFResolveAddress(
    uintptr_t address
)
{
    BHFResolvedAddress =
        address;

    Dl_info info;

    memset(
        &info,
        0,
        sizeof(info)
    );

    if (dladdr(
            (const void *)address,
            &info)) {

        BHFResolved = YES;

        if (info.dli_fname != NULL) {

            BHFResolvedPath =
                [NSString
                    stringWithUTF8String:
                        info.dli_fname];
        }

        if (info.dli_sname != NULL) {

            BHFResolvedSymbol =
                [NSString
                    stringWithUTF8String:
                        info.dli_sname];
        }

        if (info.dli_fbase != NULL) {

            BHFImageBase =
                (uintptr_t)
                    info.dli_fbase;
        }

        if (BHFResolvedPath == nil) {
            BHFResolvedPath =
                @"unknown";
        }

        if (BHFResolvedSymbol == nil) {
            BHFResolvedSymbol =
                @"<redacted/unknown>";
        }

        if (BHFImageBase != 0 &&
            BHFResolvedAddress >=
                BHFImageBase) {

            BHFResolvedImage =
                [NSString
                    stringWithFormat:
                        @"%@",
                        BHFResolvedPath];
        }

        return;
    }

    BHFResolved = NO;
}


#pragma mark - Symbol Resolver

static void BHFResolveYapDatabase(void)
{
    /*
     * First try the exact symbol name.
     */
    void *symbol =
        dlsym(
            RTLD_DEFAULT,
            "YapRowidSetEnumerate"
        );

    if (symbol != NULL) {

        BHFResolveAddress(
            (uintptr_t)symbol
        );

        return;
    }


    /*
     * Some Mach-O images expose symbols only
     * through their specific handle.
     *
     * Search loaded images for YapDatabase.
     */
    uint32_t imageCount =
        _dyld_image_count();


    for (uint32_t i = 0;
         i < imageCount;
         i++) {

        const char *imageName =
            _dyld_get_image_name(i);

        if (imageName == NULL) {
            continue;
        }

        NSString *name =
            [NSString
                stringWithUTF8String:
                    imageName];

        if (name == nil) {
            continue;
        }


        if ([name
                rangeOfString:
                    @"YapDatabase"
                options:
                    NSCaseInsensitiveSearch]
                .location ==
            NSNotFound) {

            continue;
        }


        void *handle =
            dlopen(
                imageName,
                RTLD_NOW
            );

        if (handle == NULL) {
            continue;
        }


        symbol =
            dlsym(
                handle,
                "YapRowidSetEnumerate"
            );


        if (symbol != NULL) {

            BHFResolveAddress(
                (uintptr_t)symbol
            );

            dlclose(handle);

            return;
        }


        dlclose(handle);
    }


    BHFResolved = NO;
}


#pragma mark - Resolver Output

static NSString *BHFResolverText(void)
{
    if (!BHFResolved) {

        return
            @"BumbleHeatFix\n"
             "SYMBOL RESOLVER v3.3\n\n"
             "TARGET:\n"
             "YapRowidSetEnumerate\n\n"
             "STATUS:\n"
             "NOT RESOLVED\n\n"
             "The symbol was not exposed by "
             "the loaded image.\n\n"
             "No modification performed.";
    }


    uintptr_t offset = 0;

    if (BHFImageBase != 0 &&
        BHFResolvedAddress >=
            BHFImageBase) {

        offset =
            BHFResolvedAddress -
            BHFImageBase;
    }


    return
        [NSString
            stringWithFormat:
                @"BumbleHeatFix\n"
                 "SYMBOL RESOLVER v3.3\n\n"
                 "TARGET:\n"
                 "YapRowidSetEnumerate\n\n"
                 "STATUS:\n"
                 "RESOLVED\n\n"
                 "ADDRESS:\n"
                 "0x%llx\n\n"
                 "IMAGE BASE:\n"
                 "0x%llx\n\n"
                 "OFFSET:\n"
                 "+0x%llx\n\n"
                 "IMAGE:\n"
                 "%@\n\n"
                 "SYMBOL:\n"
                 "%@\n\n"
                 "TARGET STATUS\n"
                 "Resolution only\n"
                 "No hook\n"
                 "No modification\n"
                 "No priority changes\n"
                 "No suspension\n"
                 "No termination",

                (unsigned long long)
                    BHFResolvedAddress,

                (unsigned long long)
                    BHFImageBase,

                (unsigned long long)
                    offset,

                BHFResolvedPath != nil
                    ? BHFResolvedPath
                    : @"unknown",

                BHFResolvedSymbol != nil
                    ? BHFResolvedSymbol
                    : @"<redacted/unknown>"
        ];
}


#pragma mark - Periodic Resolution

static void BHFPerformResolution(void)
{
    BHFResolveYapDatabase();

    BHFUpdateOverlay(
        BHFResolverText()
    );
}


#pragma mark - Constructor

%ctor
{
    @autoreleasepool {

        NSLog(
            @"[BumbleHeatFix] "
             "SYMBOL RESOLVER v3.3 loaded"
        );


        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                2 * NSEC_PER_SEC
            ),

            dispatch_get_main_queue(),

            ^{

                BHFCreateOverlay();


                /*
                 * Resolve once immediately.
                 */
                BHFPerformResolution();


                /*
                 * Retry a few times because the
                 * framework may finish loading
                 * shortly after Bumble launches.
                 */
                __block NSUInteger attempts = 0;


                BHFResolveTimer =
                    [NSTimer
                        scheduledTimerWithTimeInterval:
                            2.0

                        repeats:YES

                        block:^(NSTimer *timer) {

                            attempts++;

                            BHFPerformResolution();


                            /*
                             * Once resolved, we don't
                             * need to keep searching.
                             */
                            if (BHFResolved ||
                                attempts >= 10) {

                                [timer invalidate];

                                BHFResolveTimer =
                                    nil;
                            }
                        }];
            }
        );
    }
}
