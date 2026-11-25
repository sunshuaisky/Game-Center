#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
  print -u2 "usage: $0 OUTPUT_DIRECTORY"
  exit 64
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
output_directory=$1
base_url=${GAME_CENTER_MAC_CORE_BASE_URL:-https://buildbot.libretro.com/nightly/apple/osx/arm64/latest}
cores=(
  mgba_libretro.dylib
  desmume_libretro.dylib
  swanstation_libretro.dylib
  ppsspp_libretro.dylib
  azahar_libretro.dylib
  dolphin_libretro.dylib
  pcee2_libretro.dylib
)

mkdir -p -- "$output_directory"

missing=()
for core in $cores; do
  if [[ ! -f "$output_directory/$core" ]]; then
    missing+=("$core")
  fi
done

if (( ${#missing} > 0 )); then
  if [[ -n "${GAME_CENTER_MAC_CORE_DIR:-}" && -d "$GAME_CENTER_MAC_CORE_DIR" ]]; then
    for core in $missing; do
      if [[ ! -f "$GAME_CENTER_MAC_CORE_DIR/$core" ]]; then
        print -u2 "离线核心目录缺少：$core"
        exit 65
      fi
      cp "$GAME_CENTER_MAC_CORE_DIR/$core" "$output_directory/$core"
      chmod 0755 "$output_directory/$core"
    done
  else
    temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/game-center-mac-cores.XXXXXX")
    trap 'rm -rf -- "$temporary_directory"' EXIT INT TERM
    mkdir -p -- "$temporary_directory/cores"

    for core in $missing; do
      archive="${core}.zip"
      print "下载 macOS 核心：$core"
      curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 \
        --output "$temporary_directory/$archive" "$base_url/$archive"
      unzip -q -o "$temporary_directory/$archive" -d "$temporary_directory/cores" "$core"
    done

    for core in $missing; do
      module="$temporary_directory/cores/$core"
      if [[ ! -f "$module" ]]; then
        print -u2 "解压后缺少核心：$core"
        exit 65
      fi
      if ! xcrun lipo -verify_arch arm64 "$module"; then
        print -u2 "不是 macOS arm64 核心：$module"
        exit 66
      fi
      build_platform=$(xcrun vtool -arch arm64 -show-build "$module")
      if ! grep -Eq 'platform[[:space:]]+MACOS$|LC_VERSION_MIN_MACOSX' <<< "$build_platform"; then
        print -u2 "核心不是 macOS 二进制：$module"
        exit 66
      fi
      chmod 0755 "$module"
      cp "$module" "$output_directory/$core"
    done
  fi
else
  print "Using cached macOS Libretro cores in $output_directory"
fi

# Stage MoltenVK (arm64/universal Vulkan -> Metal translation layer) from kept Cemu/Vita3K bundles.
if [[ ! -f "$output_directory/libMoltenVK.dylib" ]]; then
  for candidate in \
    "$ROOT_DIR/build/emulators/Emulators/Cemu.app/Contents/Frameworks/libMoltenVK.dylib" \
    "$ROOT_DIR/build/emulators/Emulators/Vita3K.app/Contents/Frameworks/libMoltenVK.dylib"; do
    if [[ -f "$candidate" ]]; then
      cp "$candidate" "$output_directory/libMoltenVK.dylib"
      chmod 0755 "$output_directory/libMoltenVK.dylib"
      break
    fi
  done
fi

# Stage Dolphin Sys directory required by dolphin_libretro.dylib.
if [[ ! -f "$output_directory/System/Wii/dolphin-emu/Sys/codehandler.bin" ]]; then
  tmp_wii=$(mktemp -d "${TMPDIR:-/tmp}/game-center-dolphin-sys.XXXXXX")
  trap 'rm -rf -- "$tmp_wii"' EXIT INT TERM
  curl --fail --silent --show-error --location --retry 3 --retry-all-errors \
    --output "$tmp_wii/dolphin-source.tar.gz" \
    "https://codeload.github.com/libretro/dolphin/tar.gz/0863ee3"
  mkdir -p "$tmp_wii/src" "$output_directory/System/Wii/dolphin-emu"
  tar -xf "$tmp_wii/dolphin-source.tar.gz" -C "$tmp_wii/src" --strip-components=1
  ditto "$tmp_wii/src/Data/Sys" "$output_directory/System/Wii/dolphin-emu/Sys"
  rm -rf -- "$tmp_wii"
fi

# Stage PPSSPP assets directory required by ppsspp_libretro.dylib.
if [[ ! -d "$output_directory/System/PSP/PPSSPP/flash0" ]]; then
  tmp_psp=$(mktemp -d "${TMPDIR:-/tmp}/game-center-ppsspp-assets.XXXXXX")
  trap 'rm -rf -- "$tmp_psp"' EXIT INT TERM
  curl --fail --silent --show-error --location --retry 3 --retry-all-errors \
    --output "$tmp_psp/ppsspp-source.tar.gz" \
    "https://codeload.github.com/hrydgard/ppsspp/tar.gz/refs/tags/v1.20.4"
  mkdir -p "$tmp_psp/src" "$output_directory/System/PSP"
  tar -xf "$tmp_psp/ppsspp-source.tar.gz" -C "$tmp_psp/src" --strip-components=1
  ditto "$tmp_psp/src/assets" "$output_directory/System/PSP/PPSSPP"
  rm -rf -- "$tmp_psp"
fi

touch "$output_directory/.complete"
print "macOS 核心准备完成：$output_directory"
