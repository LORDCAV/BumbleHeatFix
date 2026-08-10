
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <pthread.h>

static UIWindow *BHFWindow = nil;
static UILabel *BHFLabel = nil;

static UIWindow *BHFGetWindow(void)
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
            if (window.hidden) {
                continue;
            }

            if (window.alpha <= 0.0) {
                continue;
            }

            if (window.windowLevel != UIWindowLevelNormal) {
                continue;
            }

            return window;
        }
    }

    return nil;
}

static void BHFCreateOverlay(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (BHFWindow != nil) {
            return;
        }

        UIWindow *targetWindow = BHFGetWindow();

        if (targetWindow == nil) {
            return;
        }

        BHFWindow = [[UIWindow alloc]
            initWithFrame:CGRectMake(8.0, 50.0, 300.0, 190.0)];

        BHFWindow.windowLevel = UIWindowLevelAlert + 100.0;
        BHFWindow.backgroundColor =
            [UIColor colorWithWhite:0.0 alpha:0.85];

        BHFWindow.userInteractionEnabled = NO;
        BHFWindow.hidden = NO;

        BHFLabel = [[UILabel alloc]
            initWithFrame:BHFWindow.bounds];

        BHFLabel.numberOfLines = 0;

        BHFLabel.textColor = [UIColor whiteColor];

        BHFLabel.font =
            [UIFont monospacedSystemFontOfSize:11.0
                                        weight:UIFontWeightRegular];

        BHFLabel.textAlignment = NSTextAlignmentLeft;

        BHFLabel.text =
            @"BumbleHeatFix\n"
             "THREAD MONITOR\n"
             "Dylib: LOADED\n"
             "Reading threads...";

        [BHFWindow addSubview:BHFLabel];
    });
}

static NSString *BHFGetThreadName(thread_t thread)
{
    char name[64];

    memset(name, 0, sizeof(name));

    pthread_t pthreadID =
        pthread_from_mach_thread_np(thread);

    if (pthreadID != NULL) {
        int result =
            pthread_getname_np(
                pthreadID,
                name,
                sizeof(name)
            );

        if (result == 0 && name[0] != '\0') {
            return [NSString stringWithUTF8String:name];
        }
    }

    return @"<unnamed>";
}

static void BHFReadThreads(void)
{
    mach_port_t task = mach_task_self();

    thread_act_array_t threads = NULL;

    mach_msg_type_number_t threadCount = 0;

    kern_return_t result =
        task_threads(
            task,
            &threads,
            &threadCount
        );

    if (result != KERN_SUCCESS ||
        threads == NULL ||
        threadCount == 0) {

        BHFUpdateOverlay(
            @"BumbleHeatFix\n"
             "THREAD MONITOR\n"
             "Unable to read threads"
        );

        return;
    }

    NSMutableString *output =
        [NSMutableString stringWithFormat:
            @"BumbleHeatFix\n"
             "THREAD MONITOR\n"
             "Threads: %u\n\n",
             threadCount];

    mach_msg_type_number_t displayed = 0;

    for (mach_msg_type_number_t i = 0;
         i < threadCount && displayed < 8;
         i++) {

        thread_basic_info_data_t info;

        mach_msg_type_number_t infoCount =
            THREAD_BASIC_INFO_COUNT;

        kern_return_t infoResult =
            thread_info(
                threads[i],
                THREAD_BASIC_INFO,
                (thread_info_t)&info,
                &infoCount
            );

        if (infoResult != KERN_SUCCESS) {
            continue;
        }

        NSString *name =
            BHFGetThreadName(threads[i]);

        [output appendFormat:
            @"%u. %@\n",
            displayed + 1,
            name];

        displayed++;
    }

    if (displayed == 0) {
        [output appendString:@"No readable threads"];
    }

    BHFUpdateOverlay(output);

    vm_deallocate(
        mach_task_self(),
        (vm_address_t)threads,
        threadCount * sizeof(thread_t)
    );
}

static void BHFUpdateOverlay(NSString *text)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (BHFLabel != nil) {
            BHFLabel.text = text;
        }
    });
}

%ctor
{
    @autoreleasepool {

        NSLog(
            @"[BumbleHeatFix] Thread monitor loaded"
        );

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                2 * NSEC_PER_SEC
            ),
            dispatch_get_main_queue(),
            ^{
                BHFCreateOverlay();
            }
        );

        dispatch_source_t timer =
            dispatch_source_create(
                DISPATCH_SOURCE_TYPE_TIMER,
                0,
                0,
                dispatch_get_main_queue()
            );

        if (timer != NULL) {

            dispatch_source_set_timer(
                timer,
                dispatch_time(
                    DISPATCH_TIME_NOW,
                    3 * NSEC_PER_SEC
                ),
                1 * NSEC_PER_SEC,
                100 * NSEC_PER_MSEC
            );

            dispatch_source_set_event_handler(
                timer,
                ^{
                    BHFCreateOverlay();
                    BHFReadThreads();
                }
            );

            dispatch_resume(timer);
        }
    }
}
```
