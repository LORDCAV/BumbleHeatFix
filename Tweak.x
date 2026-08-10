#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static void BHFLog(NSString *format, ...)
{
    va_list args;
    va_start(args, format);

    NSString *message =
        [[NSString alloc] initWithFormat:format arguments:args];

    va_end(args);

    NSLog(@"[BumbleHeatFix] %@", message);
}

static UIWindow *BHFGetWindow(void)
{
    UIApplication *app = [UIApplication sharedApplication];

    if (@available(iOS 13.0, *)) {

        for (UIScene *scene in app.connectedScenes) {

            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }

            UIWindowScene *windowScene =
                (UIWindowScene *)scene;

            if (windowScene.activationState !=
                UISceneActivationStateForegroundActive) {
                continue;
            }

            for (UIWindow *window in windowScene.windows) {

                if (window.isKeyWindow) {
                    return window;
                }
            }

            if (windowScene.windows.count > 0) {
                return windowScene.windows.firstObject;
            }
        }
    }

    return nil;
}

static void BHFShowTestOverlay(void)
{
    UIWindow *window = BHFGetWindow();

    if (!window) {
        BHFLog(@"ERROR: Bumble window not found");
        return;
    }

    BHFLog(@"Bumble window found");

    UIView *old =
        [window viewWithTag:987654];

    if (old) {
        [old removeFromSuperview];
    }

    UIView *panel =
        [[UIView alloc]
            initWithFrame:CGRectMake(15, 55, 280, 150)];

    panel.tag = 987654;

    panel.backgroundColor =
        [[UIColor blackColor]
            colorWithAlphaComponent:0.9];

    panel.layer.cornerRadius = 12.0;

    UILabel *label =
        [[UILabel alloc]
            initWithFrame:CGRectMake(12, 10, 256, 130)];

    label.numberOfLines = 0;

    label.textColor =
        [UIColor whiteColor];

    label.font =
        [UIFont systemFontOfSize:15.0
                          weight:UIFontWeightMedium];

    label.text =
        @"BumbleHeatFix\n"
         "MONITOR TEST\n\n"
         "Dylib: LOADED\n"
         "Overlay: WORKING";

    [panel addSubview:label];

    [window addSubview:panel];

    BHFLog(@"TEST OVERLAY DISPLAYED");
}

%ctor
{
    @autoreleasepool {

        BHFLog(@"================================");
        BHFLog(@"BumbleHeatFix loaded");
        BHFLog(@"Process: %@",
               [[NSProcessInfo processInfo] processName]);
        BHFLog(@"================================");

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                2 * NSEC_PER_SEC
            ),
            dispatch_get_main_queue(),
            ^{
                BHFShowTestOverlay();
            }
        );
    }
}
