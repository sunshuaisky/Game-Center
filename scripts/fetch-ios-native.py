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
requested = set(sys.argv[3].split(",")) if len(sys.argv) > 3 else {"cemu"}
cache.mkdir(parents=True, exist_ok=True)
destination.mkdir(parents=True, exist_ok=True)
engines = {
    "cemu": (
        "MuffinEMU-v11.8", "MuffinEMU/Muffin-EMU", "v11.8", "MuffinEMU.ipa",
        "62ec179f38ff124b62f4cb192d6d8c2a0363e9e74e8d188a6fabcea889d8a2c1",
        "Cemu", ("MoltenVK", "MoltenVK128"), {"CemuData", "default.metallib"}, "LICENSE.txt"),
}

def sha256(path):
    if not path.is_file():
        return ""
    checksum = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()

def fetch(url, target, digest=None):
    if target.is_file() and target.stat().st_size and (digest is None or sha256(target) == digest):
        return
    with tempfile.TemporaryDirectory(dir=cache) as work:
        part = Path(work) / "download"
        subprocess.run(["curl", "-fsSL", "--retry", "3", "--retry-all-errors",
                        "--connect-timeout", "12", url, "-o", part], check=True)
        if digest and sha256(part) != digest:
            raise RuntimeError("Engine download failed SHA-256 verification: " + target.name)
        shutil.move(part, target)

for runtime in sorted(requested):
    if runtime not in engines:
        raise ValueError("Unknown native runtime: " + runtime)
    version, repo, tag, asset, digest, framework, extra_frameworks, resources, licence_name = engines[runtime]
    archive = cache / (version + ".ipa")
    fetch(f"https://github.com/{repo}/releases/download/{tag}/{asset}", archive, digest)
    all_frameworks = (framework,) + tuple(extra_frameworks)
    with tempfile.TemporaryDirectory(dir=cache) as work:
        work = Path(work)
        with zipfile.ZipFile(archive) as ipa:
            root = next(n.split(".app/")[0] + ".app/" for n in ipa.namelist() if ".app/" in n)
            fw_prefixes = {fw: root + f"Frameworks/{fw}.framework/" for fw in all_frameworks}
            for name in ipa.namelist():
                relative = name.removeprefix(root)
                if not name.startswith(root):
                    continue
                matched_fw = next((fw for fw, pfx in fw_prefixes.items() if name.startswith(pfx)), None)
                if matched_fw is not None:
                    output = work / matched_fw / name.removeprefix(fw_prefixes[matched_fw])
                elif relative.split("/")[0] in resources:
                    output = destination / relative
                else:
                    continue
                if ".." in Path(relative).parts or Path(relative).is_absolute():
                    raise RuntimeError("Unsafe native engine archive path")
                if name.endswith("/"):
                    output.mkdir(parents=True, exist_ok=True)
                else:
                    output.parent.mkdir(parents=True, exist_ok=True)
                    output.write_bytes(ipa.read(name))
        for fw in all_frameworks:
            fw_work = work / fw
            executable = fw_work / fw
            if not executable.is_file():
                raise RuntimeError(f"Missing framework binary {fw} in {archive.name}")
            executable.chmod(0o755)
            subprocess.run(["xcrun", "lipo", "-verify_arch", "arm64", executable], check=True)
            build = subprocess.check_output(["xcrun", "vtool", "-arch", "arm64", "-show-build", executable], text=True)
            if "platform IOS\n" not in build:
                raise RuntimeError(f"Native framework {fw} is not an iOS device binary")
            info_path = fw_work / "Info.plist"
            if info_path.is_file():
                info = plistlib.loads(info_path.read_bytes())
                if fw == framework:
                    info.update(CFBundleVersion=tag.removeprefix("v"), CFBundleShortVersionString=tag.removeprefix("v"))
                info_path.write_bytes(plistlib.dumps(info))
            signature = fw_work / "_CodeSignature"
            if signature.exists():
                shutil.rmtree(signature)
            target = destination / f"Frameworks/{fw}.framework"
            target.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["ditto", fw_work, target], check=True)
    licence = cache / (version + "-LICENSE.txt")
    fetch(f"https://raw.githubusercontent.com/{repo}/{tag}/{licence_name}", licence)
    shutil.copyfile(licence, destination / (version + "-LICENSE.txt"))
    (destination / (version + "-SOURCE.txt")).write_text(
        f"Native {runtime} engine from {repo}, release {tag}.\n"
        f"Upstream source: https://github.com/{repo}/tree/{tag}\n"
        f"Source archive: https://github.com/{repo}/archive/refs/tags/{tag}.tar.gz\n")
    print(f"Prepared iOS native runtime {runtime} ({tag})", flush=True)
