#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STAGING="$ROOT_DIR/build/emulators"

# GB/GBC/GBA/NDS/PS1/PSP/3DS/Wii/PS2 now run natively inside Game Center's
# ARM64 GameCenterCoreHelper via Libretro cores (scripts/fetch-mac-cores.sh).
# Only standalone desktop emulators without viable embedded cores (Wii U, PS3,
# PS Vita) and the Switch S2Arm engine are fetched as standalone macOS bundles.
python3 "$ROOT_DIR/scripts/fetch-mac-systems.py"

mkdir -p "$STAGING/ThirdPartyLicenses"
cat > "$STAGING/ThirdPartyLicenses/README.txt" <<'NOTICE'
Third-party emulators & embedded Libretro cores bundled with Game Center:

Embedded macOS ARM64 Libretro cores (Contents/Resources/Cores/, executed in GameCenterCoreHelper):
- mGBA (GB / GBC / GBA): https://github.com/mgba-emu/mgba
- DeSmuME (Nintendo DS): https://github.com/libretro/desmume
- SwanStation (PlayStation): https://github.com/libretro/swanstation
- PPSSPP (PlayStation Portable): https://github.com/hrydgard/ppsspp
- Azahar (Nintendo 3DS): https://github.com/azahar-emu/azahar
- Dolphin (Nintendo Wii): https://github.com/libretro/dolphin
- PCEE2 / PCSX2 (PlayStation 2, ARM64): https://github.com/WizzardSK/pcee2-libretro
- MoltenVK (Vulkan -> Metal): https://github.com/KhronosGroup/MoltenVK

Standalone macOS ARM64/Universal emulators (Contents/Resources/Emulators/):
- Cemu (Wii U): https://github.com/hauntek/Cemu
- RPCS3 (PlayStation 3): https://github.com/RPCS3/rpcs3
- Vita3K (PlayStation Vita): https://github.com/Vita3K/Vita3K

Switch Engine (Contents/Resources/S2ArmEngine/):
- S2Arm: https://github.com/jhaizhou-ops/S2Arm

Corresponding upstream source archives for standalone emulators are included in ../ThirdPartySource.
NOTICE

echo "Prepared standalone macOS emulator builds in $STAGING"
