#import <UIKit/UIKit.h>

// The Swift implementation supplies the library controller expected by NX2Apple's ShellMain.
@interface ShellLibrary : NSObject
+ (UIViewController *)makeControllerWithInitialURL:(NSURL *)url;
+ (BOOL)handleOpenURL:(NSURL *)url;
@end
