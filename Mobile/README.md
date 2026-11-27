# Game Center for iOS

macOS 顶栏的「生成 iOS App」会扫描当前游戏目录，输出一份 `Game Center.ipa`。
基础 IPA 包含手机游戏库、iOS 模拟器核心、NX2Apple Shell 和 Switch 标题清单。
手机端显示 Mac 游戏库里的 Switch 标题。每款游戏的程序和资源通过独立的
`.gcimport` 文件夹导入。

游戏构建自动读取本机有效的 iOS 开发证书及私钥，不需要选择描述文件。
手机连接时会识别已安装 Game Center 的签名团队，并供后续离线构建自动匹配。
基础 IPA 使用 AltStore / SideStore 安装，侧载账号需与游戏签名账号相同。
本机缺少对应开发证书时会在构建阶段提示，不能绕过 iOS 的签名验证。

## iPhone 文件目录

在「文件 → 在我的 iPhone 上 → Game Center」中可以看到 `Documents` 的内容。

```text
Documents/
├── GameLibrary/                     # 与 Mac 游戏目录结构完全一致
│   ├── gb/
│   ├── gbc/
│   ├── gba/
│   ├── nds/
│   ├── 3ds/
│   ├── psp/
│   ├── ps1/
│   ├── ps2/
│   ├── wii/
│   ├── wiiu/
│   ├── switch/
│   │    ├── catalog.json                     # 可选的更新清单
│   │    ├── <TitleID>-<引擎>.gcimport/         # 拷入这里后自动导入
│   │    └── <TitleID>/
│   │        ├── Builds/
│   │        │   ├── S2Arm/
│   │        │   │   ├── manifest.json
│   │        │   │   ├── S2AImages-<TitleID>.dylib
│   │        │   │   ├── Games/<TitleID>/
│   │        │   │   └── Content/game.img
│   │        │   └── NXNative/
│   │        │       ├── manifest.json
│   │        │       ├── DmGame<TitleID>.framework/
│   │        │       └── Content/
│   │        │           ├── romfs.img
│   │        │           └── aoc/              # 可选 DLC
│   │        └── UserData/<引擎>/          # 设置等运行数据，不存放持久游戏存档
│   └── save/
│       ├── <平台>/<游戏名>/
│       └── switch/<TitleID>/
│           ├── save/                    # 两种引擎共享
│           └── save_device/
├── BIOS/<平台>/
└── Export/
```

普通 ROM 可以从 iOS 游戏库选择平台后导入，也可以直接拷入相应 ROM 目录。
对于 CUE、M3U 等由多个文件组成的游戏，用「文件」把整套文件拷入同一个子目录。
App 回到前台时扫描这些目录。

Switch 包输出到 Mac 游戏库的 `switch/iOS`。把整个 `.gcimport` 文件夹放入
手机的 `GameLibrary/Switch`，或者从 Switch 页使用「导入」。回到 App 或下拉刷新后，
构建包会自动归档到 `<TitleID>/Builds/<引擎>`，成功后移除根目录中的待导入包。
两套引擎共用同一个
Title ID，资源和程序分别保存。只有一个 IMG 的目录不构成可启动的程序包。

## 接入与验证状态

- NXNative 走 NX2Apple 的 `--shell-framework` 模式。手机端使用同一项目的 Shell 启动
  Framework。该路径依赖支持 NX2Apple 的设备、iOS 26 或更新版本和同一开发团队签名。
  仍需用实际构建的游戏执行真机验证。
- S2Arm 真机 IPA 嵌入已安装引擎的官方共享宿主（按随包清单校验），包含渲染、音频、输入、
  NativeAOT 服务层和游戏代码加载；Game Center 的 Framework 提供统一游戏库，保留官方 Play
  回调和启动校验。NXNative 使用同一 IPA 内的 NX2Apple Shell 桥接。
  不包含每款游戏的程序和资源。运行时版本记在 IPA 的 `S2Arm-runtime.json`。
- S2Arm 游戏包必须有 `catalogue.json`（宿主 ABI、程序哈希及签名团队）；旧版导出缺少该文件，
  需要在 Mac 重新构建。导入后可直接点击启动，宿主在起局前自动校验并按需调整地址空间与代码槽位。
  游戏文件仍在 `GameLibrary/Switch/<TitleID>/Builds/S2Arm`，内部运行目录使用别名，
  不复制 IMG；设置在 `<TitleID>/UserData/S2Arm`，存档统一在 `GameLibrary/save/switch/<TitleID>`。
- S2Arm 设置菜单提供退出确认，安全退休会话后恢复启动前保留的游戏详情控制器。
  退出宿主使用 `scripts/patches/s2arm-session-exit.patch`，macOS 发布包附带预编译宿主，
  源码构建可用 `scripts/prepare-s2arm-exit-host.py` 重建。同款游戏退出后可通过会话重建再次启动；跨游戏切换仍受签名代码地址保留限制。
- 两个引擎的程序包均需与 IPA 使用匹配的开发团队签名。S2Arm 一进程运行一款，切换游戏
  需要重开 App。iOS 模拟器不嵌入 S2Arm 真机宿主。尚需完成有效签名下的实际游戏真机验证。
- Libretro 前端已接入软件画面、音频、手柄和电池存档。依赖硬件渲染接口的核心尚待接入对应接口，
  各平台仍需实际 ROM 和真机验证。平台和 ROM 扩展名由 `IOSCoreCatalog.swift` 统一定义。
- 设置直接同步整个 `GameLibrary/save`，按文件修改时间自动上传较新文件或恢复云端较新文件，覆盖前保留备份。
  不再依赖游戏是否已安装，GB/GBC/GBA 的电池存档文件名会映射。复制保留修改时间，不传播删除。
  相同修改时间但内容不同会保留两端并提示。其他核心仅同步原文件，不执行跨模拟器格式转换。
- Mac 自动创建 `iCloud Drive/Game Center存档/save`。iOS 普通 AltStore/SideStore 签名没有 iCloud Documents
  权限时，首次必须通过系统文件窗口授权 iCloud Drive（或已经存在的固定存档文件夹）；之后记住授权。
  有合法 iCloud 容器签名的安装可以使用容器，无须选择文件夹；当前侧载包不会伪造此权限。


## 构建

需要 Xcode、iOS SDK 和已安装的 S2Arm 内置引擎。第一次生成 IPA 会下载固定版本的 NX2Apple Shell 源码和
Libretro iOS 核心。可用 `GAME_CENTER_IOS_CORE_DIR` 指定准备好的核心目录。
命令行与 macOS 按钮走同一个构建入口。

```bash
swift build
.build/debug/GameCenter --build-ios "$PWD/build/ios" "/path/to/game-library"
```

日常构建无需手选描述文件。游戏构建自动匹配本机有效的 iOS 开发证书及手机团队；
Game Center IPA 由 AltStore / SideStore 使用同一 Apple 账号安装。高级命令行仍支持
`GAME_CENTER_IOS_PROFILE`，不影响默认自动流程。
设置 `GAME_CENTER_IOS_SDK=iphonesimulator` 可构建模拟器用的 `.app`，用于验证游戏库和
导入流程。真机核心使用 iOS arm64 二进制。


## iOS 接入状态

GB/GBC、GBA、NDS、3DS、PSP、PS1 使用现有 libretro 宿主，Switch 保留 S2Arm/NXNative 专用宿主。

新增平台的游戏仍在 Game Center 内运行：

| 平台 | 引擎及运行方式 | 首次准备 |
| --- | --- | --- |
| Wii | Dolphin libretro，缓存解释器与软件渲染 | 系统资源随应用打包，运行速度需要真机验证 |
| Wii U | MuffinEMU v11.8 的 Cemu 原生框架，Metal 渲染 | 加密内容需要自己的密钥，放在 BIOS/WiiU/keys.txt |
| PS2 | PCEE2 的 PCSX2 核心，Metal 渲染与解释执行 | BIOS 已随应用内置，首次启动写入 BIOS/PS2/pcsx2/bios；需要其他版本时自行放入 |
| PS3 | RPCS3 v0.2.0 iOS 原生框架 | 先为 Game Center 开启兼容的 JIT 调试器；系统固件已随应用内置，首次启动时写入 RPCS3 的目录，需要重装时在 BIOS/PS3 放入 PS3UPDAT.PUP |
| PS Vita | 运行宿主尚未完成 | 独立上游项目不能直接作为 Game Center 的内嵌框架使用 |

PS1 与 PS2 的 BIOS、PS3 的固件随应用打包在 `CoreAssets/` 下，由构建电脑 `build/system-files/` 里的本地副本生成，不依赖下载目录。应用一打开就写入 `BIOS/<平台>`（在「文件」应用里可见），只补缺失文件，已有文件（包括用户自己放入的）不会被覆盖。PS3 的固件在 `BIOS/PS3`，启动 PS3 游戏时再拷进 RPCS3 自己的目录。

Wii U 支持 WUA/WUX/WUD/RPX 和含 title.tmd 或 code/*.rpx 的内容文件夹，PS3 支持 ISO/SELF/EBOOT.BIN 及光盘或安装后的游戏文件夹。PS3 在 JIT 内存准备成功前不会加载原生核心。

libretro 核心的运行、保存与关闭共用后台串行队列。新增摇杆输入和触屏指针，PS2 记忆卡保存到 GameLibrary/save/ps2，PS3 账户存档保存到 GameLibrary/save/ps3/home，Wii U 使用 GameLibrary/save/wiiu/mlc。Wii 与 PS2 的解释执行模式可能很慢，编译、打包和 ABI 检查不代表已通过真机游戏验证。

新加入的原生框架在 build-ios-app.sh 中和其他框架一起签名。build/ios-integration 中的验证包采用临时签名，只用于构建检查，安装到手机前需走应用的正常签名流程。
