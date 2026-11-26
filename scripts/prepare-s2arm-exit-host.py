"""Build/cache the S2Arm host with Game Center's non-terminating exit API."""
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

# Dependency checks run with Python -I, which excludes the script's directory.
# Load only the bundled sibling, without depending on PYTHONPATH or the cwd.
_cache_spec = importlib.util.spec_from_file_location(
    "game_center_cache_maintenance", Path(__file__).resolve().with_name("cache_maintenance.py"))
_cache_module = importlib.util.module_from_spec(_cache_spec)
_cache_spec.loader.exec_module(_cache_module)
HOST_NAME = _cache_module.HOST_NAME
prune_host_caches = _cache_module.prune_host_caches

RELEASES = {
    '39d35671a57ee30d5f528c13d206fd6309a84b8f': (
        's2arm-session-exit-39d3567.patch', 'd94c7faa9375918d8223ca51a34dc0ea926cdd7b4c2c2c75e4dc5650ce7caf64'),
    'ebd3ef57de0f1ee5c69c2227956172a391119101': (
        's2arm-session-exit-ebd3ef5.patch', '6eb1f695c87438e1ce6d9e65dabf3eeb767667f0ce4f8fd3ba1e8e1f0456fe0f'),
    'b1d568d0e85afdec91f8cbc08bd33909a0c0e465': (
        's2arm-session-exit-b1d568d.patch', 'a22bed51d4a4c610d720614e210a1f0e7711a6149b57bb7195f90e952e90cb42'),
    '70f3dbe16699127e0cc53c4992e3ac2500d8bbaa': (
        's2arm-session-exit.patch', 'e189e443a4fa6cf2770b5324d5c072ea5e1b1929fa9e4bc34d1367ddb0dc1441'),
    '06f2e15f703543dfb424e3a8fdea98a5adfcb319': (
        's2arm-session-exit-06f2e15.patch', '7b47621df54f8659d278f46248f45f0f828e271fff85cdf0ba9b67e64bd700ff'),
}


def prepare(installed, check_only=False):
    root = Path.home() / "Library/Caches/GameCenter"
    root.mkdir(parents=True, exist_ok=True)
    with (root / "maintenance.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_SH)
        shell = _prepare(installed, check_only=check_only)
        if shell.parent.parent == root and HOST_NAME.fullmatch(shell.parent.name):
            os.utime(shell.parent, None)
    try:
        prune_host_caches(root)
    except OSError as error:
        print(f"缓存维护暂未完成：{error}", file=sys.stderr)
    return shell


def _prepare(installed, check_only=False):
    scripts = Path(__file__).resolve().parent
    base = json.loads((installed / 'Shell/manifest.json').read_text())['details']
    revision = base['sourceCommit']
    if revision not in RELEASES:
        raise RuntimeError(f'这版 S2Arm 的退出接口补丁尚未适配（{revision}），请使用与 Game Center 随附宿主匹配的引擎版本。')
    patch_name, archive_sha = RELEASES[revision]
    patch = scripts / 'patches' / patch_name
    fingerprint = hashlib.sha256(patch.read_bytes()).hexdigest()
    shell_id = base['shellId']
    cache_key = hashlib.sha256(f'{revision}/{shell_id}/{fingerprint}'.encode()).hexdigest()[:24]
    cache_root = Path.home() / 'Library/Caches/GameCenter'
    cache = cache_root / ('S2Arm-Exit-' + cache_key)
    for shell in [scripts.parent / 'S2ArmExitHosts' / revision,
                  scripts.parent / 'build/mobile-host/versions' / revision,
                  scripts.parent / 'S2ArmExitHost', scripts.parent / 'build/mobile-host/Shell',
                  cache_root / ('S2Arm-Exit-' + fingerprint[:16]) / 'Shell', cache / 'Shell']:
        manifest = shell / 'manifest.json'
        if manifest.is_file():
            details = json.loads(manifest.read_text())['details']
            if (details.get('sourceCommit') == revision and details.get('baseShellId') == shell_id
                    and details.get('gameCenterExitPatch') == fingerprint):
                return shell
    if check_only:
        raise RuntimeError("未找到与当前 S2Arm 引擎匹配的 iOS 宿主，请使用随附此引擎版本宿主的 Game Center。")
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / 'build.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        shell = cache / 'Shell'
        if (shell / 'manifest.json').is_file():
            return shell
        return build(installed, revision, archive_sha, patch, fingerprint, cache, shell)


def build(installed, revision, archive_sha, patch, fingerprint, cache, shell):
    make = shutil.which('gmake') or '/opt/homebrew/bin/gmake'
    dotnet = os.environ.get('DOTNET', str(Path.home() / '.dotnet/dotnet'))
    if not Path(make).is_file() or not Path(dotnet).is_file():
        raise RuntimeError('重新编译退出宿主需要 GNU Make 4 和微软 .NET 10 SDK。发布版 Mac 应用可直接使用随附的预编译宿主。')
    archive = cache / 'source.tar.gz'
    if not archive.is_file() or hashlib.sha256(archive.read_bytes()).hexdigest() != archive_sha:
        subprocess.run(['curl', '-fL', '--retry', '2', '--connect-timeout', '30', '--max-time', '300',
                        'https://codeload.github.com/jhaizhou-ops/S2Arm/tar.gz/' + revision, '-o', str(archive)], check=True, stdout=sys.stderr)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != archive_sha:
        raise RuntimeError('S2Arm 源码校验失败')
    engine = cache / 'Engine'
    if not engine.is_dir():
        with tempfile.TemporaryDirectory(prefix="source-", dir=cache) as tmp:
            staging = Path(tmp) / "Engine"
            staging.mkdir()
            with tarfile.open(archive) as source:
                for member in source.getmembers():
                    relative = Path(member.name)
                    if relative.is_absolute() or '..' in relative.parts:
                        raise RuntimeError('源码归档路径无效')
                subprocess.run(['tar', 'xzf', str(archive), '--strip-components', '1', '-C', str(staging)], check=True)
            shutil.copytree(installed / 'Engine/Binaries', staging / 'Binaries', dirs_exist_ok=True)
            subprocess.run(['/usr/bin/patch', '--batch', '-p1', '-i', str(patch)], cwd=staging, check=True, stdout=sys.stderr)
            staging.rename(engine)
    env = dict(os.environ, DOTNET=dotnet, DOTNET_ROOT=str(Path(dotnet).parent),
               S2A_PREBUILT_TOOLS=str(engine / 'Binaries/Prepare'), S2A_CS_CACHE=str(cache / 'cs-cache'))
    env['PATH'] = str(Path(make).parent) + ':' + str(Path(dotnet).parent) + ':' + env.get('PATH', '')
    subprocess.run([make, '-s', '-j4', 'ios', 'S2A_CS=1', 'S2A_SHELLUI=1', 'S2A_COMMIT=' + revision],
                   cwd=engine.resolve(), env=env, check=True, stdout=sys.stderr)
    return package(installed / 'Shell', engine / 'build/ios/S2Arm.app', shell, fingerprint)


def package(base_shell, built_app, shell, fingerprint):
    base = json.loads((base_shell / 'manifest.json').read_text())
    shell.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.exit-host-', dir=shell.parent) as tmp:
        staging = Path(tmp) / 'Shell'
        shutil.copytree(base_shell / 'root', staging / 'root')
        shutil.copytree(built_app, staging / 'root', dirs_exist_ok=True)
        details = dict(base['details'], baseShellId=base['details']['shellId'], gameCenterExitPatch=fingerprint)
        rows = []
        for path in sorted((staging / 'root').rglob('*')):
            if path.is_file():
                rows.append(dict(path=str(path.relative_to(staging / 'root')), size=path.stat().st_size,
                                 sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
        (staging / 'manifest.json').write_text(json.dumps(dict(schema=base['schema'], target='ios-shell', details=details, files=rows)))
        staging.rename(shell)
    return shell


if __name__ == '__main__':
    try:
        print(prepare(Path(sys.argv[1]), check_only="--check" in sys.argv[2:]))
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
