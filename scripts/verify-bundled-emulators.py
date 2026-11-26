#!/usr/bin/env python3
"""Check each emulator's transitive Mach-O dependencies without relying on this Mac's package managers."""
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
extra_targets = [Path(arg).resolve() for arg in sys.argv[2:]]

CMD_RE = re.compile(r"^\s+cmd\s+(\S+)")
PATH_RE = re.compile(r"^\s+(?:path|name)\s+(.+?)\s+\(offset\s+\d+\)")
DYLIB_LOAD_CMDS = {
    "LC_LOAD_DYLIB",
    "LC_LOAD_WEAK_DYLIB",
    "LC_REEXPORT_DYLIB",
    "LC_LAZY_LOAD_DYLIB",
    "LC_LOAD_UPWARD_DYLIB",
}


def expand(value, binary, executable):
    return value.replace("@loader_path", str(binary.parent)).replace("@executable_path", str(executable.parent))


def inspect_macho(binary, executable):
    output = subprocess.check_output(["otool", "-l", binary], text=True)
    rpaths = []
    own_ids = set()
    deps = []
    current_cmd = None
    for line in output.splitlines():
        cmd_match = CMD_RE.match(line)
        if cmd_match:
            current_cmd = cmd_match.group(1)
            continue
        if current_cmd == "LC_RPATH":
            path_match = PATH_RE.match(line)
            if path_match:
                rpaths.append(expand(path_match.group(1), binary, executable))
                current_cmd = None
        elif current_cmd == "LC_ID_DYLIB":
            path_match = PATH_RE.match(line)
            if path_match:
                own_ids.add(path_match.group(1))
                current_cmd = None
        elif current_cmd in DYLIB_LOAD_CMDS:
            path_match = PATH_RE.match(line)
            if path_match:
                deps.append(path_match.group(1))
                current_cmd = None
    return rpaths, own_ids, deps


def check_binary(binary, allowed_root, label):
    allowed_resolved = allowed_root.resolve()
    pending = [(binary, [])]
    visited = set()
    local_errors = []
    while pending:
        current, inherited = pending.pop()
        if current in visited:
            continue
        visited.add(current)
        own_rpaths, own_ids, deps = inspect_macho(current, binary)
        search = own_rpaths + inherited
        current_resolved = current.resolve()
        for dependency in deps:
            if dependency in own_ids or dependency.startswith(("/System/Library/", "/usr/lib/")):
                continue
            if dependency.startswith("@rpath/"):
                suffix = dependency.removeprefix("@rpath/")
                candidates = [Path(path) / suffix for path in search]
            else:
                candidates = [Path(expand(dependency, current, binary))]
            resolved = next((path.resolve() for path in candidates if path.exists()), None)
            if resolved is None or not resolved.is_relative_to(allowed_resolved):
                local_errors.append(f"{label}: {current.name} -> {dependency}")
            elif resolved != current_resolved:
                pending.append((resolved, search))
    return label, len(visited), local_errors


tasks = []
for app in sorted(root.glob("*.app")):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    tasks.append((executable, app, app.name, "bundled binaries"))

for target in extra_targets:
    if target.is_dir():
        for dylib in sorted(target.glob("*.dylib")):
            tasks.append((dylib, target, dylib.name, "binaries"))
    elif target.is_file():
        tasks.append((target, target.parent, target.name, "binaries"))

errors = []
with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 4)) as pool:
    futures = [(pool.submit(check_binary, b, r, label), kind) for b, r, label, kind in tasks]
    for future, kind in futures:
        label, count, local_errors = future.result()
        prefix = "Checked" if kind == "bundled binaries" else ("Checked core" if label.endswith(".dylib") else "Checked helper")
        print(f"{prefix} {label}: {count} {kind}")
        errors.extend(local_errors)

if errors:
    raise SystemExit("Unbundled emulator libraries:\n" + "\n".join(sorted(set(errors))))
print("PASS: all linked non-system libraries are contained within their emulator bundles")
