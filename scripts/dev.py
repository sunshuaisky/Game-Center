#!/usr/bin/env python3
"""Build and relaunch the SwiftPM debug app when project files change."""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
WATCH_ROOTS = [ROOT / "Sources", ROOT / "Package.swift", ROOT / "Package.resolved"]
POLL_SECONDS = 0.5
DEBOUNCE_SECONDS = 0.8
child: subprocess.Popen[bytes] | None = None
stopping = False


def snapshot() -> tuple[tuple[str, int, int], ...]:
    files: list[Path] = []
    for root in WATCH_ROOTS:
        if root.is_file():
            files.append(root)
        elif root.is_dir():
            files.extend(path for path in root.rglob("*") if path.is_file() and path.name != ".DS_Store")
    entries = []
    for path in files:
        try:
            stat = path.stat()
            entries.append((str(path.relative_to(ROOT)), stat.st_mtime_ns, stat.st_size))
        except FileNotFoundError:
            continue
    return tuple(sorted(entries))


def build() -> bool:
    print("\n[Game Center Dev] 正在编译 Debug…", flush=True)
    result = subprocess.run(["swift", "build", "-c", "debug"], cwd=ROOT)
    if result.returncode != 0:
        print("[Game Center Dev] 编译失败，当前运行实例继续保留。", flush=True)
        return False
    return True


def executable_path() -> Path:
    result = subprocess.run(
        ["swift", "build", "-c", "debug", "--show-bin-path"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return Path(result.stdout.strip()) / "GameCenter"


def launch(executable: Path) -> subprocess.Popen[bytes]:
    print("[Game Center Dev] 启动开发版窗口。", flush=True)
    return subprocess.Popen([str(executable)], cwd=ROOT, start_new_session=True)


def stop_child() -> None:
    global child
    if child is None or child.poll() is not None:
        child = None
        return
    child.terminate()
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()
    child = None


def request_stop(_signum: int, _frame: object) -> None:
    global stopping
    stopping = True


def main() -> int:
    global child
    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)

    lock_path = ROOT / "build" / ".dev.pid"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    if lock_path.exists():
        try:
            existing_pid = int(lock_path.read_text().strip())
            os.kill(existing_pid, 0)
        except (ValueError, ProcessLookupError, PermissionError):
            lock_path.unlink(missing_ok=True)
        else:
            print(f"开发监听器已在运行（PID {existing_pid}）。", flush=True)
            return 1
    lock_path.write_text(str(os.getpid()))

    try:
        if not build():
            return 1
        executable = executable_path()
        if not executable.exists():
            print(f"找不到 Debug 可执行文件：{executable}", file=sys.stderr)
            return 1

        current = snapshot()
        child = launch(executable)
        print("[Game Center Dev] 正在监听 Sources、Package.swift 和应用资源；保存代码后会自动编译并刷新窗口。", flush=True)
        changed_at: float | None = None
        while not stopping:
            time.sleep(POLL_SECONDS)
            updated = snapshot()
            if updated != current:
                current = updated
                changed_at = time.monotonic()
                continue
            if changed_at is not None and time.monotonic() - changed_at >= DEBOUNCE_SECONDS:
                changed_at = None
                if build():
                    stop_child()
                    child = launch(executable)
                current = snapshot()
            elif child is None or child.poll() is not None:
                child = launch(executable)
    finally:
        stop_child()
        lock_path.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
