#!/usr/bin/env bash
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
c=$here/conformance
work=$(mktemp -d "${TMPDIR:-/tmp}/conformance-freshness.XXXXXX")
[ -n "$work" ] || exit 1
trap 'rm -rf "$work"' EXIT
python3 - "$c" <<'MAPPING'
import csv
from pathlib import Path
import sys
root = Path(sys.argv[1])
with (root / 'rewrite-map.tsv').open() as stream:
    rows = list(csv.DictReader(stream, delimiter='\t'))
for source, count, ref in [
    ('bin/test-dispatch-freshness.sh', 6, 'freshness-contract'),
    ('bin/test-review-launch.sh', 14, 'bin/test-review-launch.sh'),
    ('bin/test-portable-stat.sh', 8, 'bin/test-portable-stat.sh'),
]:
    cases = [row for row in rows if row['source_test'] == source]
    assert len(cases) == count, (source, len(cases))
    assert len({row['behaviour'] for row in cases}) == count
    assert all(row['scenario_id'] == ref and row['reason'] for row in cases)
assert not (root.parent.parent / 'bin/test-dispatch-freshness.sh').exists()
MAPPING
export DISPATCH_CONFORMANCE_ROOT="$work/root"
bash "$c/run.sh" --impl "${IMPL_BIN:-$here/../bin}" --out "$work/actual" --only freshness-
[ "$(cat "$work/actual/freshness-contract/rc")" = 0 ] || {
  cat "$work/actual/freshness-contract/stdout" "$work/actual/freshness-contract/stderr"
  exit 1
}
for case_id in a b c d e f; do
  grep -qx "Test $case_id PASS" "$work/actual/freshness-contract/stdout"
done
mkdir "$work/expected"
ln -s "$c/goldens/freshness-contract" "$work/expected/freshness-contract"
bash "$c/compare.sh" "$work/expected" "$work/actual"
echo 'PASS: freshness public-command conformance'
