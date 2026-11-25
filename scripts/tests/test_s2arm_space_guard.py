"""Exercise the production exporter without running a multi-GB game build."""
import pathlib
import sys
import types
import unittest

class Failure(Exception):
    def __init__(self, message, code):
        super().__init__(message)
        self.code = code

class SpaceGuardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.saved = {name: sys.modules.get(name) for name in ('ipa', 'layout', 'main', 'program_pack', 'core', 'library')}
        sys.modules.update({name: types.SimpleNamespace() for name in cls.saved})
        sys.modules['core'].Failure = Failure
        source = pathlib.Path('scripts/export-s2arm-ios.py').read_text().split('sys.exit(main.run_request')[0]
        cls.module = {}
        argv = sys.argv
        try:
            sys.argv = ['export', '/tmp/main.py', '/tmp/request.json']
            exec(compile(source, 'export-s2arm-ios.py', 'exec'), cls.module)
        finally:
            sys.argv = argv

    @classmethod
    def tearDownClass(cls):
        for name, original in cls.saved.items():
            if original is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = original

    def build(self, volumes):
        calls = []
        upstream = lambda *_a, **_k: {'volumes': volumes}
        sys.modules['library'].check_pack_space = upstream
        def build(context):
            sys.modules['library'].check_pack_space(context, {}, compiler_policy={})
            calls.append('expensive work')
            return {'ok': True}
        sys.modules['ipa'].build = build
        try:
            return self.module['build_with_space_guard'](object()), calls
        finally:
            self.assertIs(sys.modules['library'].check_pack_space, upstream)
            self.calls = calls

    def test_reported_shortage_stops_before_expensive_work(self):
        with self.assertRaises(Failure) as caught:
            self.build([dict(role='library', needBytes=22_000_000_000, freeBytes=19_000_000_000)])
        self.assertEqual(caught.exception.code, 'disk_full')
        self.assertIn('24.2 GB', str(caught.exception))
        self.assertEqual(self.calls, [])

    def test_export_headroom_and_separate_cache_volume(self):
        with self.assertRaises(Failure):
            self.build([dict(role='library', needBytes=22_000_000_000, freeBytes=30_000_000_000),
                        dict(role='cache', needBytes=5_000_000_000, freeBytes=6_000_000_000)])
        self.assertEqual(self.calls, [])

    def test_sufficient_space_preserves_result(self):
        result, calls = self.build([dict(role='library', needBytes=22_000_000_000, freeBytes=30_000_000_000)])
        self.assertEqual(result, {'ok': True})
        self.assertEqual(calls, ['expensive work'])

if __name__ == '__main__':
    unittest.main()
