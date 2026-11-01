#!/usr/bin/env bash
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
c=$here/conformance
work=$(mktemp -d "${TMPDIR:-/tmp}/conformance-worker.XXXXXX")
[ -n "$work" ] || exit 1
trap 'rm -rf "$work"' EXIT
# Exercise punctuation and BSD mktemp -t suffixes without swallowing verdicts.
printf '%s\n' 'clone dispatch-review-wt.Abc123.' '(dispatch-review-wt.Abc123XXXXXXXX)' 'dispatch-review-wt.Abc123/path' 'clone dispatch-review-wt.XXXXXX.Abc123XXXXXXXX,' | sed -E -f "$c/normalise.sed" > "$work/names"
printf '%s\n' 'clone dispatch-review-wt.<TMP>.' '(dispatch-review-wt.<TMP>)' 'dispatch-review-wt.<TMP>/path' 'clone dispatch-review-wt.<TMP>,' > "$work/expected-names"
# Normalisation must preserve meaningful differences beside the scratch name.
printf '%s\n' 'dispatch-review-wt.Abc123, exit 10 --review' | sed -E -f "$c/normalise.sed" > "$work/significant"
printf '%s\n' 'dispatch-review-wt.Abc123, exit 11 --review' | sed -E -f "$c/normalise.sed" > "$work/changed"
if cmp -s "$work/significant" "$work/changed"; then echo 'FAIL: exit difference hidden'; exit 1; fi
cmp "$work/names" "$work/expected-names" || { echo 'FAIL: worker workspace normalisation'; exit 1; }
mkdir -p "$work/recording/codex/1"
printf '0\n' > "$work/recording/codex/1/rc"
: > "$work/recording/codex/1/stdout"
: > "$work/recording/codex/1/stderr"
rc=0
SCN_TMP="$work" STUB_RECORDING="$work/recording" bash "$c/stubs/claude" </dev/null > "$work/out" 2> "$work/err" || rc=$?
[ "$rc" = 97 ] && grep -q 'stub claude: missing recording' "$work/err" || { echo 'FAIL: missing runtime recording'; exit 1; }
[ -d "$c/goldens/worker-agy-review" ] || { echo 'FAIL: worker goldens absent'; exit 1; }
python3 "$c/worker-coverage.py" "$c"
mkdir -p "$work/coverage/contract"
cp "$c/worker-coverage.tsv" "$c/worker-exemptions.tsv" "$work/coverage/"
ln -s "$c/scenarios" "$work/coverage/scenarios"
for kind in exit line flag env; do
  cp "$c/contract/inventory.tsv" "$work/coverage/contract/inventory.tsv"
  printf 'dispatch-worker\t%s\tnew-contract\tnew output\ttest\n' "$kind" >> "$work/coverage/contract/inventory.tsv"
  if python3 "$c/worker-coverage.py" "$work/coverage" > "$work/error" 2>&1; then
    echo "FAIL: uncovered worker $kind accepted"; exit 1
  fi
  grep -q 'uncovered inventory rows' "$work/error"
done
# Keep agent work outside TMPDIR, including when this suite's scratch is under /tmp.
export DISPATCH_CONFORMANCE_ROOT="$work/root"
if ! bash "$c/run.sh" --impl "${IMPL_BIN:-$here/../bin}" --out "$work/actual" --only worker-; then
  for marker in "$work/actual"/*/harness-timeout; do
    [ -f "$marker" ] || continue
    directory=${marker%/harness-timeout}
    printf 'FAIL: scenario budget exceeded: %s\n' "${directory##*/}"
    cat "$directory/stderr"
  done
  exit 1
fi
python3 "$c/worker-coverage.py" "$c" "$work/actual"
mkdir "$work/expected"
for dir in "$c"/goldens/worker-*; do ln -s "$dir" "$work/expected/${dir##*/}"; done
if ! bash "$c/compare.sh" "$work/expected" "$work/actual" > "$work/comparison"; then
  cat "$work/comparison"
  # Keep failures diagnosable even though the private scratch tree is reclaimed.
  observation=$(sed -n 's@^\([^ /]*\)/stderr differs$@\1@p' "$work/comparison")
  if [ -n "$observation" ]; then
    printf '%s\n' 'Expected stderr:'
    cat "$work/expected/$observation/stderr"
    printf '%s\n' 'Actual stderr:'
    cat "$work/actual/$observation/stderr"
  fi
  exit 1
fi
echo 'PASS: worker conformance and inventory coverage'
