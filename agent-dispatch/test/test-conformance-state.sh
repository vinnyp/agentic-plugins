#!/usr/bin/env bash
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
c=$here/conformance
work=$(mktemp -d "${TMPDIR:-/tmp}/conformance-state.XXXXXX")
[ -n "$work" ] || exit 1
trap 'rm -rf "$work"' EXIT
[ -d "$c/goldens/state-compare-clean" ] || { echo 'FAIL: state goldens absent'; exit 1; }
python3 "$c/state-coverage.py" "$c"
mkdir -p "$work/coverage/contract"
cp "$c/state-coverage.tsv" "$c/state-exemptions.tsv" "$c/goldens.tsv" "$work/coverage/"
ln -s "$c/scenarios" "$work/coverage/scenarios"
for command in review-pin.sh review-clone.sh repo-state-check run-long-gate.sh gate-run.sh; do
  for kind in exit line flag env; do
    cp "$c/contract/inventory.tsv" "$work/coverage/contract/inventory.tsv"
    printf '%s\t%s\tnew-contract\tnew output\ttest\n' "$command" "$kind" >> "$work/coverage/contract/inventory.tsv"
    if python3 "$c/state-coverage.py" "$work/coverage" > "$work/error" 2>&1; then
      echo "FAIL: uncovered $command $kind accepted"; exit 1
    fi
    grep -q 'uncovered inventory rows' "$work/error"
  done
done
export DISPATCH_CONFORMANCE_ROOT="$work/root"
bash "$c/run.sh" --impl "${IMPL_BIN:-$here/../bin}" --out "$work/actual" --only state-
python3 "$c/state-coverage.py" "$c" "$work/actual"
mkdir "$work/expected"
for dir in "$c"/goldens/state-*; do ln -s "$dir" "$work/expected/${dir##*/}"; done
if ! bash "$c/compare.sh" "$work/expected" "$work/actual" > "$work/comparison"; then
  cat "$work/comparison"
  observation=$(sed -n 's@^\([^ /]*\)/stderr differs$@\1@p' "$work/comparison")
  if [ -n "$observation" ]; then
    printf '%s\n' 'Expected stderr:'
    cat "$work/expected/$observation/stderr"
    printf '%s\n' 'Actual stderr:'
    cat "$work/actual/$observation/stderr"
  fi
  exit 1
fi
echo 'PASS: state conformance and inventory coverage'
