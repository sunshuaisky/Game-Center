"""Bound regenerable S2Arm host caches. Build/read operations share maintenance.lock."""
import fcntl
import os
from pathlib import Path
import re
import shutil
import time

HOST_NAME = re.compile(r"S2Arm-Exit-(?:[0-9a-f]{16}|[0-9a-f]{24})")

def allocated_bytes(folder):
    total = 0
    for directory, children, files in os.walk(folder, followlinks=False):
        children[:] = [name for name in children if not (Path(directory) / name).is_symlink()]
        for name in files:
            path = Path(directory) / name
            try:
                info = path.lstat()
                if not path.is_symlink():
                    total += info.st_blocks * 512
            except FileNotFoundError:
                pass
    return total

def prune_host_caches(root, budget=4 * 1024**3, keep=2, grace=3600):
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    removed = 0
    with (root / "maintenance.lock").open("a") as maintenance:
        try:
            fcntl.flock(maintenance, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        entries = []
        for folder in root.iterdir():
            if folder.is_symlink() or not folder.is_dir() or not HOST_NAME.fullmatch(folder.name):
                continue
            entries.append((folder, folder.stat().st_mtime, allocated_bytes(folder)))
        entries.sort(key=lambda item: item[1], reverse=True)
        total = sum(item[2] for item in entries)
        for index in range(len(entries) - 1, -1, -1):
            folder, modified, size = entries[index]
            if index < keep and total <= budget:
                continue
            # A recently used host may still be being copied into a build.
            if time.time() - modified < grace:
                continue
            try:
                descriptor = os.open(folder / "build.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            except FileNotFoundError:
                continue
            with os.fdopen(descriptor, "a") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    continue
                shutil.rmtree(folder)
                total -= size
                removed += size
        return removed

if __name__ == "__main__":
    size = prune_host_caches(Path.home() / "Library/Caches/GameCenter")
    print(f"Removed {size / 1024**3:.2f} GiB of old regenerable host caches")
