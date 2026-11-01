#!/usr/bin/env bash
set -euo pipefail
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
c=$here/conformance
work=$(set -eu; scratch=$(mktemp -d "${TMPDIR:-/tmp}/conformance-probes.XXXXXX"); [ -n "$scratch" ]; printf '%s\n' "$scratch")
[ -n "$work" ] || exit 1
trap 'rm -rf "$work"' EXIT
python3 - "$c" <<'PY'
import csv
from pathlib import Path
import re
import sys
root = Path(sys.argv[1])
sources = {'bin/test-agy-auth-preflight.sh', 'bin/test-agy-print-form-probe.sh',
           'bin/test-codex-exec-probe.sh'}
with (root / 'rewrite-map.tsv').open() as f:
    rows = [r for r in csv.DictReader(f, delimiter='\t') if r['source_test'] in sources]
assert {r['source_test'] for r in rows} == sources
assert len(rows) == 73, len(rows)
for row in rows:
    assert all(row.values()), row
    if row['scenario_id'] != 'dropped':
        assert (root / 'scenarios' / row['scenario_id'] / 'scenario.sh').is_file(), row
for path in (root / 'scenarios').glob('probe-*/scenario.sh'):
    text = path.read_text()
    assert not re.search(r'^\s*(source|\.)\s', text, re.M), path
    assert not re.search(r'\b(agy_auth_probe|agy_model_present|agy_print_form_probe|codex_exec_probe)\b', text), path
for source in sources:
    assert not (root.parent.parent / source).exists(), source
PY
export DISPATCH_CONFORMANCE_ROOT="$work/root"
bash "$c/run.sh" --impl "${IMPL_BIN:-$here/../bin}" --out "$work/actual" --only probe-
mkdir "$work/expected"
for dir in "$c"/goldens/probe-*; do
  [ -d "$dir" ] || { echo 'FAIL: probe goldens absent'; exit 1; }
  ln -s "$dir" "$work/expected/${dir##*/}"
done
python3 - "$work/actual" <<'PY'
from pathlib import Path
import sys
paths = [p for p in Path(sys.argv[1]).iterdir() if p.is_dir()]
assert len(paths) == 5, len(paths)
for path in paths:
    assert (path / 'rc').read_text().strip() == '0', (path.name, (path / 'stdout').read_text(), (path / 'stderr').read_text())
    assert 'PASS' in (path / 'stdout').read_text(), path.name
    assert not (path / 'argv').read_text(), path.name
PY
bash "$c/compare.sh" "$work/expected" "$work/actual"
echo 'PASS: probe public-command rewrite and complete mapping'
