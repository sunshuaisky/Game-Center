#!/usr/bin/env python3
"""Stage pinned native iOS engines, resources and upstream licence notices."""
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile

cache, destination = map(Path, sys.argv[1:3])
requested = [r.strip() for r in sys.argv[3].split(",") if r.strip()] if len(sys.argv) > 3 else ["cemu"]
cache.mkdir(parents=True, exist_ok=True)
destination.mkdir(parents=True, exist_ok=True)
engines = {
    "cemu": (
        "MuffinEMU-v11.8", "MuffinEMU/Muffin-EMU", "v11.8", "MuffinEMU.ipa",
        "62ec179f38ff124b62f4cb192d6d8c2a0363e9e74e8d188a6fabcea889d8a2c1",
        [("Cemu", "Cemu"), ("MoltenVK", "MoltenVK"), ("MoltenVK128", "MoltenVK128")],
        {}, {"CemuData", "default.metallib"}, "", "LICENSE.txt"),
    "citra": (
        "ManicEMU-v2.0.2", "Manic-EMU/ManicEMU", "v2.0.2", "ManicEMU.v2.0.2.SideloadJIT.ipa",
        "fa3d1a272298b02de44eeec182ea5c2bb1f9800b65b3239a4f2ee1ea4f0d99a7",
        [("Citra", "Citra"), ("MoltenVK", "MoltenVK")],
        {}, set(), "", "LICENSE"),
    "manic-ppsspp": (
        "ManicEMU-v2.0.2", "Manic-EMU/ManicEMU", "v2.0.2", "ManicEMU.v2.0.2.SideloadJIT.ipa",
        "fa3d1a272298b02de44eeec182ea5c2bb1f9800b65b3239a4f2ee1ea4f0d99a7",
        [("ppsspp.libretro", "ppsspp_libretro"), ("MoltenVK", "MoltenVK")],
        {}, set(), "", "LICENSE"),
    "vita3k": (
        "Veeb-v0.1.0", "veebteam/Veeb", "0.1.0", "Veeb-unsigned.ipa",
        "6380264f9615795ab8ed51cf05edee75e7be102d693991a8c2f68e106ceb5ab9",
        [],
        {"Frameworks/libVita3KCore.dylib": "Vita3KCore"},
        {"shaders-builtin", "icons"}, "Vita3KAssets", "COPYING.txt"),
}

def sha256(path):
    if not path.is_file():
        return ""
    checksum = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()

def fetch(url, target, digest=None, headers=None):
    if target.is_file() and target.stat().st_size and (digest is None or sha256(target) == digest):
        return
    with tempfile.TemporaryDirectory(dir=cache) as work:
        part = Path(work) / "download"
        cmd = ["curl", "-fsSL", "--retry", "5", "--retry-all-errors", "--retry-delay", "2", "--connect-timeout", "20"]
        for key, val in (headers or {}).items():
            cmd.extend(["-H", f"{key}: {val}"])
        cmd.extend([url, "-o", str(part)])
        subprocess.run(cmd, check=True)
        if digest and sha256(part) != digest:
            raise RuntimeError("Engine download failed SHA-256 verification: " + target.name)
        shutil.move(part, target)

for runtime in requested:
    if runtime not in engines:
        raise ValueError("Unknown native runtime: " + runtime)
    version, repo, tag, asset, digest, framework_specs, dylib_specs, resources, resource_subdir, licence_name = engines[runtime]
    archive = cache / (version + ".ipa")
    fetch(f"https://github.com/{repo}/releases/download/{tag}/{asset}", archive, digest)
    with tempfile.TemporaryDirectory(dir=cache) as work:
        work = Path(work)
        with zipfile.ZipFile(archive) as ipa:
            root = next(n.split(".app/")[0] + ".app/" for n in ipa.namelist() if ".app/" in n)
            fw_prefixes = {src_fw: (dst_fw, root + f"Frameworks/{src_fw}.framework/") for src_fw, dst_fw in framework_specs}
            res_base = destination / resource_subdir if resource_subdir else destination
            for name in ipa.namelist():
                relative = name.removeprefix(root)
                if not name.startswith(root):
                    continue
                matched = next(((src_fw, dst_fw, pfx) for src_fw, (dst_fw, pfx) in fw_prefixes.items() if name.startswith(pfx)), None)
                if matched is not None:
                    src_fw, dst_fw, pfx = matched
                    sub = name.removeprefix(pfx)
                    if sub == src_fw and src_fw != dst_fw:
                        sub = dst_fw
                    output = work / dst_fw / sub
                elif relative in dylib_specs:
                    dst_fw = dylib_specs[relative]
                    output = work / dst_fw / dst_fw
                elif relative.split("/")[0] in resources:
                    output = res_base / relative
                else:
                    continue
                if ".." in Path(relative).parts or Path(relative).is_absolute():
                    raise RuntimeError("Unsafe native engine archive path")
                if name.endswith("/"):
                    output.mkdir(parents=True, exist_ok=True)
                else:
                    output.parent.mkdir(parents=True, exist_ok=True)
                    output.write_bytes(ipa.read(name))
        all_specs = list(framework_specs) + [(src_rel, dst_fw) for src_rel, dst_fw in dylib_specs.items()]
        primary_src = all_specs[0][0] if all_specs else None
        for src_fw, dst_fw in all_specs:
            fw_work = work / dst_fw
            executable = fw_work / dst_fw
            if not executable.is_file():
                raise RuntimeError(f"Missing framework binary {src_fw} in {archive.name}")
            executable.chmod(0o755)
            subprocess.run(["xcrun", "lipo", "-verify_arch", "arm64", executable], check=True)
            build = subprocess.check_output(["xcrun", "vtool", "-arch", "arm64", "-show-build", executable], text=True)
            if "platform IOS\n" not in build:
                raise RuntimeError(f"Native framework {src_fw} is not an iOS device binary")
            if src_fw != dst_fw:
                subprocess.run(
                    ["xcrun", "install_name_tool", "-id", f"@rpath/{dst_fw}.framework/{dst_fw}", str(executable)],
                    check=True,
                )
            info_path = fw_work / "Info.plist"
            info = plistlib.loads(info_path.read_bytes()) if info_path.is_file() else {}
            info["CFBundleExecutable"] = dst_fw
            info["CFBundlePackageType"] = "FMWK"
            if src_fw != dst_fw or "CFBundleIdentifier" not in info:
                info["CFBundleIdentifier"] = f"org.gamecenter.core.{dst_fw.replace('_', '-').lower()}"
            if src_fw == primary_src:
                info["CFBundleVersion"] = tag.removeprefix("v")
                info["CFBundleShortVersionString"] = tag.removeprefix("v")
            info_path.write_bytes(plistlib.dumps(info))
            signature = fw_work / "_CodeSignature"
            if signature.exists():
                shutil.rmtree(signature)
            target = destination / f"Frameworks/{dst_fw}.framework"
            if target.exists():
                shutil.rmtree(target)
            target.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["ditto", fw_work, target], check=True)
    licence = cache / (version + "-LICENSE.txt")
    try:
        fetch(f"https://api.github.com/repos/{repo}/contents/{licence_name}?ref={tag}", licence,
              headers={"Accept": "application/vnd.github.raw"})
    except Exception:
        fetch(f"https://raw.githubusercontent.com/{repo}/{tag}/{licence_name}", licence)
    shutil.copyfile(licence, destination / (version + "-LICENSE.txt"))
    (destination / (version + "-SOURCE.txt")).write_text(
        f"Native {runtime} engine from {repo}, release {tag}.\n"
        f"Upstream source: https://github.com/{repo}/tree/{tag}\n"
        f"Source archive: https://github.com/{repo}/archive/refs/tags/{tag}.tar.gz\n")
    print(f"Prepared iOS native runtime {runtime} ({tag})", flush=True)
