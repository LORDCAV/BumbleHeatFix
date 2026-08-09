#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

static UILabel *BHFLabel = nil;

static UIWindow *BHFGetActiveWindow(void)
{
    UIApplication *application = [UIApplication sharedApplication];

    for (UIScene *scene in application.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }

        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }

        UIWindowScene *windowScene = (UIWindowScene *)scene;

        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }

        for (UIWindow *window in windowScene.windows) {
            if (!window.hidden && window.alpha > 0.0 && window.windowLevel == UIWindowLevelNormal) {
                return window;
            }
        }
    }

    return nil;
}

static void BHFCreateOverlay(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *targetWindow = BHFGetActiveWindow();

        if (!targetWindow) {
            NSLog(@"[BumbleHeatFix] Could not find active application window");
            return;
        }

        UIView *existing = [targetWindow viewWithTag:987654];

        if (existing) {
            return;
        }

        UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(12.0, 70.0, 190.0, 70.0)];

        panel.tag = 987654;
        panel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.80];
        panel.layer.cornerRadius = 12.0;
        panel.layer.masksToBounds = YES;

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(10.0, 8.0, 170.0, 22.0)];

        title.text = @"BumbleHeatFix";
        title.textColor = UIColor.whiteColor;
        title.font = [UIFont boldSystemFontOfSize:15.0];

        UILabel *status = [[UILabel alloc] initWithFrame:CGRectMake(10.0, 32.0, 170.0, 25.0)];

        status.text = @"Monitor: ACTIVE";
        status.textColor = UIColor.greenColor;
        status.font = [UIFont systemFontOfSize:13.0];

        [panel addSubview:title];
        [panel addSubview:status];

        [targetWindow addSubview:panel];

        BHFLabel = status;

        NSLog(@"[BumbleHeatFix] Overlay created successfully");
    });
}

%ctor
{
    @autoreleasepool {
        NSLog(@"[BumbleHeatFix] =================================");
        NSLog(@"[BumbleHeatFix] Loaded successfully");
        NSLog(@"[BumbleHeatFix] =================================");

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
            dispatch_get_main_queue(),
            ^{
                BHFCreateOverlay();
            }
        );
    }
}
