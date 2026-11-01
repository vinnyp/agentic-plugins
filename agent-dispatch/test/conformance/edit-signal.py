"""Signal only the dispatcher created here, once its stub reports readiness."""
import os
from pathlib import Path
import signal
import subprocess
import time

env = os.environ
child = subprocess.Popen([
    env['IMPL_BIN'] + '/coding-dispatch.sh', '--worktree', 'codex',
    env['SCN_REPO'], env['SCN_TMP'] + '/brief', 'true',
])
try:
    deadline = time.monotonic() + 6
    while not Path(env['SCN_TMP'], 'ready').exists():
        if child.poll() is not None or time.monotonic() >= deadline:
            raise RuntimeError('dispatcher stub did not become ready')
        time.sleep(0.01)
    child.send_signal(signal.SIGTERM)
    rc = child.wait(timeout=4)
finally:
    if child.poll() is None:
        child.kill()
        child.wait()
raise SystemExit(rc)
