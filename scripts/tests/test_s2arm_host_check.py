"""Exercise the same isolated Python invocation used by the device dependency UI."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class HostCheckTests(unittest.TestCase):
    def test_bundled_host_in_isolated_mode(self):
        scripts = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix="Game Center host check ") as directory:
            root = Path(directory)
            bundled = root / "MobileBuild/scripts"
            bundled.mkdir(parents=True)
            for name in ["prepare-s2arm-exit-host.py", "cache_maintenance.py"]:
                shutil.copy2(scripts / name, bundled / name)
            patches = bundled / "patches"
            patches.mkdir()
            patch = b"exit-host-patch-fixture"
            (patches / "s2arm-session-exit-b1d568d.patch").write_bytes(patch)
            revision = "b1d568d0e85afdec91f8cbc08bd33909a0c0e465"
            details = {"sourceCommit": revision, "shellId": "fixture-shell"}
            installed = root / "Installed Engine"
            (installed / "Shell").mkdir(parents=True)
            (installed / "Shell/manifest.json").write_text(json.dumps({"details": details}))
            host = bundled.parent / "S2ArmExitHosts" / revision
            host.mkdir(parents=True)
            manifest = host / "manifest.json"
            manifest.write_text(json.dumps({"details": dict(details,
                baseShellId="fixture-shell", gameCenterExitPatch=hashlib.sha256(patch).hexdigest())}))
            home = root / "Clean Home"
            home.mkdir()
            environment = dict(os.environ, HOME=str(home), PYTHONPATH=str(root / "unused"))
            command = ["/usr/bin/python3", "-IB", str(bundled / "prepare-s2arm-exit-host.py"),
                       str(installed), "--check"]
            result = subprocess.run(command, cwd="/", env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(Path(result.stdout.strip()).resolve(), host.resolve())
            manifest.unlink()
            result = subprocess.run(command, cwd="/", env=environment, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("未找到与当前 S2Arm 引擎匹配的 iOS 宿主", result.stderr)
            self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
