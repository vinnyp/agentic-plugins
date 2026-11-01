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
# Compare only this slice; other capture tasks share goldens/.
mkdir "$work/expected"
for dir in "$c"/goldens/edit-*; do ln -s "$dir" "$work/expected/${dir##*/}"; done
bash "$c/compare.sh" "$work/expected" "$work/actual"
echo 'PASS: edit conformance and inventory coverage'
