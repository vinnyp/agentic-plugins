# shellcheck shell=bash
set -eu
: "${SCN_TMP:?}" "${STUB_RECORDING:?}"
runtime=${0##*/}
{
  printf '%q' "$runtime"
  for arg in "$@"; do printf ' %q' "$arg"; done
  printf '\n'
} >> "$SCN_TMP/argv"
n=1
while [ -f "$SCN_TMP/stdin.$runtime.$n" ]; do n=$((n + 1)); done
cat > "$SCN_TMP/stdin.$runtime.$n"
python3 - "$SCN_TMP/call.$runtime.$n" <<'PYTHON'
import hashlib
import os
from pathlib import Path
import subprocess
import sys

def git(*args):
    return subprocess.run(['git', *args], text=True, capture_output=True)

cwd = Path.cwd().resolve()
source = Path(os.environ.get('SCN_REPO', str(cwd))).resolve()
common = git('-C', str(source), 'rev-parse', '--path-format=absolute', '--git-common-dir')
config = os.environ.get('GIT_CONFIG_GLOBAL', '')
with open(sys.argv[1], 'w') as out:
    print('cwd', cwd, file=out)
    print('repository', 'source' if cwd == source or source in cwd.parents else 'different-clone', file=out)
    print('GIT_CONFIG_GLOBAL=' + config, file=out)
    path = Path(config) if config else None
    digest = hashlib.sha256(path.read_bytes()).hexdigest() if path and path.is_file() else 'absent'
    print('global-sha256=' + digest, file=out)
    sentinel = git('config', '--global', '--get', 'conformance.sentinel')
    print('sentinel-rc=' + str(sentinel.returncode), 'sentinel=' + sentinel.stdout.rstrip('\n'), file=out)
    print('source-review-pinned', int(common.returncode == 0 and (Path(common.stdout.strip()) / 'review-pinned').exists()), file=out)
PYTHON
recording=$STUB_RECORDING
if [ -d "$recording/$runtime/$n" ]; then
  recording=$recording/$runtime/$n
elif [ -d "$recording/$n" ]; then
  recording=$recording/$n
else
  for entry in "$recording"/* "$recording/$runtime"/*; do
    name=${entry##*/}
    case "$name" in ''|*[!0-9]*) continue ;; esac
    echo "stub $runtime: missing recording step $n" >&2
    exit 97
  done
fi
for file in stdout stderr rc; do
  if [ ! -f "$recording/$file" ]; then
    echo "stub $runtime: missing recording step $n ($file)" >&2
    exit 97
  fi
done
cat "$recording/stdout"
cat "$recording/stderr" >&2
rc=$(cat "$recording/rc")
case "$rc" in ''|*[!0-9]*) exit 2 ;; esac
[ "$rc" -le 255 ] || exit 2
exit "$rc"
