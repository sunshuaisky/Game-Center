# Game Center

面向 **macOS (Apple Silicon)** 与 **iOS** 的一体化多平台游戏库与模拟器前端。采用原生 SwiftUI + SwiftPM 构建，集成全平台 `arm64` 模拟器核心、高清封面与背景图刮削、全平台外接手柄支持、Switch 双引擎构建与金手指管理，以及 Mac / iOS 统一存档与 iCloud 双向同步。

---

## 核心特性

- **双端统一游戏库**：macOS 端支持 **14 个平台**；iOS 伴侣端支持 **11 个全免 JIT 平台**（无需 StikDebug / 电脑激活，装好即玩）。
- **Mac & iOS 目录结构 1:1 一致**：两端采用完全一致的小写平台目录名与 `save/` 存档树，直接拷贝平台文件夹即可互通。
- **全平台原生 Apple Silicon (`arm64`) 运行**：
  - macOS 端通过独立进程 `GameCenterCoreHelper` 内嵌运行 9 个 Libretro `arm64` 核心（GB / GBC / GBA / NDS / 3DS / PSP / PS1 / PS2 / Wii），零 Rosetta 依赖；Wii U / PS3 / PS Vita 集成上游原生 `arm64` 独立模拟器。
  - iOS 端内嵌全套 `arm64` Libretro 核心 + Cemu (`MuffinEMU`) Metal 渲染框架 + Switch 共享运行宿主，并内置标准 BIOS 与系统资源。
- **高清封面与背景图刮削**：接入 LaunchBox GamesDB（1080p–4K Fanart 背景图 + 官方主机盒装封面）、Steam 媒体与百科简介；始终保留本地游戏文件名作为显示标题，支持单款重抓与设置内一键全量扫描更新。
- **全平台外接手柄支持**：
  - 支持 Xbox / PlayStation DualSense / Switch Pro / MFi 等外接手柄（`GCController` / SDL），支持热插拔检测与界面全手柄导航。
  - 针对纯十字键掌机自动开启左摇杆镜像，带独立摇杆的 3D 主机不产生重复方向输入；iOS 端提供多点触控虚拟手柄与外接手柄无缝融合。
- **Switch 双引擎（S2Arm / NXNative）与金手指**：支持构建 macOS 原生应用与 iOS `.gcimport` 游戏包，内置 Atmosphère `.txt` 金手指管理与运行时热切换。
- **统一存档 & iCloud 同步**：以 `save/<平台>/` 作为唯一持久存档根目录，按文件修改时间进行增量同步并自动保留冲突/覆盖前备份。
- **多语言与明暗外观**：支持简体中文、English、日本語，界面自动跟随系统或手动切换浅色 / 暗黑模式。

---

## 支持平台与模拟器核心

### macOS 端（14 个平台，全部原生 `arm64`）

| 平台目录 | 平台 | 运行方式 / 模拟器 | 支持格式示例 |
| --- | --- | --- | --- |
| `gb` / `gbc` | Game Boy / Color | 内嵌 Libretro · mGBA | `.gb` `.gbc` `.zip` |
| `gba` | Game Boy Advance | 内嵌 Libretro · mGBA | `.gba` |
| `nds` | Nintendo DS | 内嵌 Libretro · DeSmuME | `.nds` |
| `3ds` | Nintendo 3DS | 内嵌 Libretro · Azahar | `.3ds` `.cci` `.cxi` `.3dsx` |
| `psp` | PlayStation Portable | 内嵌 Libretro · PPSSPP | `.iso` `.cso` `.pbp` `.chd` |
| `ps1` | PlayStation | 内嵌 Libretro · SwanStation | `.cue` `.ccd` `.img` `.chd` `.m3u` `.pbp` `.iso` |
| `ps2` | PlayStation 2 | 内嵌 Libretro · PCEE2 (PCSX2 ARM64) | `.iso` `.chd` `.cso` `.bin` `.gz` `.elf` |
| `wii` | Nintendo Wii | 内嵌 Libretro · Dolphin | `.iso` `.wbfs` `.rvz` `.gcz` `.ciso` `.wad` |
| `wiiu` | Nintendo Wii U | 内置独立版 · Cemu (`hauntek/Cemu`) | `.wua` `.wux` `.wud` `.rpx` / 解包目录 |
| `ps3` | PlayStation 3 | 内置独立版 · RPCS3 | 含 `PS3_GAME/USRDIR/EBOOT.BIN` 的目录 / `.iso` |
| `psv` | PlayStation Vita | 内置独立版 · Vita3K | `.vpk` `.zip` / 含 `sce_sys/param.sfo` 的目录 |
| `switch` | Nintendo Switch | S2Arm / NXNative | 游戏镜像及构建后的 `.app` |
| `mac` | macOS 原生游戏 | 系统原生启动 | `.app` |

### iOS 端（11 个平台，100% 免 JIT）

| 平台目录 | 平台 | iOS 内置核心 | 备注 |
| --- | --- | --- | --- |
| `gb` / `gbc` | Game Boy / Color | Gambatte (Libretro) | 免 JIT，支持虚拟多点触控与外接手柄 |
| `gba` | Game Boy Advance | mGBA (Libretro) | 免 JIT，自动电池存档同步 |
| `nds` | Nintendo DS | DeSmuME (Libretro) | 免 JIT，双屏触控 + 外接手柄 |
| `3ds` | Nintendo 3DS | Azahar (Libretro) | 免 JIT，软件渲染与解释执行 |
| `psp` | PlayStation Portable | PPSSPP (Libretro) | 免 JIT，内置 `flash0` 字体资源 |
| `ps1` | PlayStation | SwanStation (Libretro) | 免 JIT，内置标准 BIOS (`scph5500/5501/5502`) |
| `ps2` | PlayStation 2 | PCEE2 (PCSX2 Libretro) | 免 JIT，软件渲染 + 解释执行，内置 BIOS |
| `wii` | Nintendo Wii | Dolphin (Libretro) | 免 JIT，内置 Dolphin `Sys` 资源 |
| `wiiu` | Nintendo Wii U | Cemu (`MuffinEMU` Metal) | 免 JIT，原生 Metal + MoltenVK 渲染，支持导入 `keys.txt` |
| `switch` | Nintendo Switch | S2Arm / NXNative 共享宿主 | 导入 macOS 端生成的 `.gcimport` 游戏包 |

> 注：iOS 端不内置需要 JIT 的 PS3 与 PS Vita 模拟器，保证所有 iOS 平台装好即可直接游玩；PS3 与 PS Vita 请在 macOS 端游玩。更多 iOS 细节见 [Mobile/README.md](./Mobile/README.md)。

---

## 统一游戏目录结构（Mac & iOS 一致）

在 macOS 上选择一个目录作为游戏根目录（例如 `~/Documents/Game`），在 iOS 上对应「文件 → 我的 iPhone → Game Center → `GameLibrary`」，两者结构完全一致：

```text
<游戏根目录> (macOS) / Documents/GameLibrary/ (iOS)
├── gb/
├── gbc/
├── gba/
├── nds/
├── 3ds/
├── psp/
├── ps1/
├── ps2/
├── wii/
├── wiiu/
├── switch/
│   ├── build/        # macOS Switch 构建临时目录（扫描时自动忽略）
│   ├── cheat/        # Switch Atmosphère 金手指：cheat/<TitleID>/cheats/<BuildID>.txt
│   └── iOS/          # macOS 导出的 iOS Switch .gcimport 包
├── ps3/              # 仅 macOS
├── psv/              # 仅 macOS
├── mac/              # 仅 macOS
└── save/             # 全平台统一持久存档目录（iCloud 同步源）
    ├── <平台>/<游戏名>/
    └── switch/<16位TitleID>/
```

- 升级新版 iOS App 时，会自动将旧版 `GameLibrary/ROMs/*`、`GameLibrary/Switch` 与大写 `BIOS/*` 无损迁移至上述统一小写目录。

---

## 快速构建与开发

### 环境要求
- Apple Silicon Mac（macOS 14.0+）
- Xcode（含 macOS SDK 与 iOS SDK，导出 iOS IPA 时需要）
- Python 3（系统自带）

### 1. 开发模式（热重载）
```bash
./scripts/dev.sh
```
保存 `Sources/` 或 `Package.swift` 修改后自动编译并刷新调试窗口。

### 2. 构建完整的 macOS 应用包
```bash
./scripts/build_app.sh
```
脚本会自动下载并校验各平台原生 `arm64` 核心与独立模拟器，验证无外部 Homebrew 动态库依赖后，在 `build/Game Center.app` 生成完整应用包。

> 如需内置个人备份的 BIOS / 固件，可在构建前放入本地 `build/system-files/`（该目录已被 `.gitignore` 忽略，**切勿提交到公开仓库**）。

### 3. 生成 iOS 安装包（IPA）
- **图形界面**：打开 `build/Game Center.app`，点击顶栏「生成 iOS App」即可输出 `Game Center.ipa`（自动读取本机有效 Apple 开发证书并匹配已连接设备的签名团队）。
- **命令行**：
  ```bash
  swift build -c release
  .build/release/GameCenter --build-ios "$PWD/build/ios" "/path/to/your/game-library"
  ```

---

## 项目结构

```text
├── Package.swift                 # SwiftPM 工程定义（GameCenter / CoreHelper / SaveSupport）
├── Sources/
│   ├── GameCenter/               # macOS 主应用（SwiftUI 界面、资料库、刮削、内嵌播放器、iOS 打包）
│   ├── GameCenterCoreHelper/     # 独立进程 Libretro ARM64 运行宿主
│   ├── CRetroHost/               # C 层 Libretro 前端（视频/音频/手柄/核心选项桥接）
│   ├── GameCenterSaveSupport/    # Mac 与 iOS 共享的统一存档布局与迁移工具
│   ├── S2ArmStandaloneLauncher/  # Switch 独立应用启动器
│   └── S2ArmCheatMenu/           # 运行时金手指菜单动态库
├── Mobile/                       # iOS 客户端源码、虚拟多点触控手柄、Libretro/WiiU/Switch 播放器
├── Branding/                     # macOS 应用图标（GameCenter.icns）
├── Vendor/                       # Apple ID 签名辅助组件
├── scripts/                      # 核心拉取、macOS/iOS 打包与二进制依赖校验脚本
├── PRODUCT.md                    # 产品边界与设计原则
└── DESIGN.md                     # 视觉与交互规范
```

---

## 手柄快捷操作（主界面）

| 按键 | 功能 |
| --- | --- |
| 方向键 / 左摇杆 | 切换游戏或菜单项 |
| LB / RB | 切换主机平台 |
| X / Enter | 启动当前游戏 |
| A | 打开详情 / 确认选项 |
| Y | 打开选项菜单 |
| LT | 收藏 / 取消收藏 |
| B / Esc | 返回 |
| Menu / Options | 打开设置 |

---

## 致谢与第三方许可

本项目集成并调用了多个优秀开源模拟器与工具，包括但不限于：mGBA、DeSmuME、SwanStation、PPSSPP、Azahar、Dolphin、PCEE2 (PCSX2)、Cemu (`hauntek/Cemu` & `MuffinEMU`)、RPCS3、Vita3K、MoltenVK、S2Arm 与 NX2Apple。打包产物会在应用包内保留对应的第三方许可证与源码归档声明。本仓库仅包含前端与桥接代码，不包含任何游戏 ROM、受版权保护的 BIOS 或主机固件。
