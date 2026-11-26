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

archives=(
  gambatte_libretro_ios.dylib.zip
  mgba_libretro.dylib.zip
  desmume_libretro_ios.dylib.zip
  azahar_libretro.dylib.zip
  ppsspp_libretro.dylib.zip
  pcsx_rearmed_libretro_ios.dylib.zip
  dolphin_libretro.dylib.zip
  pcee2_libretro.dylib.zip
)

mkdir -p -- "$temporary_directory/cores"
mkdir -p -- "$output_directory"

for archive in $archives; do
  print "下载 iOS 核心：${archive%.zip}"
  curl --fail --silent --show-error --location --retry 3 --output "$temporary_directory/$archive" "$base_url/$archive"
  unzip -q -o "$temporary_directory/$archive" -d "$temporary_directory/cores" "${archive%.zip}"
done

typeset -a core_modules
core_modules=("$temporary_directory/cores"/*.dylib(N))
if (( ${#core_modules} != ${#archives} )); then
  print -u2 "核心数量不正确：期望 ${#archives}，实际 ${#core_modules}"
  exit 65
fi

for module in $core_modules; do
  if ! xcrun lipo -verify_arch arm64 "$module"; then
    print -u2 "不是 iOS arm64 核心：$module"
    exit 66
  fi
  build_platform=$(xcrun vtool -arch arm64 -show-build "$module")
  if ! grep -Eq 'platform[[:space:]]+IOS$|LC_VERSION_MIN_IPHONEOS' <<< "$build_platform"; then
    print -u2 "核心不是 iOS 真机二进制：$module"
    exit 66
  fi
  chmod 0755 "$module"
done

cp "$temporary_directory/cores/"*.dylib "$output_directory/"
if [[ ! -f "$output_directory/System/Wii/dolphin-emu/Sys/codehandler.bin" ]]; then
  curl --fail --silent --show-error --location --retry 3 --retry-all-errors \
    --output "$temporary_directory/dolphin-source.tar.gz" \
    "https://codeload.github.com/libretro/dolphin/tar.gz/0863ee3"
  mkdir -p "$temporary_directory/dolphin-source"
  tar -xf "$temporary_directory/dolphin-source.tar.gz" -C "$temporary_directory/dolphin-source" --strip-components=1
  mkdir -p "$output_directory/System/Wii/dolphin-emu"
  ditto "$temporary_directory/dolphin-source/Data/Sys" "$output_directory/System/Wii/dolphin-emu/Sys"
  cp "$temporary_directory/dolphin-source/COPYING" "$output_directory/System/Wii/Dolphin-LICENSE"
fi
if [[ ! -d "$output_directory/System/PSP/PPSSPP/flash0" ]]; then
  curl --fail --silent --show-error --location --retry 3 --retry-all-errors \
    --output "$temporary_directory/ppsspp-source.tar.gz" \
    "https://codeload.github.com/hrydgard/ppsspp/tar.gz/refs/tags/v1.20.4"
  mkdir -p "$temporary_directory/ppsspp-source" "$output_directory/System/PSP"
  tar -xf "$temporary_directory/ppsspp-source.tar.gz" -C "$temporary_directory/ppsspp-source" --strip-components=1
  ditto "$temporary_directory/ppsspp-source/assets" "$output_directory/System/PSP/PPSSPP"
fi
touch "$output_directory/.complete"
print "iOS 核心准备完成：$output_directory"
