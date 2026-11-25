#!/usr/bin/env python3
"""Check each emulator's transitive Mach-O dependencies without relying on this Mac's package managers."""
from pathlib import Path
import plistlib
import re
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
extra_targets = [Path(arg).resolve() for arg in sys.argv[2:]]
errors = []

def rpaths(binary, executable):
    output = subprocess.check_output(["otool", "-l", binary], text=True)
    result = []
    for block in output.split("cmd LC_RPATH")[1:]:
        match = re.search(r"\n\s+path (.+?) \(offset", block)
        if match:
            result.append(expand(match[1], binary, executable))
    return result

def expand(value, binary, executable):
    return value.replace("@loader_path", str(binary.parent)).replace("@executable_path", str(executable.parent))

def check_binary(binary, allowed_root, label):
    pending = [(binary, [])]
    visited = set()
    while pending:
        current, inherited = pending.pop()
        if current in visited:
            continue
        visited.add(current)
        search = rpaths(current, binary) + inherited
        own_ids = {line.strip() for line in subprocess.check_output(["otool", "-D", current], text=True).splitlines()[1:]
                   if line.strip() and not line.endswith(":")}
        lines = subprocess.check_output(["otool", "-L", current], text=True).splitlines()
        for line in lines:
            if not line.startswith("\t"):
                continue
            dependency = line.strip().split(" (compatibility version")[0]
            if dependency in own_ids or dependency.startswith(("/System/Library/", "/usr/lib/")):
                continue
            if dependency.startswith("@rpath/"):
                suffix = dependency.removeprefix("@rpath/")
                candidates = [Path(path) / suffix for path in search]
            else:
                candidates = [Path(expand(dependency, current, binary))]
            resolved = next((path.resolve() for path in candidates if path.exists()), None)
            if resolved is None or not resolved.is_relative_to(allowed_root.resolve()):
                errors.append(f"{label}: {current.name} -> {dependency}")
            elif resolved != current.resolve():
                pending.append((resolved, search))
    return len(visited)

for app in sorted(root.glob("*.app")):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    count = check_binary(executable, app, app.name)
    print(f"Checked {app.name}: {count} bundled binaries")

for target in extra_targets:
    if target.is_dir():
        for dylib in sorted(target.glob("*.dylib")):
            count = check_binary(dylib, target, dylib.name)
            print(f"Checked core {dylib.name}: {count} binaries")
    elif target.is_file():
        count = check_binary(target, target.parent, target.name)
        print(f"Checked helper {target.name}: {count} binaries")

if errors:
    raise SystemExit("Unbundled emulator libraries:\n" + "\n".join(sorted(set(errors))))
print("PASS: all linked non-system libraries are contained within their emulator bundles")
