#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdarg.h>

static void BHFLog(NSString *format, ...)
{
    va_list args;
    va_start(args, format);

    NSString *message =
        [[NSString alloc] initWithFormat:format arguments:args];

    va_end(args);

    NSLog(@"[BumbleHeatFix] %@", message);
}

%ctor
{
    @autoreleasepool
    {
        BHFLog(@"================================");
        BHFLog(@"BumbleHeatFix loaded successfully");
        BHFLog(@"Process: %@", [[NSProcessInfo processInfo] processName]);
        BHFLog(@"iOS: %@", [[UIDevice currentDevice] systemVersion]);
        BHFLog(@"Device: %@", [[UIDevice currentDevice] model]);
        BHFLog(@"================================");

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
            dispatch_get_main_queue(),
            ^{
                BHFLog(@"5-second checkpoint reached");
            }
        );

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
            dispatch_get_main_queue(),
            ^{
                BHFLog(@"15-second checkpoint reached");
            }
        );
    }
}
