#!/usr/bin/env bash
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
c=$here/conformance
work=$(mktemp -d "${TMPDIR:-/tmp}/conformance-edit.XXXXXX")
[ -n "$work" ] || exit 1
export DISPATCH_CONFORMANCE_ROOT="$work/root"
trap 'rm -rf "$work"' EXIT
[ -d "$c/goldens/edit-ok" ] || { echo 'FAIL: edit goldens absent'; exit 1; }
python3 "$c/edit-coverage.py" "$c"
# Same-length wrong patches must change the digest, including removed-worktree
# archives. Use this suite's disposable fixture repository.
mkdir "$work/patch-repo"
git -C "$work/patch-repo" init -q -b main
git -C "$work/patch-repo" -c user.name=Conformance -c user.email=conformance@example.invalid commit --allow-empty -qm fixture
SCN_REPO="$work/patch-repo" python3 - "$c/capture-state.py" <<'PYTHON'
import contextlib
import hashlib
import io
import os
from pathlib import Path
import runpy
import sys
repo = Path(os.environ['SCN_REPO'])
patch = repo / '.git/coding-dispatch-last-fail.patch'
archive = repo / '.git/coding-dispatch-fail-patches/synthetic.patch'
archive.parent.mkdir()
def capture(data):
    patch.write_bytes(data)
    archive.write_bytes(data)
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        runpy.run_path(sys.argv[1])
    lines = output.getvalue().splitlines()
    digest = 'sha256=' + hashlib.sha256(data).hexdigest()
    assert sum(line.endswith('1 ' + digest) for line in lines) == 2
    return output.getvalue()
assert capture(b'first\n') == capture(b'first\n')
assert capture(b'first\n') != capture(b'wrong\n')
PYTHON
# New exit and output rows must each fail closed before any agent stub runs.
mkdir -p "$work/coverage/contract"
cp "$c/edit-coverage.tsv" "$c/edit-line-exemptions.tsv" "$work/coverage/"
ln -s "$c/scenarios" "$work/coverage/scenarios"
for kind in exit line flag env; do
  cp "$c/contract/inventory.tsv" "$work/coverage/contract/inventory.tsv"
  printf 'coding-dispatch.sh\t%s\tnew-contract\tnew output\ttest\n' "$kind" >> "$work/coverage/contract/inventory.tsv"
  if python3 "$c/edit-coverage.py" "$work/coverage" > "$work/coverage-error" 2>&1; then
    echo "FAIL: uncovered $kind accepted"; exit 1
  fi
  grep -q 'uncovered inventory rows' "$work/coverage-error"
done
bash "$c/run.sh" --impl "${IMPL_BIN:-$here/../bin}" --out "$work/actual" --only edit-
python3 "$c/edit-coverage.py" "$c" "$work/actual"
# Both TDD paths retain the worker commit and a nonempty patch, without revert.
python3 - "$work/actual" <<'PYTHON'
from pathlib import Path
import re
import sys
for name in ('edit-tdd-fail', 'edit-tdd-signal'):
    directory = Path(sys.argv[1]) / name
    output = (directory / 'stdout').read_text() + (directory / 'stderr').read_text()
    state = (directory / 'state').read_text()
    assert 'TDD commits SALVAGED' in output, name
    assert 'tree reverted' not in output and 'unwound' not in output, name
    head = re.search(r'^HEAD ([0-9a-f]{40})$', state, re.M)[1]
    base = re.search(r'fixture-base=([0-9a-f]+)', output)[1]
    assert not head.startswith(base), name
    assert re.search(r'^patch .* 1 [1-9][0-9]* sha256=[0-9a-f]{64}$', state, re.M), name
    assert 'status\n\nresult 0' in state, name
PYTHON
# Compare only this slice; other capture tasks share goldens/.
mkdir "$work/expected"
for dir in "$c"/goldens/edit-*; do ln -s "$dir" "$work/expected/${dir##*/}"; done
bash "$c/compare.sh" "$work/expected" "$work/actual"
echo 'PASS: edit conformance and inventory coverage'
