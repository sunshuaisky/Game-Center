#!/usr/bin/env python3
"""Stage the pinned desktop emulators and their upstream sources beside the existing cores."""
import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / "build/mac-platforms"
STAGE = ROOT / "build/emulators"
ARM = platform.machine() == "arm64"
RELEASE = "https://github.com/{}/releases/download/{}/{}"
# The arm64 and x64 binaries repositories release on their own schedules and
# use different asset naming since 0.0.42.
if ARM:
    RPC = "d264e2f19ff82d8313474549a8e78ae8f03b8060"
    rpc_repo, rpc_asset = "RPCS3/rpcs3-binaries-mac-arm64", "rpcs3-v0.0.43-20662-d264e2f1_macos_aarch64.7z"
    rpc_sha = "ea7d3f40b916ceee71125220012b7c9b62b42244832363507d91c77c77888019"
    vita_tag, vita_rev = "4432", "7857416d"
    vita_asset = f"vita3k-{vita_tag}-{vita_rev}-macos-arm64.dmg"
    vita_sha = "4b43e5c33eb3a81ba8135e05b3b882999a4e8396bddea6311200582cd89b3d11"
else:
    RPC = "ffc50905a640146ddd66ee15d29d90f5841e84f0"
    rpc_repo, rpc_asset = "RPCS3/rpcs3-binaries-mac", "rpcs3-v0.0.42-19759-ffc50905_macos.7z"
    rpc_sha = "6abfa0437fda6aeed384befb288377b6854d01b58a5b80da54314d6fab8ab719"
    vita_tag, vita_rev = "4397", "64e655dd"
    vita_asset = f"vita3k-{vita_tag}-{vita_rev}-macos-intel.dmg"
    vita_sha = "59783a2277dd35bc3ae3e2df24142c8448dd007b7618eed927639c38676ca05c"

# Name, archive cache key, binary URL, SHA-256, source repository and matching revision.
systems = [
    ("Vita3K", "vita.dmg" if ARM else "vita-intel.dmg", RELEASE.format("Vita3K/Vita3K-builds", vita_tag, vita_asset),
     vita_sha, "Vita3K/Vita3K", vita_rev),
    ("RPCS3", "rpcs3-arm.7z" if ARM else "rpcs3.7z", RELEASE.format(rpc_repo, "build-"+RPC, rpc_asset),
     rpc_sha, "RPCS3/rpcs3", RPC),
    ("Cemu", "cemu.dmg", RELEASE.format("hauntek/Cemu", "v2.6.11", "cemu-2.6.11-macos-15-universal.dmg"),
     "87cdd8fa54899ff3a6a36f0991dd983cfd8de5fe2e39822b47e31d4c8e6660ca", "hauntek/Cemu", "v2.6.11"),
    ("S2Arm", "s2arm-engine.dmg", RELEASE.format("jhaizhou-ops/S2Arm", "v0.6.10", "S2Arm-mac-arm64.dmg"),
     "3a920c8f1df46795abaa89de857af6a8c1b9567ba24c516b3afdca11e53f3d89", "jhaizhou-ops/S2Arm", "v0.6.10"),
]

def sha256_file(path):
    hasher = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(1 << 20), b""):
            hasher.update(chunk)
    return hasher.hexdigest()

def download(url, path, digest=None):
    if path.is_file() and (not digest or sha256_file(path) == digest):
        return
    fd, tmp_name = tempfile.mkstemp(dir=path.parent)
    os.close(fd)
    tmp_path = Path(tmp_name)
    try:
        subprocess.run(["curl", "-fsSL", "--retry", "3", "--retry-all-errors", "--connect-timeout", "12", url, "-o", str(tmp_path)], check=True)
        if digest and sha256_file(tmp_path) != digest:
            raise ValueError(f"Checksum mismatch for {url}")
        os.replace(tmp_path, path)
    except Exception:
        tmp_path.unlink(missing_ok=True)
        raise

def stage(entry):
    name, cache, url, sha, repo, revision = entry
    app = STAGE / "Emulators" / (name + ".app")
    archive = CACHE / cache
    source = STAGE / "ThirdPartySource" / f"{name}-{revision}.tar.gz"
    license_file = STAGE / "ThirdPartyLicenses" / (name + "-LICENSE.txt")
    stamp = CACHE / (name + ".sha256")
    if app.is_dir() and source.is_file() and license_file.is_file() and stamp.exists() and stamp.read_text() == sha:
        return
    for old_source in (STAGE / "ThirdPartySource").glob(f"{name}-*.tar.gz"):
        if old_source != source:
            old_source.unlink()
    download(url, archive, sha)
    download(f"https://codeload.github.com/{repo}/tar.gz/{revision}", source)
    with tarfile.open(source) as tar:
        license_member = next(m for m in tar if len(Path(m.name).parts) == 2 and Path(m.name).name.lower() in ("copying", "license", "license.txt", "license.md", "copying.txt", "copying.gplv3"))
        license_file.write_bytes(tar.extractfile(license_member).read())
    with tempfile.TemporaryDirectory(dir=CACHE) as temp:
        work = Path(temp)
        mounted = cache.endswith(".dmg")
        if mounted:
            subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", temp, archive], check=True, stdout=subprocess.DEVNULL)
        try:
            if not mounted:
                subprocess.run(["/usr/bin/tar", "-xf", archive, "-C", work], check=True)
            bundle, = work.glob("*.app")
            if app.exists():
                shutil.rmtree(app)
            subprocess.run(["ditto", bundle, app], check=True)
        finally:
            if mounted:
                subprocess.run(["hdiutil", "detach", temp], check=True, stdout=subprocess.DEVNULL)
    stamp.write_text(sha)
    print(f"Prepared {name} {revision}", flush=True)

if __name__ == "__main__":
    from concurrent.futures import ThreadPoolExecutor
    for folder in (CACHE, STAGE/"Emulators", STAGE/"ThirdPartyLicenses", STAGE/"ThirdPartySource"):
        folder.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(stage, systems))
