#!/usr/bin/env bash
set -euo pipefail
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
c=$here/conformance
work=$(set -eu; scratch=$(mktemp -d "${TMPDIR:-/tmp}/conformance-repo-state.XXXXXX"); [ -n "$scratch" ]; printf '%s\n' "$scratch")
[ -n "$work" ] || exit 1
trap 'rm -rf "$work"' EXIT
python3 - "$c" <<'PY'
import csv
from pathlib import Path
import sys
root = Path(sys.argv[1])
with (root / 'rewrite-map.tsv').open() as f:
    rows = list(csv.DictReader(f, delimiter='\t'))
assert {r['source_test'] for r in rows} >= {'bin/test-repo-state.sh', 'bin/test-repo-state-cli.sh', 'bin/test-repo-state-memory.sh'}
assert rows and set(rows[0]) == {'source_test', 'behaviour', 'scenario_id', 'reason'}
with (root / 'source-allowlist.tsv').open() as f:
    retained = {r['source_test']: r['reason'] for r in csv.DictReader(f, delimiter='\t')}
for row in rows:
    assert all(row.values()), row
    if row['scenario_id'] == row['source_test']:
        assert retained.get(row['source_test']), row
        assert (root.parent.parent / row['source_test']).is_file(), row
    elif row['scenario_id'] != 'dropped':
        assert (root / 'scenarios' / row['scenario_id'] / 'scenario.sh').is_file(), row
for path in list((root / 'scenarios').glob('repo-state-*/scenario.sh')) + list(root.glob('repo-state*fixture.sh')):
    text = path.read_text()
    assert 'lib/' not in text, path
    assert 'repo_state_' not in text, path
PY
export DISPATCH_CONFORMANCE_ROOT="$work/root"
bash "$c/run.sh" --impl "${IMPL_BIN:-$here/../bin}" --out "$work/actual" --only repo-state-
mkdir "$work/expected"
for dir in "$c"/goldens/repo-state-*; do
  [ -d "$dir" ] || { echo 'FAIL: repo-state goldens absent'; exit 1; }
  ln -s "$dir" "$work/expected/${dir##*/}"
done
python3 - "$work/actual" <<'PY'
from pathlib import Path
import sys
for path in Path(sys.argv[1]).iterdir():
    if path.is_dir():
        assert (path / 'rc').read_text().strip() == '0', (path.name, (path / 'stderr').read_text())
        assert 'PASS:' in (path / 'stdout').read_text(), path.name
        assert not (path / 'argv').read_text(), path.name
PY
bash "$c/compare.sh" "$work/expected" "$work/actual"
# Publish case tokens only after every observation matches its golden.
for dir in "$work/actual"/*; do
  grep -E '^(PASS:|hostile metadata types PASS$)' "$dir/stdout"
done
echo 'PASS: repo-state public-command rewrite and complete mapping'
