import fcntl
import importlib.util
from pathlib import Path
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location("cache_maintenance", Path(__file__).parents[1] / "cache_maintenance.py")
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


class CacheMaintenanceTests(unittest.TestCase):
    def test_retention_and_protected_data(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            hosts = []
            for index in range(4):
                folder = root / ("S2Arm-Exit-" + f"{index:024x}")
                folder.mkdir()
                (folder / "data").write_bytes(b"x" * 8192)
                cache.os.utime(folder, (time.time() - 7200 + index,) * 2)
                hosts.append(folder)
            recovery = root / "SaveRepair"
            recovery.mkdir()
            (recovery / "save").write_bytes(b"save")
            (root / "S2Arm-Exit-ffffffffffffffff").symlink_to(recovery, target_is_directory=True)
            with (root / "maintenance.lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_SH)
                self.assertEqual(cache.prune_host_caches(root), 0)
                self.assertTrue(all(folder.exists() for folder in hosts))
            self.assertGreater(cache.prune_host_caches(root), 0)
            self.assertEqual([folder.exists() for folder in hosts], [False, False, True, True])
            self.assertEqual((recovery / "save").read_bytes(), b"save")

    def test_recent_and_build_locked_hosts_survive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / ("S2Arm-Exit-" + "a" * 24)
            folder.mkdir()
            (folder / "data").write_bytes(b"x" * 8192)
            self.assertEqual(cache.prune_host_caches(root, budget=0, keep=0), 0)
            with (folder / "build.lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                self.assertEqual(cache.prune_host_caches(root, budget=0, keep=0, grace=0), 0)
            self.assertGreater(cache.prune_host_caches(root, budget=0, keep=0, grace=0), 0)
            self.assertFalse(folder.exists())


if __name__ == "__main__":
    unittest.main()
