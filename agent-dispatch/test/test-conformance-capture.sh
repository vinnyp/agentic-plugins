#!/usr/bin/env bash
set -eu
here=$(CDPATH='' cd "$(dirname "$0")" && pwd -P)
c=$here/conformance
work=$(mktemp -d "${TMPDIR:-/tmp}/conformance-capture.XXXXXX")
[ -n "$work" ] || exit 1
trap 'rm -rf "$work"' EXIT
export DISPATCH_CONFORMANCE_ROOT="$work/root"
bash "$c/run.sh" --impl "${IMPL_BIN:-$here/../bin}" --out "$work/actual" --only capture-
mkdir "$work/expected"
for dir in "$c"/goldens/capture-*; do ln -s "$dir" "$work/expected/${dir##*/}"; done
# Each scenario asserts its intended observation before a golden is compared.
for dir in "$work/actual"/*; do
  [ "$(cat "$dir/rc")" = 0 ] || { cat "$dir/stdout" "$dir/stderr"; exit 1; }
done
bash "$c/compare.sh" "$work/expected" "$work/actual"
# Metadata-only smoke tests use stubs, never a real agent.
python3 - "$c/model-roster.py" "$work" <<'PY'
import importlib.util
from pathlib import Path
import sys
spec = importlib.util.spec_from_file_location('roster', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
p = Path(sys.argv[2]) / 'server.py'
p.write_text('''import json, sys
for line in sys.stdin:
    q = json.loads(line)
    method = q['method']
    if method == 'initialized': continue
    if method == 'initialize': result = {}
    elif method == 'config/read': result = {'config': {'model': sys.argv[1] or None}}
    elif method == 'model/list':
        if q['params']['cursor'] is None:
            result = {'data': [], 'nextCursor': 'second'}
        else:
            result = {'data': [{'model': 'fixture-model', 'isDefault': True}], 'nextCursor': None}
    else: raise AssertionError('unexpected method: ' + method)
    print(json.dumps({'id': q['id'], 'result': result}), flush=True)
''')
for configured in ('fixture-model', '', 'missing-model'):
    try:
        module.check([sys.executable, str(p), configured])
    except ValueError:
        assert configured == 'missing-model'
    else:
        assert configured != 'missing-model'
PY
# The public metadata-only route must use the published agy pins and fail closed.
# shellcheck source=agent-dispatch/bin/lib/agy-models.sh
source "$here/../bin/lib/agy-models.sh"
export AGY_MODEL_CODING_DEFAULT AGY_MODEL_REVIEW_DEFAULT
mkdir "$work/bin"
cat > "$work/bin/agy" <<'STUB'
#!/usr/bin/env bash
set -eu
[ "$*" = models ] || exit 97
printf '%s\tCoding\n' "$AGY_MODEL_CODING_DEFAULT"
[ "${HIDE_REVIEW_MODEL:-0}" = 0 ] || exit 0
printf '%s\tReview\n' "$AGY_MODEL_REVIEW_DEFAULT"
STUB
cat > "$work/bin/codex" <<'STUB'
#!/usr/bin/env bash
set -eu
[ "$*" = app-server ] || exit 97
exec python3 "$MODEL_SERVER" fixture-model
STUB
chmod +x "$work/bin/agy" "$work/bin/codex"
export MODEL_SERVER="$work/server.py"
PATH="$work/bin:$PATH" bash "$c/live-smoke.sh" --models-only > "$work/models"
grep -qx 'PASS agy-models' "$work/models"
grep -qx 'PASS codex-models' "$work/models"
if HIDE_REVIEW_MODEL=1 PATH="$work/bin:$PATH" bash "$c/live-smoke.sh" --models-only > "$work/models"; then
  echo 'FAIL missing live agy pin accepted'; exit 1
fi
grep -qx 'FAIL agy-models' "$work/models"
printf 'PASS conformance capture and metadata-only model checks\n'
