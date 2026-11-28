#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
  print -u2 "usage: $0 OUTPUT_DIRECTORY"
  exit 64
fi

output_directory=$1
base_url=${GAME_CENTER_IOS_CORE_BASE_URL:-https://buildbot.libretro.com/nightly/apple/ios-arm64/latest}
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/game-center-ios-cores.XXXXXX")
trap 'rm -rf -- "$temporary_directory"' EXIT INT TERM

# 3DS (Citra.framework) and PSP (ppsspp.libretro) are staged from Manic EMU in fetch-ios-native.py.
archives=(
  gambatte_libretro_ios.dylib.zip
  mgba_libretro.dylib.zip
  desmume_libretro_ios.dylib.zip
  pcsx_rearmed_libretro_ios.dylib.zip
  dolphin_libretro.dylib.zip
)

curl_opts=(
  --fail --silent --show-error --location
  --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 20
)

mkdir -p -- "$temporary_directory/cores"
mkdir -p -- "$output_directory"

if [[ ! -s "$output_directory/pcee2_libretro.dylib" ]]; then
  /bin/bash "${0:A:h}/build-ios-pcee2.sh" "$output_directory"
fi

for archive in $archives; do
  module_name=${archive%.zip}
  if [[ -s "$output_directory/$module_name" ]]; then
    continue
  fi
  print "下载 iOS 核心：$module_name"
  curl "${curl_opts[@]}" --output "$temporary_directory/$archive" "$base_url/$archive"
  unzip -q -o "$temporary_directory/$archive" -d "$temporary_directory/cores" "$module_name"
  module="$temporary_directory/cores/$module_name"
  if [[ ! -s "$module" ]]; then
    print -u2 "核心压缩包中缺少文件：$module_name"
    exit 65
  fi
  if ! xcrun lipo -verify_arch arm64 "$module"; then
    print -u2 "不是 iOS arm64 核心：$module_name"
    exit 66
  fi
  build_platform=$(xcrun vtool -arch arm64 -show-build "$module")
  if ! grep -Eq 'platform[[:space:]]+IOS$|LC_VERSION_MIN_IPHONEOS' <<< "$build_platform"; then
    print -u2 "核心不是 iOS 真机二进制：$module_name"
    exit 66
  fi
  chmod 0755 "$module"
  # Persist each verified core immediately so retries never discard prior downloads.
  mv -f "$module" "$output_directory/$module_name"
done

if [[ ! -f "$output_directory/System/Wii/dolphin-emu/Sys/codehandler.bin" ]]; then
  print "下载 Wii (Dolphin) 系统资源"
  curl "${curl_opts[@]}" \
    --output "$temporary_directory/dolphin-source.tar.gz" \
    "https://codeload.github.com/libretro/dolphin/tar.gz/0863ee3"
  mkdir -p "$temporary_directory/dolphin-source"
  tar -xf "$temporary_directory/dolphin-source.tar.gz" -C "$temporary_directory/dolphin-source" --strip-components=1
  mkdir -p "$output_directory/System/Wii/dolphin-emu"
  ditto "$temporary_directory/dolphin-source/Data/Sys" "$output_directory/System/Wii/dolphin-emu/Sys"
  cp "$temporary_directory/dolphin-source/COPYING" "$output_directory/System/Wii/Dolphin-LICENSE"
fi
if [[ ! -d "$output_directory/System/PSP/PPSSPP/flash0" ]]; then
  print "下载 PSP (PPSSPP) 字体与系统资源"
  curl "${curl_opts[@]}" \
    --output "$temporary_directory/ppsspp-source.tar.gz" \
    "https://codeload.github.com/hrydgard/ppsspp/tar.gz/refs/tags/v1.20.4"
  mkdir -p "$temporary_directory/ppsspp-source" "$output_directory/System/PSP"
  tar -xf "$temporary_directory/ppsspp-source.tar.gz" -C "$temporary_directory/ppsspp-source" --strip-components=1
  ditto "$temporary_directory/ppsspp-source/assets" "$output_directory/System/PSP/PPSSPP"
fi
touch "$output_directory/.complete"
print "iOS 核心准备完成：$output_directory"
