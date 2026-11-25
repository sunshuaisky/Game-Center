#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <stdio.h>

typedef const char *(*S2ABuildIDFunction)(void);
typedef void (*S2AEnableCheatsFunction)(void);

@interface GCStandaloneCheats : NSObject <NSMenuDelegate>
@property(nonatomic, copy) NSString *directory;
@property(nonatomic, strong) NSMutableSet<NSString *> *enabled;
@end

@implementation GCStandaloneCheats

- (instancetype)init {
    if ((self = [super init])) {
        const char *path = getenv("S2A_CHEATS_DIR");
        if (!path || !*path) path = getenv("S2A_CHEATS");
        self.directory = path && *path ? [NSString stringWithUTF8String:path] : @"";
        self.enabled = [NSMutableSet set];
        [self reloadEnabled];
    }
    return self;
}

- (NSURL *)enabledURL {
    return [NSURL fileURLWithPath:[self.directory stringByAppendingPathComponent:@"enabled.txt"]];
}

- (void)reloadEnabled {
    NSString *text = [NSString stringWithContentsOfURL:self.enabledURL encoding:NSUTF8StringEncoding error:nil] ?: @"";
    self.enabled = [NSMutableSet setWithArray:[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]];
    [self.enabled removeObject:@""];
}

- (NSString *)buildID {
    S2ABuildIDFunction function = (S2ABuildIDFunction)dlsym(RTLD_DEFAULT, "s2a_main_build_id");
    const char *value = function ? function() : NULL;
    NSString *build = value ? [NSString stringWithUTF8String:value] : @"";
    return build.length >= 16 ? [[build substringToIndex:16] uppercaseString] : @"";
}

- (NSArray<NSDictionary *> *)entries {
    NSString *build = self.buildID;
    if (self.directory.length == 0 || build.length != 16) return @[];
    NSString *file = [build stringByAppendingPathExtension:@"txt"];
    NSString *text = [NSString stringWithContentsOfFile:[self.directory stringByAppendingPathComponent:file]
                                                encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (line.length < 3 || ![line hasPrefix:@"["] || ![line hasSuffix:@"]"]) continue;
        NSString *name = [[line substringWithRange:NSMakeRange(1, line.length - 2)]
                          stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (name.length == 0) name = @"未命名";
        [result addObject:@{@"name": name, @"key": [NSString stringWithFormat:@"%@/%@", file, name]}];
    }
    return result;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    [self reloadEnabled];
    NSArray<NSDictionary *> *entries = self.entries;
    if (entries.count == 0) {
        NSMenuItem *empty = [menu addItemWithTitle:@"没有当前版本的金手指" action:nil keyEquivalent:@""];
        empty.enabled = NO;
    } else {
        for (NSDictionary *entry in entries) {
            NSMenuItem *item = [menu addItemWithTitle:entry[@"name"] action:@selector(toggle:) keyEquivalent:@""];
            item.target = self;
            item.representedObject = entry[@"key"];
            item.state = [self.enabled containsObject:entry[@"key"]] ? NSControlStateValueOn : NSControlStateValueOff;
        }
    }
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *open = [menu addItemWithTitle:@"打开金手指文件夹…" action:@selector(openFolder:) keyEquivalent:@""];
    open.target = self;
    NSMenuItem *reload = [menu addItemWithTitle:@"重新载入金手指" action:@selector(reload:) keyEquivalent:@""];
    reload.target = self;
}

- (void)toggle:(NSMenuItem *)item {
    NSString *key = item.representedObject;
    if ([self.enabled containsObject:key]) [self.enabled removeObject:key]; else [self.enabled addObject:key];
    NSString *body = [[self.enabled.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@"\n"];
    if (body.length) body = [body stringByAppendingString:@"\n"];
    NSError *error = nil;
    if (![body writeToURL:self.enabledURL atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"无法保存金手指设置";
        alert.informativeText = error.localizedDescription ?: @"";
        [alert runModal];
    }
}

- (void)openFolder:(id)sender {
    (void)sender;
    if (self.directory.length) [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:self.directory isDirectory:YES]];
}

- (void)reload:(id)sender { (void)sender; [self reloadEnabled]; }

@end

static GCStandaloneCheats *gCheats;

static void GCInstallCheatsMenu(void) {
    if (gCheats || !NSApp.mainMenu) return;
    for (NSMenuItem *item in NSApp.mainMenu.itemArray) {
        if ([item.title isEqualToString:@"金手指"] || [item.title isEqualToString:@"Cheats"]) {
            fprintf(stderr, "[GameCenter] S2Arm 金手指菜单已由宿主提供\n");
            return;
        }
    }
    gCheats = [GCStandaloneCheats new];
    S2AEnableCheatsFunction enable = (S2AEnableCheatsFunction)dlsym(RTLD_DEFAULT, "s2a_cheats_host_enable");
    if (enable) enable();
    NSMenu *submenu = [[NSMenu alloc] initWithTitle:@"金手指"];
    submenu.delegate = gCheats;
    submenu.autoenablesItems = NO;
    NSMenuItem *root = [[NSMenuItem alloc] initWithTitle:@"金手指" action:nil keyEquivalent:@""];
    root.submenu = submenu;
    [NSApp.mainMenu addItem:root];
    fprintf(stderr, "[GameCenter] S2Arm 金手指菜单已安装\n");
}

__attribute__((constructor)) static void GCStandaloneCheatsLoad(void) {
    fprintf(stderr, "[GameCenter] S2Arm 金手指菜单组件已加载\n");
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification
                                                        object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(__unused NSNotification *note) { GCInstallCheatsMenu(); }];
        if (NSApp.isRunning) GCInstallCheatsMenu();
    });
}
