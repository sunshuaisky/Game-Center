#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Safe dynamic Objective-C bridge for Manic EMU's Citra.framework (3DS).
/// Loads Citra.framework via dlopen at runtime so both iOS Simulator and Device
/// builds compile cleanly without a static link dependency.
@interface GCThreeDSBridge : NSObject

+ (BOOL)isFrameworkAvailable;
+ (nullable instancetype)loadCoreWithError:(NSError * _Nullable * _Nullable)error;

- (void)allocateVulkanLibrary;
- (void)deallocateVulkanLibrary;
- (void)allocateMetalLayer:(CAMetalLayer *)layer size:(CGSize)size isSecondary:(BOOL)isSecondary;
- (void)deallocateMetalLayers;
- (void)insertCartridgeAndBootWithURL:(NSURL *)url advancedMode:(BOOL)advancedMode jitSupport:(BOOL)jitSupport;
- (void)touchBeganAtPoint:(CGPoint)point;
- (void)touchMovedAtPoint:(CGPoint)point;
- (void)touchEnded;
- (void)virtualControllerButtonDown:(NSUInteger)button;
- (void)virtualControllerButtonUp:(NSUInteger)button;
- (void)thumbstickMoved:(NSUInteger)analog x:(float)x y:(float)y;
- (BOOL)isPaused;
- (void)pausePlay:(BOOL)play;
- (void)stop;
- (void)reset;
- (BOOL)running;
- (BOOL)stopped;
- (void)orientationChange:(UIInterfaceOrientation)orientation metalView:(UIView *)metalView;
- (void)setMotionRotation:(NSInteger)rotation;
- (void)updateSettingsWithAdvancedMode:(BOOL)advancedMode;
- (void)setFrameLimit:(uint16_t)limit;

@end

NS_ASSUME_NONNULL_END
