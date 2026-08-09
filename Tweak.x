#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

static UILabel *BHFLabel = nil;

static void BHFCreateOverlay(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *targetWindow = nil;

        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *window in scene.windows) {
                    if (window.isKeyWindow) {
                        targetWindow = window;
                        break;
                    }
                }
            }

            if (targetWindow)
                break;
        }

        if (!targetWindow) {
            targetWindow = [UIApplication sharedApplication].keyWindow;
        }

        if (!targetWindow) {
            NSLog(@"[BumbleHeatFix] Could not find application window");
            return;
        }

        UIView *existing = [targetWindow viewWithTag:987654];
        if (existing) {
            return;
        }

        UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(12, 70, 190, 70)];
        panel.tag = 987654;
        panel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.80];
        panel.layer.cornerRadius = 12.0;
        panel.layer.masksToBounds = YES;

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(10, 8, 170, 22)];
        title.text = @"BumbleHeatFix";
        title.textColor = UIColor.whiteColor;
        title.font = [UIFont boldSystemFontOfSize:15.0];

        UILabel *status = [[UILabel alloc] initWithFrame:CGRectMake(10, 32, 170, 25)];
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
