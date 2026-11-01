#!/usr/bin/env bash
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
c=$here/conformance
work=$(mktemp -d "${TMPDIR:-/tmp}/conformance-clone.XXXXXX")
[ -n "$work" ] || exit 1
trap 'rm -rf "$work"' EXIT
python3 - "$c" <<'PY'
import csv
from pathlib import Path
import re
import sys
root = Path(sys.argv[1])
with (root / 'rewrite-map.tsv').open() as f:
    rows = [r for r in csv.DictReader(f, delimiter='\t')
            if r['source_test'] == 'bin/test-review-clone.sh']
assert len(rows) == 49, len(rows)
for row in rows:
    assert all(row.values()), row
    assert row['scenario_id'] == 'clone-contract', row
    assert (root / 'scenarios' / row['scenario_id'] / 'scenario.sh').is_file()
text = (root / 'scenarios/clone-contract/scenario.sh').read_text()
assert not re.search(r'^\s*(source|\.)\s', text, re.M)
assert not re.search(r'\b(_?review_clone_\w+|declare -f)\b', text)
assert not (root.parent.parent / 'bin/test-review-clone.sh').exists()
PY
export DISPATCH_CONFORMANCE_ROOT="$work/root"
bash "$c/run.sh" --impl "${IMPL_BIN:-$here/../bin}" --out "$work/actual" --only clone-
[ "$(cat "$work/actual/clone-contract/rc")" = 0 ] || {
  cat "$work/actual/clone-contract/stdout" "$work/actual/clone-contract/stderr"
  exit 1
}
grep -q '^PASS:' "$work/actual/clone-contract/stdout"
mkdir "$work/expected"
ln -s "$c/goldens/clone-contract" "$work/expected/clone-contract"
bash "$c/compare.sh" "$work/expected" "$work/actual"
echo 'PASS: review clone public-command rewrite and complete mapping'
