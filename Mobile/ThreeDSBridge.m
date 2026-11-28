#import "ThreeDSBridge.h"
#include <dlfcn.h>

@protocol GCCitraCoreABI <NSObject>
@optional
+ (id)shared;
- (void)allocateVulkanLibrary;
- (void)deallocateVulkanLibrary;
- (void)allocateMetalLayer:(CAMetalLayer *)layer withSize:(CGSize)size isSecondary:(BOOL)isSecondary;
- (void)deallocateMetalLayers;
- (void)insertCartridgeAndBootWithURL:(NSURL *)url advancedMode:(BOOL)advancedMode jitSupport:(BOOL)jitSupport;
- (void)insertCartridgeAndBoot:(NSURL *)url advancedMode:(BOOL)advancedMode jitSupport:(BOOL)jitSupport;
- (void)touchBeganAtPoint:(CGPoint)point;
- (void)touchMovedAtPoint:(CGPoint)point;
- (void)touchEnded;
- (void)virtualControllerButtonDown:(NSUInteger)button;
- (void)virtualControllerButtonUp:(NSUInteger)button;
- (void)thumbstickMoved:(NSUInteger)analog x:(float)x y:(float)y;
- (BOOL)isPaused;
- (void)pausePlay:(BOOL)pausePlay;
- (void)stop;
- (void)reset;
- (BOOL)running;
- (BOOL)stopped;
- (void)orientationChangeWithOrientation:(UIInterfaceOrientation)orientation metalView:(UIView *)metalView;
- (void)orientationChanged:(UIInterfaceOrientation)orientation metalView:(UIView *)metalView;
- (void)setMotionRotation:(NSInteger)rotation;
- (void)updateSettingsWithAdvancedMode:(BOOL)advancedMode;
- (void)updateSettings:(BOOL)advancedMode;
- (void)setFrameLimit:(uint16_t)limit;
@end

static void *g_citra_handle = NULL;

@interface GCThreeDSBridge ()
@property (nonatomic, strong) id<GCCitraCoreABI> core;
@end

@implementation GCThreeDSBridge

+ (NSString *)citraBinaryPath {
    return [[NSBundle mainBundle].bundleURL
        URLByAppendingPathComponent:@"Frameworks/Citra.framework/Citra"].path;
}

+ (NSString *)moltenVKBinaryPath {
    return [[NSBundle mainBundle].bundleURL
        URLByAppendingPathComponent:@"Frameworks/MoltenVK.framework/MoltenVK"].path;
}

+ (BOOL)isFrameworkAvailable {
    return [[NSFileManager defaultManager] fileExistsAtPath:[self citraBinaryPath]];
}

+ (nullable instancetype)loadCoreWithError:(NSError * _Nullable * _Nullable)error {
    if (g_citra_handle == NULL) {
        NSString *mvkPath = [self moltenVKBinaryPath];
        if ([[NSFileManager defaultManager] fileExistsAtPath:mvkPath]) {
            dlopen(mvkPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
        }
        NSString *citraPath = [self citraBinaryPath];
        g_citra_handle = dlopen(citraPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
        if (g_citra_handle == NULL) {
            const char *dlErr = dlerror();
            NSString *detail = dlErr ? [NSString stringWithUTF8String:dlErr] : @"";
            NSString *msg = detail.length > 0
                ? [NSString stringWithFormat:@"无法加载 Manic EMU 3DS 引擎（Citra.framework）。请重新生成并安装最新版 iOS IPA。\n%@", detail]
                : @"无法加载 Manic EMU 3DS 引擎（Citra.framework）。请重新生成并安装最新版 iOS IPA。";
            if (error) {
                *error = [NSError errorWithDomain:@"GameCenter.ThreeDS" code:1 userInfo:@{NSLocalizedDescriptionKey: msg}];
            }
            return nil;
        }
    }

    Class cls = NSClassFromString(@"CitraCore");
    if (cls == Nil || ![cls respondsToSelector:@selector(shared)]) {
        if (error) {
            *error = [NSError errorWithDomain:@"GameCenter.ThreeDS" code:2 userInfo:@{
                NSLocalizedDescriptionKey: @"Citra.framework 缺少 CitraCore 入口类。"
            }];
        }
        return nil;
    }

    id instance = [(id<GCCitraCoreABI>)cls shared];
    if (instance == nil) {
        if (error) {
            *error = [NSError errorWithDomain:@"GameCenter.ThreeDS" code:3 userInfo:@{
                NSLocalizedDescriptionKey: @"无法初始化 CitraCore 实例。"
            }];
        }
        return nil;
    }

    GCThreeDSBridge *bridge = [[GCThreeDSBridge alloc] init];
    bridge.core = instance;
    return bridge;
}

- (void)allocateVulkanLibrary {
    if ([self.core respondsToSelector:@selector(allocateVulkanLibrary)]) {
        [self.core allocateVulkanLibrary];
    }
}

- (void)deallocateVulkanLibrary {
    if ([self.core respondsToSelector:@selector(deallocateVulkanLibrary)]) {
        [self.core deallocateVulkanLibrary];
    }
}

- (void)allocateMetalLayer:(CAMetalLayer *)layer size:(CGSize)size isSecondary:(BOOL)isSecondary {
    if ([self.core respondsToSelector:@selector(allocateMetalLayer:withSize:isSecondary:)]) {
        [self.core allocateMetalLayer:layer withSize:size isSecondary:isSecondary];
    }
}

- (void)deallocateMetalLayers {
    if ([self.core respondsToSelector:@selector(deallocateMetalLayers)]) {
        [self.core deallocateMetalLayers];
    }
}

- (void)insertCartridgeAndBootWithURL:(NSURL *)url advancedMode:(BOOL)advancedMode jitSupport:(BOOL)jitSupport {
    if ([self.core respondsToSelector:@selector(insertCartridgeAndBootWithURL:advancedMode:jitSupport:)]) {
        [self.core insertCartridgeAndBootWithURL:url advancedMode:advancedMode jitSupport:jitSupport];
    } else if ([self.core respondsToSelector:@selector(insertCartridgeAndBoot:advancedMode:jitSupport:)]) {
        [self.core insertCartridgeAndBoot:url advancedMode:advancedMode jitSupport:jitSupport];
    }
}

- (void)touchBeganAtPoint:(CGPoint)point {
    if ([self.core respondsToSelector:@selector(touchBeganAtPoint:)]) {
        [self.core touchBeganAtPoint:point];
    }
}

- (void)touchMovedAtPoint:(CGPoint)point {
    if ([self.core respondsToSelector:@selector(touchMovedAtPoint:)]) {
        [self.core touchMovedAtPoint:point];
    }
}

- (void)touchEnded {
    if ([self.core respondsToSelector:@selector(touchEnded)]) {
        [self.core touchEnded];
    }
}

- (void)virtualControllerButtonDown:(NSUInteger)button {
    if ([self.core respondsToSelector:@selector(virtualControllerButtonDown:)]) {
        [self.core virtualControllerButtonDown:button];
    }
}

- (void)virtualControllerButtonUp:(NSUInteger)button {
    if ([self.core respondsToSelector:@selector(virtualControllerButtonUp:)]) {
        [self.core virtualControllerButtonUp:button];
    }
}

- (void)thumbstickMoved:(NSUInteger)analog x:(float)x y:(float)y {
    if ([self.core respondsToSelector:@selector(thumbstickMoved:x:y:)]) {
        [self.core thumbstickMoved:analog x:x y:y];
    }
}

- (BOOL)isPaused {
    if ([self.core respondsToSelector:@selector(isPaused)]) {
        return [self.core isPaused];
    }
    return NO;
}

- (void)pausePlay:(BOOL)play {
    if ([self.core respondsToSelector:@selector(pausePlay:)]) {
        [self.core pausePlay:play];
    }
}

- (void)stop {
    if ([self.core respondsToSelector:@selector(stop)]) {
        [self.core stop];
    }
}

- (void)reset {
    if ([self.core respondsToSelector:@selector(reset)]) {
        [self.core reset];
    }
}

- (BOOL)running {
    if ([self.core respondsToSelector:@selector(running)]) {
        return [self.core running];
    }
    return NO;
}

- (BOOL)stopped {
    if ([self.core respondsToSelector:@selector(stopped)]) {
        return [self.core stopped];
    }
    return YES;
}

- (void)orientationChange:(UIInterfaceOrientation)orientation metalView:(UIView *)metalView {
    if ([self.core respondsToSelector:@selector(orientationChangeWithOrientation:metalView:)]) {
        [self.core orientationChangeWithOrientation:orientation metalView:metalView];
    } else if ([self.core respondsToSelector:@selector(orientationChanged:metalView:)]) {
        [self.core orientationChanged:orientation metalView:metalView];
    }
}

- (void)setMotionRotation:(NSInteger)rotation {
    if ([self.core respondsToSelector:@selector(setMotionRotation:)]) {
        [self.core setMotionRotation:rotation];
    }
}

- (void)updateSettingsWithAdvancedMode:(BOOL)advancedMode {
    if ([self.core respondsToSelector:@selector(updateSettingsWithAdvancedMode:)]) {
        [self.core updateSettingsWithAdvancedMode:advancedMode];
    } else if ([self.core respondsToSelector:@selector(updateSettings:)]) {
        [self.core updateSettings:advancedMode];
    }
}

- (void)setFrameLimit:(uint16_t)limit {
    if ([self.core respondsToSelector:@selector(setFrameLimit:)]) {
        [self.core setFrameLimit:limit];
    }
}

@end
