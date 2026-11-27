#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Game Center"
EXECUTABLE="GameCenter"
APP_PATH="$ROOT_DIR/build/$APP_NAME.app"

cd "$ROOT_DIR"
"$ROOT_DIR/scripts/fetch_emulators.sh"
"$ROOT_DIR/scripts/fetch-mac-cores.sh" "$ROOT_DIR/build/mac-cores"
swift build -c release

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Helpers" "$APP_PATH/Contents/Resources/Tools" "$APP_PATH/Contents/Resources/Cores"
cp "$ROOT_DIR/Branding/GameCenter.icns" "$APP_PATH/Contents/Resources/GameCenter.icns"
cp "$ROOT_DIR/.build/release/$EXECUTABLE" "$APP_PATH/Contents/MacOS/$EXECUTABLE"
cp "$ROOT_DIR/.build/release/GameCenterCoreHelper" "$APP_PATH/Contents/Helpers/GameCenterCoreHelper"
chmod 0755 "$APP_PATH/Contents/Helpers/GameCenterCoreHelper"
cp "$ROOT_DIR/.build/release/S2ArmStandaloneLauncher" "$APP_PATH/Contents/Resources/Tools/S2ArmStandaloneLauncher"
cp "$ROOT_DIR/build/mac-cores/"*.dylib "$APP_PATH/Contents/Resources/Cores/"
if [[ -d "$ROOT_DIR/build/mac-cores/System" ]]; then
  ditto "$ROOT_DIR/build/mac-cores/System" "$APP_PATH/Contents/Resources/Cores/System"
fi
xcrun clang -fobjc-arc -dynamiclib -arch arm64 -mmacosx-version-min=14.0 \
  -framework AppKit -framework Foundation \
  "$ROOT_DIR/Sources/S2ArmCheatMenu/S2ArmCheatMenu.m" \
  -o "$APP_PATH/Contents/Resources/Tools/S2ArmCheatMenu.dylib"
codesign --force --sign - "$APP_PATH/Contents/Resources/Tools/S2ArmCheatMenu.dylib"
mkdir -p "$APP_PATH/Contents/Resources/Emulators"
for emulator in Vita3K RPCS3 Cemu; do
  ditto "$ROOT_DIR/build/emulators/Emulators/$emulator.app" "$APP_PATH/Contents/Resources/Emulators/$emulator.app"
done
python3 "$ROOT_DIR/scripts/verify-bundled-emulators.py" \
  "$APP_PATH/Contents/Resources/Emulators" \
  "$APP_PATH/Contents/Resources/Cores" \
  "$APP_PATH/Contents/Helpers/GameCenterCoreHelper"

# S2Arm engine travels inside the bundle so a fresh Mac can install it offline.
if [[ -d "$ROOT_DIR/build/emulators/Emulators/S2Arm.app/Contents/Resources" ]]; then
  ditto "$ROOT_DIR/build/emulators/Emulators/S2Arm.app/Contents/Resources" "$APP_PATH/Contents/Resources/S2ArmEngine"
  s2arm_archives=("$ROOT_DIR"/build/emulators/ThirdPartySource/S2Arm-*.tar.gz)
  if [[ -f "${s2arm_archives[0]}" ]]; then
    s2arm_version="$(basename "${s2arm_archives[0]}" | sed 's/^S2Arm-//; s/\.tar\.gz$//')"
    printf '%s\n' "$s2arm_version" > "$APP_PATH/Contents/Resources/S2ArmEngine/engine-version.txt"
  fi
fi
# Locally staged BIOS / firmware seeds the emulators on first run. Personal
# backups only — a package containing them must not be redistributed.
if [[ -d "$ROOT_DIR/build/system-files" ]]; then
  ditto "$ROOT_DIR/build/system-files" "$APP_PATH/Contents/Resources/SystemFiles"
fi
for directory in ThirdPartyLicenses ThirdPartySource; do
  mkdir -p "$APP_PATH/Contents/Resources/$directory"
  for entry in "$ROOT_DIR/build/emulators/$directory/"*; do
    case "$(basename "$entry")" in
      README.txt|Vita3K*|RPCS3*|Cemu*|S2Arm*)
        ditto "$entry" "$APP_PATH/Contents/Resources/$directory/$(basename "$entry")" ;;
    esac
  done
done
ditto "$ROOT_DIR/.build/release/GameCenter_GameCenter.bundle" "$APP_PATH/Contents/Resources/GameCenter_GameCenter.bundle"
ditto "$ROOT_DIR/Sources/GameCenter/Resources/en.lproj" "$APP_PATH/Contents/Resources/en.lproj"
ditto "$ROOT_DIR/Sources/GameCenter/Resources/ja.lproj" "$APP_PATH/Contents/Resources/ja.lproj"
ditto "$ROOT_DIR/Sources/GameCenter/Resources/zh-Hans.lproj" "$APP_PATH/Contents/Resources/zh-Hans.lproj"
MOBILE_BUILD="$APP_PATH/Contents/Resources/MobileBuild"
mkdir -p "$MOBILE_BUILD/scripts" "$MOBILE_BUILD/Sources/GameCenter"
ditto "$ROOT_DIR/Mobile" "$MOBILE_BUILD/Mobile"
rm -f "$MOBILE_BUILD/Mobile/README.md"
cp "$ROOT_DIR/scripts/build-ios-app.sh" "$ROOT_DIR/scripts/fetch-ios-native.py" "$ROOT_DIR/scripts/fetch-ios-cores.sh" "$ROOT_DIR/scripts/prepare-nx-shell.sh" "$MOBILE_BUILD/scripts/"
cp "$ROOT_DIR/scripts/apple-id-sign.py" "$ROOT_DIR/scripts/export-s2arm-ios.py" "$MOBILE_BUILD/scripts/"
cp "$ROOT_DIR/scripts/cache_maintenance.py" "$ROOT_DIR/scripts/embed-s2arm-host.py" "$ROOT_DIR/scripts/prepare-s2arm-exit-host.py" "$MOBILE_BUILD/scripts/"
ditto "$ROOT_DIR/Vendor/AppleSigning" "$MOBILE_BUILD/AppleSigning"
mkdir -p "$MOBILE_BUILD/scripts/patches"
cp "$ROOT_DIR/scripts/patches"/s2arm-session-exit*.patch "$MOBILE_BUILD/scripts/patches/"
if [[ -d "$ROOT_DIR/build/mobile-host/Shell" ]]; then
  ditto "$ROOT_DIR/build/mobile-host/Shell" "$MOBILE_BUILD/S2ArmExitHost"
fi
if [[ -d "$ROOT_DIR/build/mobile-host/versions" ]]; then
  ditto "$ROOT_DIR/build/mobile-host/versions" "$MOBILE_BUILD/S2ArmExitHosts"
fi
if [[ -d "$ROOT_DIR/build/ios-cores" ]]; then
  ditto "$ROOT_DIR/build/ios-cores" "$MOBILE_BUILD/iOSCores"
fi
mkdir -p "$MOBILE_BUILD/Sources/GameCenterSaveSupport"
cp "$ROOT_DIR/Sources/GameCenterSaveSupport/GameSaveLayout.swift" "$MOBILE_BUILD/Sources/GameCenterSaveSupport/"
cp "$ROOT_DIR/Sources/GameCenter/MobileLibraryFormat.swift" "$MOBILE_BUILD/Sources/GameCenter/"
cp "$ROOT_DIR/Sources/GameCenter/GameMetadataPlatform.swift" "$ROOT_DIR/Sources/GameCenter/GameTitleMatcher.swift" "$ROOT_DIR/Sources/GameCenter/MetadataRefreshPolicy.swift" "$ROOT_DIR/Sources/GameCenter/GameMetadataService.swift" "$ROOT_DIR/Sources/GameCenter/CloudSaveSyncView.swift" "$ROOT_DIR/Sources/GameCenter/CloudSaveDirectorySync.swift" "$ROOT_DIR/Sources/GameCenter/CloudSaveLocation.swift" "$MOBILE_BUILD/Sources/GameCenter/"

cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>GameCenter</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ja</string><string>zh-Hans</string></array>
  <key>CFBundleIdentifier</key><string>com.phoenixicarus.gamecenter</string>
  <key>CFBundleName</key><string>Game Center</string>
  <key>CFBundleIconFile</key><string>GameCenter.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSMicrophoneUsageDescription</key><string>Game Center 中的 Nintendo DS 游戏可使用麦克风模拟掌机的吹气和语音输入。</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSRequiresAquaSystemAppearance</key><false/>
</dict>
</plist>
PLIST

codesign --force --deep --preserve-metadata=entitlements --sign - "$APP_PATH"

echo "Built: $APP_PATH"
