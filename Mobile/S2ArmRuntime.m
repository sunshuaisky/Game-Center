// The official S2Arm executable owns UIApplication and its early memory setup.
// Replace only its library controller, retaining its registered Play callback,
// launch-context validation, renderer, audio, input and crash recovery.
#import "S2ArmRuntime.h"
#import "NXShellLibrary.h"
#import <objc/runtime.h>
#import <dlfcn.h>

static IMP originalShowLibrary;
static int (*playGame)(const char *);
static const void *(*launchContext)(void);
static int (*needsUpdate)(const char *);
static int (*needsReinstall)(const char *);
static IMP originalLifecycle[4];
static IMP originalOrientations;
static IMP originalGearItems;
static UIViewController *gameCenterLibrary;
static BOOL exitingGame;
typedef void (*GCStopCallback)(int, const char *, void *);
static int (*stopSession)(GCStopCallback, void *);
static int (*sessionState)(void);
extern const char *dm_shell_active_game_id(void);

@protocol GCGameMenu <NSObject>
- (void)afterMenu:(void (^)(void))action;
@end

static void restoreGameCenter(UIWindow *window) {
    void (*releaseGameView)(void) = dlsym(RTLD_DEFAULT, "s2a_ios_release_game_view");
    if (releaseGameView) releaseGameView();
    window.rootViewController = gameCenterLibrary;
    [NSNotificationCenter.defaultCenter postNotificationName:@"DMShellDidReturnToLibrary" object:nil];
}

@interface S2ArmLibrary : NSObject
+ (void)prepareRuntime;
+ (void)prepareIntegrationLaunch:(NSString *)titleID;
@end

// Integration-only entry driven by an explicit devicectl launch environment.
// It uses the same retirement, library restoration and launch paths as the UI.
static void testRepeatStopped(int result, const char *detail, void *context) {
    int phase = (int)(intptr_t)context;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (result) { NSLog(@"GC_REPEAT failed stop %d: %s", phase, detail ?: ""); return; }
        UIWindow *window = gameCenterLibrary.view.window;
        if (!window) for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
            if ([scene isKindOfClass:UIWindowScene.class]) for (UIWindow *candidate in ((UIWindowScene *)scene).windows)
                if (candidate.isKeyWindow) window = candidate;
        restoreGameCenter(window);
        NSLog(@"GC_REPEAT stopped phase=%d library_restored=%d", phase, window.rootViewController == gameCenterLibrary);
        const char *second = getenv("GAME_CENTER_TEST_SECOND_TITLE");
        int last = second && *second ? 3 : 2;
        if (phase == last) { NSLog(@"GC_REPEAT completed %d sessions in one process", last); return; }
        const char *next = phase == 1 && second && *second ? second : getenv("S2A_LIBRARY_AUTOPLAY");
        [S2ArmLibrary prepareIntegrationLaunch:@(next)];
        const char *error = gc_s2arm_start_game(next);
        NSLog(@"GC_REPEAT resume accepted=%d error=%s", error == NULL, error ?: "none");
        if (!error) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSLog(@"GC_REPEAT second session state=%d", sessionState ? sessionState() : -1);
            int rc = stopSession(testRepeatStopped, (void *)(intptr_t)(phase + 1));
            if (rc) NSLog(@"GC_REPEAT second stop rejected=%d", rc);
        });
    });
}

static void exitFinished(int result, const char *detail, void *context) {
    UIAlertController *progress = CFBridgingRelease(context);
    NSString *failure = result ? [NSString stringWithUTF8String:detail ?: "游戏会话未能安全关闭，请重新打开 App。"] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [progress dismissViewControllerAnimated:YES completion:^{
            exitingGame = NO;
            UIWindow *window = progress.view.window;
            if (!window) {
                for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
                    if ([scene isKindOfClass:UIWindowScene.class])
                        for (UIWindow *candidate in ((UIWindowScene *)scene).windows)
                            if (candidate.isKeyWindow) window = candidate;
            }
            if (failure) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"退出未完成" message:failure preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [window.rootViewController presentViewController:alert animated:YES completion:nil];
            } else {
                restoreGameCenter(window);
            }
        }];
    });
}

static void confirmExit(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:UIWindowScene.class])
            for (UIWindow *candidate in ((UIWindowScene *)scene).windows)
                if (candidate.isKeyWindow) window = candidate;
    UIViewController *presenter = window.rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"退出游戏" message:@"确认退出并返回游戏详情？请先在游戏内保存进度。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"继续游戏" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确认退出" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        if (exitingGame || !stopSession) return;
        exitingGame = YES;
        UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"正在退出游戏…" message:@"正在关闭游戏会话，请稍候。" preferredStyle:UIAlertControllerStyleAlert];
        [presenter dismissViewControllerAnimated:YES completion:^{
            [presenter presentViewController:progress animated:YES completion:^{
                void *context = (void *)CFBridgingRetain(progress);
                int result = stopSession(exitFinished, context);
                if (result) exitFinished(result, "当前游戏尚不能安全退出，请稍后重试。", context);
            }];
        }];
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static id noMenuAction(id owner, SEL selector) { return nil; }
static NSArray *gearItems(id owner, SEL selector) {
    NSMutableArray *items = [((NSArray *(*)(id, SEL))originalGearItems)(owner, selector) mutableCopy];
    __weak id weakOwner = owner;
    [items addObject:[UIAction actionWithTitle:@"退出游戏" image:[UIImage systemImageNamed:@"rectangle.portrait.and.arrow.right"] identifier:@"gamecenter.exit" handler:^(UIAction *action) {
        [(id<GCGameMenu>)weakOwner afterMenu:^{ confirmExit(); }];
    }]];
    return items;
}

static void forwardScene(id owner, SEL selector, UIScene *scene, int state) {
    if (dm_shell_active_game_id()) { gc_nx_focus(state); return; }
    if (originalLifecycle[state]) ((void (*)(id, SEL, UIScene *))originalLifecycle[state])(owner, selector, scene);
}
static void resignActive(id o, SEL s, UIScene *scene) { forwardScene(o, s, scene, 0); }
static void enterBackground(id o, SEL s, UIScene *scene) { forwardScene(o, s, scene, 1); }
static void enterForeground(id o, SEL s, UIScene *scene) { forwardScene(o, s, scene, 2); }
static void becomeActive(id o, SEL s, UIScene *scene) { forwardScene(o, s, scene, 3); }
static UIInterfaceOrientationMask orientations(id owner, SEL selector, UIWindowScene *scene) {
    if (dm_shell_active_game_id()) return gc_nx_orientations(scene.traitCollection);
    return originalOrientations ? ((UIInterfaceOrientationMask (*)(id, SEL, UIWindowScene *))originalOrientations)(owner, selector, scene) : UIInterfaceOrientationMaskAll;
}



static void showGameCenter(id scene, SEL selector) {
    ((void (*)(id, SEL))originalShowLibrary)(scene, selector);
    UIWindow *window = [scene valueForKey:@"window"];
    UIViewController *library = [ShellLibrary makeControllerWithInitialURL:nil];
    gameCenterLibrary = library;
    gc_nx_set_library_controller(library);
    window.rootViewController = library;
    [window makeKeyAndVisible];
    const char *repeat = getenv("GAME_CENTER_TEST_REOPEN");
    if (repeat && !strcmp(repeat, "1") && getenv("S2A_LIBRARY_AUTOPLAY") && stopSession) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSLog(@"GC_REPEAT first session state=%d", sessionState ? sessionState() : -1);
            int rc = stopSession(testRepeatStopped, (void *)(intptr_t)1);
            if (rc) NSLog(@"GC_REPEAT first stop rejected=%d", rc);
        });
    }
}

@interface GameCenterS2ArmAdapter : NSObject
@end
@implementation GameCenterS2ArmAdapter
+ (void)load {
    Class scene = NSClassFromString(@"S2ASceneDelegate");
    Method method = scene ? class_getInstanceMethod(scene, NSSelectorFromString(@"showLibrary")) : NULL;
    playGame = dlsym(RTLD_DEFAULT, "s2a_shell_play");
    launchContext = dlsym(RTLD_DEFAULT, "s2a_launch_ctx_get");
    needsUpdate = dlsym(RTLD_DEFAULT, "s2a_shell_game_needs_host_update");
    needsReinstall = dlsym(RTLD_DEFAULT, "s2a_shell_game_needs_reinstall");
    if (method && playGame && launchContext) {
        stopSession = dlsym(RTLD_DEFAULT, "s2a_host_stop");
        sessionState = dlsym(RTLD_DEFAULT, "s2a_host_session_state");
        if (stopSession) {
            Class runtime = NSClassFromString(@"S2ASettingsRuntime");
            for (NSString *name in @[@"manageSaves", @"switchGame"]) {
                Method getter = class_getInstanceMethod(runtime, NSSelectorFromString(name));
                if (getter) method_setImplementation(getter, (IMP)noMenuAction);
            }
            Method gear = class_getInstanceMethod(NSClassFromString(@"S2AVPadView"), NSSelectorFromString(@"gearItems"));
            if (gear) originalGearItems = method_setImplementation(gear, (IMP)gearItems);
        }
        [S2ArmLibrary prepareRuntime];
        originalShowLibrary = method_setImplementation(method, (IMP)showGameCenter);
        SEL selectors[] = {@selector(sceneWillResignActive:), @selector(sceneDidEnterBackground:),
                           @selector(sceneWillEnterForeground:), @selector(sceneDidBecomeActive:)};
        IMP implementations[] = {(IMP)resignActive, (IMP)enterBackground, (IMP)enterForeground, (IMP)becomeActive};
        for (int i = 0; i < 4; i++) {
            Method old = class_getInstanceMethod(scene, selectors[i]);
            if (old) originalLifecycle[i] = method_setImplementation(old, implementations[i]);
            else class_addMethod(scene, selectors[i], implementations[i], "v@:@");
        }
        SEL orientation = @selector(supportedInterfaceOrientationsForWindowScene:);
        Method old = class_getInstanceMethod(scene, orientation);
        if (old) originalOrientations = method_setImplementation(old, (IMP)orientations);
        else class_addMethod(scene, orientation, (IMP)orientations, "Q@:@");
    }
}
@end

int gc_s2arm_available(void) { return originalShowLibrary && playGame && launchContext; }
int gc_s2arm_active(void) { return gc_s2arm_available() && launchContext() != NULL && (!sessionState || sessionState() != 4); }
const char *gc_s2arm_start_game(const char *title_id) {
    if (!gc_s2arm_available()) return "当前 IPA 未包含 S2Arm 真机宿主，请重新生成并安装 Game Center IPA。";
    if (sessionState && sessionState() == 4) {
        int (*resumeGame)(const char *) = dlsym(RTLD_DEFAULT, "s2a_ios_resume_game");
        if (!resumeGame) return "当前 IPA 的宿主尚不支持再次启动，请安装新版 Game Center IPA。";
        int result = resumeGame(title_id);
        if (result == -4) return "无法准备这款游戏的运行环境，请检查游戏包和运行日志。";
        return result ? "游戏会话暂时未能重新启动，请稍后重试。" : NULL;
    }
    if (gc_s2arm_active()) return "请先退出当前游戏，再选择另一款游戏。";
    if (!playGame(title_id)) return "S2Arm 游戏启动回调尚未就绪，请重新打开 Game Center。";
    if (needsReinstall && needsReinstall(title_id)) return "游戏程序签名与当前 App 不匹配，请在 Mac 使用相同签名重新构建并导入。";
    if (needsUpdate && needsUpdate(title_id)) return "游戏程序与当前 S2Arm 宿主版本不兼容，请在 Mac 更新引擎后重新构建游戏。";
    return NULL; // Other failures are presented by the official host itself.
}
