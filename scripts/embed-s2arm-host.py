"""Embed the installed, manifest-verified S2Arm shell with Game Center's library.

The official executable remains the process host (including its early address
reservation). Only a dependency on our signed UI/launcher framework is added.
No instructions, signature checks, or runtime protections are patched.
"""
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys


def add_dependency(binary, name):
    data = bytearray(binary.read_bytes())
    magic, cpu, _, kind, count, size, _, _ = struct.unpack_from("<8I", data)
    if magic != 0xFEEDFACF or cpu != 0x100000C or kind != 2:
        raise ValueError("S2Arm shell must be an arm64 Mach-O executable")
    cursor, first_section = 32, len(data)
    for _ in range(count):
        command, length = struct.unpack_from("<II", data, cursor)
        if length < 8 or cursor + length > 32 + size:
            raise ValueError("Invalid Mach-O load commands")
        if command == 0x19:
            sections = struct.unpack_from("<I", data, cursor + 64)[0]
            for index in range(sections):
                offset = struct.unpack_from("<I", data, cursor + 72 + index * 80 + 48)[0]
                if offset:
                    first_section = min(first_section, offset)
        cursor += length
    encoded = name.encode() + b"\0"
    length = (24 + len(encoded) + 7) & ~7
    if cursor != 32 + size or cursor + length > first_section or any(data[cursor:cursor + length]):
        raise ValueError("S2Arm shell has insufficient load-command padding")
    command = struct.pack("<6I", 0xC, length, 24, 0, 0x10000, 0x10000) + encoded
    data[cursor:cursor + length] = command.ljust(length, b"\0")
    struct.pack_into("<II", data, 16, count + 1, size + length)
    binary.write_bytes(data)


def embed(shell, app):
    manifest = json.loads((shell / "manifest.json").read_text())
    if manifest.get("target") != "ios-shell":
        raise ValueError("Not an S2Arm iOS shell")
    root = shell / "root"
    symbols = subprocess.check_output(["xcrun", "nm", "-gU", str(root / "S2Arm")], text=True)
    for symbol in ["_s2a_shell_play", "_s2a_launch_ctx_get", "_s2a_host_stop", "_s2a_host_resume",
                   "_s2a_host_session_state", "_OBJC_CLASS_$_S2ASceneDelegate"]:
        if not any(line.endswith(" " + symbol) for line in symbols.splitlines()):
            raise ValueError(f"S2Arm shell is missing the required interface: {symbol}")
    for item in manifest["files"]:
        relative = Path(item["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Invalid shell manifest path")
        path = root / relative
        if hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
            raise ValueError(f"S2Arm shell verification failed: {relative}")
    # The widget belongs to the official launcher and is not used by Game Center.
    for item in root.iterdir():
        if item.name in {"Info.plist", "PlugIns", "_CodeSignature", "embedded.mobileprovision"}:
            continue
        destination = app / ("GameCenter" if item.name == "S2Arm" else item.name)
        if item.is_dir():
            shutil.copytree(item, destination, dirs_exist_ok=True)
        else:
            shutil.copy2(item, destination)
    add_dependency(app / "GameCenter", "@executable_path/Frameworks/GameCenterMobile.framework/GameCenterMobile")
    (app / "Games").mkdir(exist_ok=True)
    (app / "s2a_catalogue.json").write_text('{"schema":1,"games":[]}')
    (app / "S2Arm-runtime.json").write_text(json.dumps(manifest["details"]))
    import plistlib
    with (root / "Info.plist").open("rb") as f:
        official = plistlib.load(f)
    with (app / "Info.plist").open("rb") as f:
        info = plistlib.load(f)
    for key in ["S2ACommit", "CADisableMinimumFrameDurationOnPhone", "LSSupportsGameMode",
                "GCSupportsGameMode", "LSApplicationCategoryType", "UIRequiresFullScreen",
                "NSBluetoothAlwaysUsageDescription", "NSBonjourServices", "NSLocalNetworkUsageDescription",
                "UISupportedExternalAccessoryProtocols"]:
        if key in official:
            info[key] = official[key]
    with (app / "Info.plist").open("wb") as f:
        plistlib.dump(info, f)


if __name__ == "__main__":
    embed(Path(sys.argv[1]), Path(sys.argv[2]))
