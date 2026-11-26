#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
request="$1"
output="$2"
work="$(mktemp -d "${TMPDIR:-/tmp}/game-center-ios.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
app="$work/Payload/Game Center.app"
mkdir -p "$app/Frameworks"
cp "$root/Mobile/Info.plist" "$app/Info.plist"
cp "$request/platforms.json" "$request/catalog.json" "$app/"
/usr/bin/python3 - "$request/catalog.json" "$app" <<'PY'
from concurrent.futures import ThreadPoolExecutor
import json, os, pathlib, subprocess, sys, uuid
artwork = pathlib.Path.home() / 'Library/Application Support/Game Center/Artwork'
destination = pathlib.Path(sys.argv[2]) / 'Covers'
jobs = []
for item in json.loads(pathlib.Path(sys.argv[1]).read_bytes()):
    try:
        key = str(uuid.UUID(item['id'])).upper()
    except (ValueError, KeyError):
        continue
    source = artwork / (key + '.jpg')
    if source.is_file():
        jobs.append((source, destination / (key + '.jpg')))
if jobs:
    destination.mkdir(exist_ok=True)
    def resize(pair):
        src, dst = pair
        subprocess.run(['/usr/bin/sips', '-Z', '512', '-s', 'format', 'jpeg', str(src), '--out', str(dst)],
                       stdout=subprocess.DEVNULL)
    with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 4)) as pool:
        list(pool.map(resize, jobs))
PY

sdk="${GAME_CENTER_IOS_SDK:-iphoneos}"
target="arm64-apple-ios26.0"
if [[ "$sdk" == iphonesimulator ]]; then
  target="$target-simulator"
fi
sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
printf 'GC_MOBILE_STAGE\t2\t正在准备 NX2Apple 共享运行环境\n'
nx_root="$(/bin/bash "$root/scripts/prepare-nx-shell.sh")"
nx_app="$nx_root/frontend-ios/Shell/App"
cp "$nx_root/LICENSE" "$app/NX2Apple-LICENSE"
cp "$nx_root/NOTICE" "$app/NX2Apple-NOTICE"
cp "$root/Mobile/NXShellLibrary.h" "$work/DmShell-Swift.h"
cat "$root/Mobile/RetroCore.h" "$nx_app/ShellEngine.h" "$root/Mobile/S2ArmRuntime.h" > "$work/GameCenter-Bridging.h"
printf 'GC_MOBILE_STAGE\t3\t正在编译游戏库和运行宿主\n'
xcrun --sdk "$sdk" clang -target "$target" -isysroot "$sdk_path" -O2 \
  -Wall -Wextra -c "$root/Mobile/RetroCore.c" -o "$work/RetroCore.o"
cp "$nx_app/ShellMain.m" "$work/ShellMain.m"
cat >> "$work/ShellMain.m" <<'OBJC'

void gc_nx_set_library_controller(UIViewController *controller) { g_library_vc = controller; }
void gc_nx_focus(int state) { if (g_focus) g_focus(state); }
UIInterfaceOrientationMask gc_nx_orientations(UITraitCollection *traits) { return shell_orientations(traits); }
OBJC
host_flags=(-DGC_NX_PRIMARY_HOST=1)
swift_flags=(-module-name GameCenterMobile)
binary="$app/GameCenter"
if [[ "$sdk" == iphoneos ]]; then
  s2arm_root="${GAME_CENTER_S2ARM_ROOT:-$HOME/Library/Application Support/Game Center/SwitchEngines/S2Arm}"
  [[ -f "$s2arm_root/Shell/manifest.json" ]] || {
    echo '请先在 Switch 构建设置中安装或更新 S2Arm 内置引擎，再生成包含运行时的 IPA。' >&2
    exit 1
  }
  printf 'GC_MOBILE_DETAIL\t正在校验并嵌入 S2Arm 共享宿主\n'
  s2arm_shell="$(/usr/bin/python3 "$root/scripts/prepare-s2arm-exit-host.py" "$s2arm_root")"
  /usr/bin/python3 "$root/scripts/embed-s2arm-host.py" "$s2arm_shell" "$app"
  cp "$s2arm_root/Engine/LICENSE" "$app/S2Arm-LICENSE"
  if [[ -d "$s2arm_root/Licenses" ]]; then
    ditto "$s2arm_root/Licenses" "$app/S2Arm-Licenses"
  fi
  if [[ -f "$s2arm_root/Engine/shell/NOTICE" ]]; then
    cp "$s2arm_root/Engine/shell/NOTICE" "$app/S2Arm-Shell-NOTICE"
  fi
  /usr/libexec/PlistBuddy -c 'Set :UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication:0:UISceneDelegateClassName S2ASceneDelegate' "$app/Info.plist"
  host_flags=(-Dmain=gc_nx_unused_main)
  framework="$app/Frameworks/GameCenterMobile.framework"
  mkdir -p "$framework"
  binary="$framework/GameCenterMobile"
  swift_flags=(-emit-library -module-name GameCenterMobile -Xlinker -install_name -Xlinker '@rpath/GameCenterMobile.framework/GameCenterMobile')
  /usr/libexec/PlistBuddy -c 'Clear dict' \
    -c 'Add CFBundleIdentifier string com.phoenixicarus.gamecenter.mobile-runtime' \
    -c 'Add CFBundleExecutable string GameCenterMobile' -c 'Add CFBundlePackageType string FMWK' \
    -c 'Add CFBundleVersion string 1' -c 'Add CFBundleShortVersionString string 1.0' "$framework/Info.plist"
fi
xcrun --sdk "$sdk" clang -target "$target" -isysroot "$sdk_path" -fobjc-arc -O2 -I "$work" -I "$nx_app" \
  "${host_flags[@]}" -c "$work/ShellMain.m" -o "$work/NXShellMain.o"
xcrun --sdk "$sdk" clang -target "$target" -isysroot "$sdk_path" -fobjc-arc -O2 -I "$root/Mobile" \
  -c "$root/Mobile/S2ArmRuntime.m" -o "$work/S2ArmRuntime.o"
xcrun --sdk "$sdk" swiftc -target "$target" -sdk "$sdk_path" -O -parse-as-library "${swift_flags[@]}" \
  -import-objc-header "$work/GameCenter-Bridging.h" \
  "$root/Sources/GameCenter/GameMetadataPlatform.swift" "$root/Sources/GameCenter/GameTitleMatcher.swift" "$root/Sources/GameCenter/GameMetadataService.swift" "$root/Sources/GameCenterSaveSupport/GameSaveLayout.swift" "$root/Sources/GameCenter/MobileLibraryFormat.swift" "$root/Sources/GameCenter/CloudSaveSyncView.swift" "$root/Sources/GameCenter/CloudSaveDirectorySync.swift" "$root/Sources/GameCenter/CloudSaveLocation.swift" "$root"/Mobile/*.swift "$work/RetroCore.o" "$work/NXShellMain.o" "$work/S2ArmRuntime.o" \
  -o "$binary"

printf 'GC_MOBILE_STAGE\t4\t正在准备 iOS 模拟器核心，首次生成需要下载\n'
if [[ "$sdk" == iphoneos ]]; then
  core_dir="${GAME_CENTER_IOS_CORE_DIR:-${XDG_CACHE_HOME:-$HOME/Library/Caches}/GameCenter/iOS-Cores}"
  bundled_core_dir="$root/build/ios-cores"
  [[ -d "$bundled_core_dir" ]] || bundled_core_dir="$root/iOSCores"
  /usr/bin/python3 - "$request/platforms.json" <<'PYMODULES' > "$work/modules"
import json, sys
for name in sorted({item["module"] for item in json.load(open(sys.argv[1])) if not item.get("runtime")}):
    if not name.endswith(".dylib"):
        raise SystemExit("原生核心缺少运行类型配置：" + name)
    print(name)
PYMODULES
  missing_core=0
  while IFS= read -r module; do
    if [[ ! -s "$bundled_core_dir/$module" && ! -s "$core_dir/$module" ]]; then missing_core=1; fi
    if [[ "$module" == dolphin_libretro.dylib && ! -f "$core_dir/System/Wii/dolphin-emu/Sys/codehandler.bin" ]]; then missing_core=1; fi
    if [[ "$module" == ppsspp_libretro.dylib && ! -d "$core_dir/System/PSP/PPSSPP/flash0" ]]; then missing_core=1; fi
  done < "$work/modules"
  if [[ "$missing_core" == 1 && -z "${GAME_CENTER_IOS_CORE_DIR:-}" ]]; then
    /bin/zsh "$root/scripts/fetch-ios-cores.sh" "$core_dir"
  fi
  while IFS= read -r module; do
    printf 'GC_MOBILE_DETAIL\t正在嵌入 %s\n' "$module"
    if [[ -s "$bundled_core_dir/$module" ]]; then
      source="$bundled_core_dir/$module"
    else
      source="$core_dir/$module"
    fi
    platform="$(xcrun vtool -arch arm64 -show-build "$source")"
    if ! grep -Eq 'platform[[:space:]]+IOS$|LC_VERSION_MIN_IPHONEOS' <<< "$platform"; then
      echo "核心不是 iOS 真机二进制：$module" >&2
      exit 1
    fi
    name="${module%.dylib}"
    framework="$app/Frameworks/$name.framework"
    mkdir -p "$framework"
    cp "$source" "$framework/$name"
    chmod 755 "$framework/$name"
    /usr/libexec/PlistBuddy -c "Clear dict" \
      -c "Add CFBundleIdentifier string org.gamecenter.core.${name//_/-}" \
      -c "Add CFBundleExecutable string $name" -c 'Add CFBundlePackageType string FMWK' \
      -c 'Add CFBundleVersion string 1' -c 'Add CFBundleShortVersionString string 1.0' \
      "$framework/Info.plist"
  done < "$work/modules"
  if [[ -d "$core_dir/System" ]]; then
    ditto "$core_dir/System" "$app/CoreAssets"
  fi
  # BIOS and firmware staged for the Mac app travel along under CoreAssets.
  # The device copies them into its own folders, filling in only what is
  # missing (PhoneLibrary.mergeTree / PS3Player). Run from a source checkout
  # they are in build/system-files; from inside the Mac app bundle, where
  # this script is a copy, they are the bundle's own Resources/SystemFiles.
  system_files="$root/build/system-files"
  [[ -d "$system_files" ]] || system_files="$root/../SystemFiles"
  if [[ -d "$system_files/PS1BIOS" ]]; then
    mkdir -p "$app/CoreAssets/PS1"
    /usr/bin/python3 - "$system_files/PS1BIOS" "$app/CoreAssets/PS1" <<'PYPS1'
import hashlib, pathlib, shutil, sys
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
canonical = {
    "8dd7d5296a650fac7319bce665a6a53c": "scph5500.bin",
    "490f666e1afb15b7362b406ed1cea246": "scph5501.bin",
    "32736f17079d0b2b7024407c39bd3050": "scph5502.bin",
    "924e392ed05558ffdb115408c263dccf": "scph1001.bin",
    "c53ca5908936d412331790f4426c6c33": "psxonpsp660.bin",
}
written = set()
for item in sorted(src.iterdir()):
    if not item.is_file():
        continue
    digest = hashlib.md5(item.read_bytes()).hexdigest()
    target_name = canonical.get(digest)
    if target_name and target_name not in written:
        shutil.copy2(item, dst / target_name)
        written.add(target_name)
if not written:
    for item in sorted(src.iterdir()):
        if item.is_file() and item.suffix.lower() == ".bin":
            shutil.copy2(item, dst / item.name.lower())
PYPS1
  fi
  if [[ -d "$system_files/PS2BIOS" ]]; then
    mkdir -p "$app/CoreAssets/PS2/pcsx2/bios"
    for file in "$system_files/PS2BIOS"/*; do
      [[ -f "$file" ]] || continue
      case "${file##*.}" in
        bin|BIN|rom0|ROM0|rom1|ROM1|rom2|ROM2|erom|EROM|mec|MEC|nvm|NVM) cp "$file" "$app/CoreAssets/PS2/pcsx2/bios/" ;;
      esac
    done
  fi
  if [[ -d "$system_files/WiiU" ]]; then
    ditto "$system_files/WiiU" "$app/CoreAssets/WiiU"
  fi
  native_runtimes=$(/usr/bin/python3 - "$request/platforms.json" <<'PYNATIVE'
import json, sys
print(",".join(sorted({p["runtime"] for p in json.load(open(sys.argv[1])) if p.get("runtime") in {"cemu"}})))
PYNATIVE
)
  if [[ -n "$native_runtimes" ]]; then
    /usr/bin/python3 "$root/scripts/fetch-ios-native.py" "${GAME_CENTER_IOS_NATIVE_CACHE:-$HOME/Library/Caches/GameCenter/iOS-Native}" "$app" "$native_runtimes"
  fi
fi

# Compile after embedding the host so Game Center's icon takes precedence.
xcrun --sdk "$sdk" actool "$root/Mobile/Assets.xcassets" \
  --compile "$app" --platform "$sdk" --minimum-deployment-target 26.0 \
  --target-device iphone --target-device ipad --app-icon AppIcon \
  --output-partial-info-plist "$work/app-icon-info.plist"
/usr/bin/python3 - "$app/Info.plist" "$work/app-icon-info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as source:
    info = plistlib.load(source)
with open(sys.argv[2], 'rb') as source:
    info.update(plistlib.load(source))
with open(sys.argv[1], 'wb') as destination:
    plistlib.dump(info, destination)
PY

printf 'GC_MOBILE_STAGE\t5\t正在签名应用并校验核心\n'
identity="${GAME_CENTER_IOS_SIGN_IDENTITY:--}"
sign_args=(--force --sign "$identity")
if [[ -n "${GAME_CENTER_IOS_PROFILE:-}" ]]; then
  [[ "$identity" != - ]] || { echo "提供描述文件时，请同时设置 GAME_CENTER_IOS_SIGN_IDENTITY。" >&2; exit 1; }
  security cms -D -i "$GAME_CENTER_IOS_PROFILE" -o "$work/profile.plist"
  plutil -extract Entitlements xml1 -o "$work/entitlements.plist" "$work/profile.plist"
  application_id="$(plutil -extract application-identifier raw "$work/entitlements.plist")"
  bundle_id="${GAME_CENTER_IOS_BUNDLE_ID:-com.phoenixicarus.gamecenter.ios}"
  [[ "${application_id#*.}" == "$bundle_id" || "${application_id#*.}" == '*' ]] || {
    echo "描述文件不匹配 $bundle_id" >&2
    exit 1
  }
  plutil -replace application-identifier -string "${application_id%%.*}.$bundle_id" "$work/entitlements.plist"
  /usr/bin/python3 - "$work/entitlements.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as source:
    entitlements = plistlib.load(source)
entitlements["keychain-access-groups"] = [
    entitlements["application-identifier"] if item.endswith(".*") else item
    for item in entitlements.get("keychain-access-groups", [])
]
# Keep only the entitlements used by the application.
used = {"application-identifier", "com.apple.developer.team-identifier", "get-task-allow", "keychain-access-groups",
        "com.apple.developer.kernel.increased-memory-limit"}
with open(path, "wb") as output:
    plistlib.dump({key: value for key, value in entitlements.items() if key in used}, output)
PY
  plutil -replace CFBundleIdentifier -string "$bundle_id" "$app/Info.plist"
  cp "$GAME_CENTER_IOS_PROFILE" "$app/embedded.mobileprovision"
  app_sign_args=(--entitlements "$work/entitlements.plist")
else
  app_sign_args=()
  if [[ "$sdk" == iphoneos ]]; then
    # Preserve the official host's memory entitlement in the unsigned export.
    # A real device signature must use a profile authorizing this capability.
    /usr/bin/python3 - "$work/entitlements.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "wb") as output:
    plistlib.dump({"com.apple.developer.kernel.increased-memory-limit": True}, output)
PY
    app_sign_args=(--entitlements "$work/entitlements.plist")
  fi
fi
sign_pids=()
for framework in "$app"/Frameworks/*.framework; do
  [[ -d "$framework" ]] || continue
  codesign "${sign_args[@]}" "$framework" &
  sign_pids+=($!)
done
for pid in "${sign_pids[@]}"; do
  wait "$pid"
done
if [[ ${#app_sign_args[@]} -gt 0 ]]; then
  codesign "${sign_args[@]}" "${app_sign_args[@]}" "$app"
else
  codesign "${sign_args[@]}" "$app"
fi
codesign --verify --deep --strict "$app"
printf 'GC_MOBILE_STAGE\t6\t正在压缩并写入输出目录\n'
if [[ "$sdk" == iphonesimulator ]]; then
  rm -rf "$output"
  ditto "$app" "$output"
else
  output_stage="$(mktemp "$(dirname "$output")/.game-center-ipa.XXXXXX")"
  trap 'rm -rf -- "$work"; rm -f -- "$output_stage"' EXIT
  ditto -c -k --norsrc --keepParent "$work/Payload" "$output_stage"
  chmod 644 "$output_stage"
  mv -f "$output_stage" "$output"
fi
