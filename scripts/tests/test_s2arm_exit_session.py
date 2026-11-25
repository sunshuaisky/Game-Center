"""Run the native stop-controller regression against a patched S2Arm source tree."""
from pathlib import Path
import subprocess
import sys
import tempfile

engine = Path(sys.argv[1]).resolve()
here = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='gc-session-test-') as directory:
    work = Path(directory)
    include = ['-I', str(engine / 'runtime/include'), '-I', str(engine / 'runtime/src')]
    subprocess.run(['xcrun', 'clang', '-c', '-O0', *include, str(engine / 'runtime/src/session.c'), '-o', str(work / 'session.o')], check=True)
    symbols = subprocess.check_output(['xcrun', 'nm', '-u', str(work / 'session.o')], text=True)
    supplied = {'s2a_thread_restart_supported', 's2a_window_ok', 's2a_thread_stop_all', 's2a_svc_park_all'}
    # Unrelated runtime providers are deterministic fixtures. The test itself
    # supplies the join, service, graphics and rebuild providers with assertions.
    stubs = [line.strip()[1:] for line in symbols.splitlines()
             if line.strip().startswith('_s2a_') and line.strip()[1:] not in supplied]
    (work / 'stubs.c').write_text('\n'.join('int ' + name + '(void) { return 0; }' for name in stubs))
    subprocess.run(['xcrun', 'clang', '-O0', *include, str(here / 's2arm_exit_session.c'), str(work / 'stubs.c'),
                    str(work / 'session.o'), '-Wl,-export_dynamic', '-o', str(work / 'test')], check=True)
    subprocess.run([str(work / 'test')], check=True)
    subprocess.run([str(work / 'test'), 'fail-join'], check=True)
