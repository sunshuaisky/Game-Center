#!/bin/bash
# Build the signed-code-free PS2 interpreter and its Metal shaders for iPhone.
set -euo pipefail
output=$1
scripts=$(cd "$(dirname "$0")" && pwd)
revision=cdb18a66f4c59167d032ad12eadb7fceb2fcf3cd
mkdir -p "$output"
output=$(cd "$output" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/pcee2-ios.XXXXXX")
trap 'rm -rf "$work"' EXIT
source_dir="$work/pcee2"
prefix="$work/deps"
git init -q "$source_dir"
git -C "$source_dir" fetch -q --depth 1 https://github.com/WizzardSK/pcee2-libretro.git "$revision"
git -C "$source_dir" checkout -q --detach FETCH_HEAD
cd "$source_dir"
git submodule update --init --recursive --depth 1
git apply "$scripts/patches/pcee2-ios-metal.patch"
# Match the core's deployment target when building shaderc with modern Xcode.
sed -i '' 's/-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0/-DCMAKE_OSX_DEPLOYMENT_TARGET=16.0/g' pcee2-libretro/scripts/build-deps-macos.sh
APPLE_PLATFORM=ios OSX_ARCH=arm64 bash pcee2-libretro/scripts/build-deps-macos.sh "$prefix"
cmake -G Ninja -S . -B build/ios-arm64 -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_C_FLAGS=-DIOS -DCMAKE_CXX_FLAGS=-DIOS -DIOS=ON \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DENABLE_LIBRETRO=ON -DENABLE_QT_UI=OFF -DENABLE_TESTS=OFF \
    -DDISABLE_ADVANCE_SIMD=ON -DSHADERC_STATIC=ON -DUSE_VULKAN=OFF -DCMAKE_MACOSX_BUNDLE=OFF \
    -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_FIND_ROOT_PATH="$prefix" -DSHADERC_LIBRARY="$prefix/lib/libshaderc_combined.a"
cmake --build build/ios-arm64 --parallel 8 --target pcee2_libretro
cp build/ios-arm64/bin/pcee2_libretro.dylib "$output/pcee2_libretro.dylib.new"
mv "$output/pcee2_libretro.dylib.new" "$output/pcee2_libretro.dylib"
