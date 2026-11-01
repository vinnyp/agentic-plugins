#!/usr/bin/env bash
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# Migrated suites and scenarios must not regain implementation sourcing.
python3 - "$here" <<'SOURCE_GUARD'
import csv
from pathlib import Path
import re
import sys
root = Path(sys.argv[1]).parent
conformance = root / 'test/conformance'
with (conformance / 'source-allowlist.tsv').open() as stream:
    allowed = {row['source_test']: row['reason']
               for row in csv.DictReader(stream, delimiter='\t')}
with (conformance / 'rewrite-map.tsv').open() as stream:
    migrated = {row['source_test'] for row in csv.DictReader(stream, delimiter='\t')}
paths = set((conformance / 'scenarios').glob('*/scenario.sh'))
paths.update(root / name for name in migrated if (root / name).exists())
pattern = re.compile(r'^[ \t]*(source|\.)[ \t]+.*lib/', re.M)
for path in sorted(paths):
    name = str(path.relative_to(root))
    if pattern.search(path.read_text()):
        assert allowed.get(name), f'{name}: implementation sourcing without allowlist reason'
SOURCE_GUARD
work=$(mktemp -d "${TMPDIR:-/tmp}/conformance-test.XXXXXX")
[ -n "$work" ] || exit 1
export DISPATCH_CONFORMANCE_ROOT="$work/root"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$here/conformance/run.sh" ] || fail 'run.sh missing'
mkdir -p "$work/test" "$work/bin/lib"
cp -R "$here/conformance" "$work/test/conformance"
cp "$here/../bin/lib/timeout-bin.sh" "$here/../bin/lib/portable-timeout" "$work/bin/lib/"
h="$work/test/conformance"
rm -rf "$h/scenarios" "$h/goldens"
printf 'id\ttag\tissue\tbudget_s\tretry\n' > "$h/goldens.tsv"
# Exact expectations prevent a comparison from passing by erasing both values.
normalised_is() {
  local actual
  actual=$(printf '%s\n' "$2" | sed -E -f "$h/normalise.sed")
  [ "$actual" = "$3" ] || fail "$1: got $actual"
}
normalised_is 'epoch pinned_at normalised' 'pinned_at=1793495751' 'pinned_at=<TS>'
normalised_is 'phase slug normalised' 'branch=phase-my-repo-20261031230803-77539' 'branch=phase-my-repo-<TS>-<PID>'
normalised_is 'cd slug normalised' 'branch=cd-20261031230803-77539' 'branch=cd-<TS>-<PID>'
normalised_is 'review temp path normalised' 'REVIEW_OUTFILE=/tmp/dispatch-review.aB1234.md (rc=124) [retry]' 'REVIEW_OUTFILE=<REVIEW_TMP> (rc=124) [retry]'
normalised_is 'BSD review temp path normalised' 'REVIEW_OUTFILE=/var/folders/example/T/dispatch-review.aB12345678 (rc=0)' 'REVIEW_OUTFILE=<REVIEW_TMP> (rc=0)'
normalised_is 'worktree namespace hash normalised' 'worktree=<SCN_TMP>/.worktrees/my_repo_1a2b3c4d/cd-20261031230803-77539' 'worktree=<SCN_TMP>/.worktrees/my_repo_<HASH>/cd-<TS>-<PID>'
normalised_is 'state namespace directory' 'repo__1a2b3c4d' 'repo__<HASH>'
normalised_is 'state namespace contents' 'repo__1a2b3c4d/tracked.txt' 'repo__<HASH>/tracked.txt'
normalised_is 'state namespace path' '<SCN_TMP>/.worktrees/repo__1a2b3c4d' '<SCN_TMP>/.worktrees/repo__<HASH>'
normalised_is 'review worktree normalised' 'worktree=/tmp/dispatch-review-wt.aB1234/repo word' 'worktree=/tmp/dispatch-review-wt.<TMP>/repo word'
normalised_is 'review worktree prefix anchored' 'other-dispatch-review-wt.aB1234/repo' 'other-dispatch-review-wt.aB1234/repo'
normalised_is 'brief fingerprint preserved' '▶ brief fingerprint: abcdef123456 (42B); first line: brief' '▶ brief fingerprint: abcdef123456 (42B); first line: brief'
normalised_is 'normaliser context preserved' 'name_1a2b3c4d pinned_at=123x phase-myrepo-123 cd-123-456 REVIEW_OUTFILE=/tmp/custom.md' 'name_1a2b3c4d pinned_at=123x phase-myrepo-123 cd-123-456 REVIEW_OUTFILE=/tmp/custom.md'
normalised_is 'normaliser does not hide lines' 'pinned_at=1793495751
pid=77539
DISPATCH=fail
exit=2
--changed' 'pinned_at=<TS>
pid=<PID>
DISPATCH=fail
exit=2
--changed'
mkdir -p "$h/scenarios/sample" "$work/impl" "$work/recording"
printf 'hello\n' > "$work/recording/stdout"
printf 'diagnostic\n' > "$work/recording/stderr"
printf '0\n' > "$work/recording/rc"
export STUB_RECORDING="$work/recording"
cat > "$h/scenarios/sample/scenario.sh" <<'SCENARIO'
#!/usr/bin/env bash
printf 'tools=%s\n' "$PATH"
printf 'path=%s/file sha=0123456789abcdef0123456789abcdef01234567 base_sha=abcdef1 pid=123 pinned_at=1793495751 elapsed=12s cd-20261031230803-123 phase-build-20261031230803-123\n' "$SCN_TMP"
codex --sample "$IMPL_BIN"
SCENARIO
printf 'id\ttag\tissue\tbudget_s\tretry\nsample\tpreserve\t\t2\t0\n' > "$h/goldens.tsv"
bash "$h/run.sh" --impl "$work/impl" --out "$work/a"
bash "$h/run.sh" --impl "$work/impl" --out "$work/b"
bash "$h/compare.sh" "$work/a" "$work/b" || fail 'two runs with tool paths compare clean'
for stream in stdout stderr; do
for side in a b; do
  cp "$work/$side/sample/$stream" "$work/saved-stream"
  printf '/example/bin/lib/repo-state.sh: child setpgid (91436 to 91436): Operation not permitted\n' >> "$work/$side/sample/$stream"
  bash "$h/compare.sh" "$work/a" "$work/b" || fail 'setpgid race line ignored'
  cp "$work/saved-stream" "$work/$side/sample/$stream"
done
done
printf '/example/bin/lib/repo-state.sh: child setpgid (91436 to 91436): Operation not permitted extra\n' >> "$work/b/sample/stderr"
if bash "$h/compare.sh" "$work/a" "$work/b" > "$work/diff"; then fail 'other setpgid text still compared'; fi
case "$(cat "$work/diff")" in *'sample/stderr differs'*) ;; *) fail 'other setpgid text names stderr';; esac
cp "$work/recording/stderr" "$work/b/sample/stderr"
ln -s "$work/impl" "$work/impl-link"
bash "$h/run.sh" --impl "$work/impl-link" --out "$work/symlinked"
bash "$h/compare.sh" "$work/a" "$work/symlinked" || fail 'symlinked impl compares clean'
cp "$work/a/sample/scn_tmp" "$work/b/sample/scn_tmp"
cp "$work/a/sample/run_dir" "$work/b/sample/run_dir"
cp "$work/a/sample/stdout" "$work/original"
for change in call rc stderr exit dispatch argv state; do
  cp "$work/original" "$work/b/sample/stdout"
  cp "$work/a/sample/rc" "$work/b/sample/rc"
  cp "$work/a/sample/stderr" "$work/b/sample/stderr"
  cp "$work/a/sample/argv" "$work/b/sample/argv"
  case "$change" in
    call) printf 'changed\n' >> "$work/b/sample/call.codex.1"; field=call.codex.1 ;;
    rc) printf '9\n' > "$work/b/sample/rc"; field=rc ;;
    stderr) printf 'different\n' >> "$work/b/sample/stderr"; field=stderr ;;
    exit) printf 'exit=1 sha=0123456789abcdef0123456789abcdef01234567 pid=123\n' >> "$work/a/sample/stdout"; printf 'exit=2 sha=0123456789abcdef0123456789abcdef01234567 pid=123\n' >> "$work/b/sample/stdout"; field=stdout ;;
    dispatch) printf 'DISPATCH=ok\n' >> "$work/a/sample/stdout"; printf 'DISPATCH=fail\n' >> "$work/b/sample/stdout"; field=stdout ;;
    state) printf 'changed\n' > "$work/b/sample/state"; field=state ;;
    argv) printf '%s\n' '--changed' >> "$work/b/sample/argv"; field=argv ;;
  esac
  if bash "$h/compare.sh" "$work/a" "$work/b" > "$work/diff"; then fail "$change difference detected"; fi
  case "$(cat "$work/diff")" in *"sample/$field"*) ;; *) fail "$change names file" ;; esac
  cp "$work/original" "$work/a/sample/stdout"
  cp "$work/a/sample/call.codex.1" "$work/b/sample/call.codex.1"
done
cp "$work/a/sample/state" "$work/b/sample/state"
rm "$work/b/sample/state"
if bash "$h/compare.sh" "$work/a" "$work/b" > "$work/diff"; then fail 'missing state accepted'; fi
cp "$work/a/sample/state" "$work/b/sample/state"
cp "$work/a/sample/argv" "$work/b/sample/argv"
cp "$work/original" "$work/b/sample/stdout"
sed 's/0123456789abcdef0123456789abcdef01234567/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/; s/base_sha=abcdef1/base_sha=1234567/; s/pid=123/pid=456/; s/1793495751/1793499999/; s/elapsed=12s/elapsed=99s/; s/cd-20261031230803-123/cd-20271101230803-456/; s/phase-build-20261031230803-123/phase-build-20271101230803-456/' "$work/original" > "$work/b/sample/stdout"
bash "$h/compare.sh" "$work/a" "$work/b" || fail 'paths normalised'
printf 'worktree=/tmp/dispatch-review-wt.aB1234/repo same\n' > "$work/a/sample/stdout"
printf 'worktree=/tmp/dispatch-review-wt.Zz9876/repo same\n' > "$work/b/sample/stdout"
bash "$h/compare.sh" "$work/a" "$work/b" || fail 'review worktree paths compare clean'
printf 'worktree=/tmp/dispatch-review-wt.Zz9876/repo changed\n' > "$work/b/sample/stdout"
if bash "$h/compare.sh" "$work/a" "$work/b"; then fail 'changed word beside review worktree detected'; fi
printf 'id\ttag\tissue\tbudget_s\tretry\n' > "$h/goldens.tsv"
if bash "$h/run.sh" --impl "$work/impl" --out "$work/untagged"; then fail 'untagged golden refused'; fi
printf 'sample\tpreserve\t\t1\t1\n' >> "$h/goldens.tsv"
printf 'sleep 10\n' > "$h/scenarios/sample/scenario.sh"
# Force the portable fallback even on machines with GNU timers.
mkdir "$work/path"
for command in bash git jq dirname mkdir mktemp cat cp rm sed awk perl sleep ls env readlink find ln python3; do
  command_path=$(command -v "$command")
  ln -s "$command_path" "$work/path/$command"
done
if PATH="$work/path" bash "$h/run.sh" --impl "$work/impl" --out "$work/budget" 2> "$work/log"; then fail 'budget enforced'; fi
[ "$(cat "$work/budget/sample/rc")" = 124 ] || fail 'timeout rc'
case "$(cat "$work/log")" in *'retry sample'*) ;; *) fail 'retry logged' ;; esac

printf 'sample\tpreserve\t\t1\t0\n' > "$h/goldens.tsv"
if bash "$h/run.sh" --impl "$work/impl" --out "$work/no-retry"; then fail 'retry=0 budget enforced'; fi
[ ! -e "$work/no-retry/sample/retry.log" ] || fail 'retry=0 leaves no retry log'
[ -f "$work/no-retry/sample/harness-timeout" ] || fail 'retry=0 leaves timeout marker'

refused() {
  local label=$1 expected=$2
  shift 2
  if "$@" > "$work/refusal" 2>&1; then fail "$label"; fi
  grep -Fq -- "$expected" "$work/refusal" || fail "$label: wrong diagnostic: $(cat "$work/refusal")"
}
run_out() { bash "$h/run.sh" --impl "$work/impl" --out "$work/$1"; }
normalised_is 'review after scratch replacement' 'REVIEW_OUTFILE=<SCN_TMP>/dispatch-review.aB1234 (rc=0)' 'REVIEW_OUTFILE=<REVIEW_TMP> (rc=0)'
refused 'non-empty out refused' 'output directory must be empty' run_out a
refused 'only matches nothing refused' 'no scenarios executed' bash "$h/run.sh" --impl "$work/impl" --out "$work/no-match" --only absent
mkdir "$work/empty-a" "$work/empty-b"
refused 'empty compare refused' 'no scenarios to compare' bash "$h/compare.sh" "$work/empty-a" "$work/empty-b"
refused 'id sets differ refused' 'scenario id sets differ' bash "$h/compare.sh" "$work/a" "$work/empty-a"
refused 'timeout refused by compare' 'harness-timeout' bash "$h/compare.sh" "$work/budget" "$work/budget"
[ -f "$work/budget/sample/harness-timeout" ] || fail 'timeout marker'
mv "$h/scenarios" "$h/saved-scenarios"
printf 'id\ttag\tissue\tbudget_s\tretry\n' > "$h/goldens.tsv"
refused 'no scenarios refused' 'no scenarios executed' run_out no-scenarios
mv "$h/saved-scenarios" "$h/scenarios"
printf 'orphan\tpreserve\t\t2\t0\n' >> "$h/goldens.tsv"
refused 'orphan golden refused' 'orphan golden' run_out orphan
printf 'exit 0\n' > "$h/scenarios/sample/scenario.sh"
i=0
for row in 'known-defect||2|0' 'preserve||0|0' 'preserve||abc|0' 'preserve||2|2' 'bad||2|0' 'preserve||2' 'preserve||2|0|extra'; do
  i=$((i + 1))
  printf 'sample|%s\n' "$row" | tr '|' '\t' > "$h/goldens.tsv"
  refused "golden validator $row" "invalid golden" run_out "invalid-$i"
done
printf 'sample\tpreserve\t\t2\t1\n' > "$h/goldens.tsv"
printf 'exit 7\n' > "$h/scenarios/sample/scenario.sh"
run_out app-fail
[ "$(cat "$work/app-fail/sample/rc")" = 7 ] || fail 'application rc'
[ ! -e "$work/app-fail/sample/retry.log" ] || fail 'no retry on application failure'
for code in 124 125 137; do
  printf 'exit %s\n' "$code" > "$h/scenarios/sample/scenario.sh"
  run_out "app-$code"
  [ "$(cat "$work/app-$code/sample/rc")" = "$code" ] || fail 'application status preserved'
  [ ! -e "$work/app-$code/sample/retry.log" ] || fail 'application timer-like status not retried'
  [ ! -e "$work/app-$code/sample/harness-timeout" ] || fail 'application timer-like status not timeout'
done
cat > "$h/scenarios/sample/scenario.sh" <<'SCENARIO'
[ -z "${AGY_MODEL+x}${CODING_DISPATCH_TIMEOUT+x}" ] || exit 21
[ "$HOME" = "$SCN_TMP/home" ] || exit 22
[ "$TMPDIR" = "$SCN_TMP/tmp" ] || exit 23
case "$SCN_TMP" in *//*) exit 24 ;; esac
codex --sample "$IMPL_BIN"
SCENARIO
AGY_MODEL=poison CODING_DISPATCH_TIMEOUT=poison HOME="$work/poison-home" run_out poison
[ "$(cat "$work/poison/sample/rc")" = 0 ] || fail 'poison env absent'
printf 'codex --sample %q\n' "$(cd -P "$work/impl" && pwd)" > "$work/expected-argv"
cmp -s "$work/expected-argv" "$work/poison/sample/argv" || fail 'stub records argv'
# The producer holds the pipe open until the runner exits, with a hard deadline.
python3 - "$h/run.sh" "$work/impl" "$work" <<'PYTHON'
import subprocess
import sys
runner, impl, work = sys.argv[1:]
for label, data in [('open', b''), ('data', b'caller input\n')]:
    process = subprocess.Popen(['bash', runner, '--impl', impl, '--out', work + '/caller-' + label], stdin=subprocess.PIPE)
    try:
        if data:
            process.stdin.write(data)
            process.stdin.flush()
        assert process.wait(timeout=5) == 0, 'caller stdin ignored: runner failed'
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        process.stdin.close()
PYTHON
for input in "$work"/caller-*/sample/stdin.*; do
  [ -f "$input" ] && [ ! -s "$input" ] || fail 'caller stdin ignored'
done
mkdir "$work/impl-two"
bash "$h/run.sh" --impl "$work/impl-two" --out "$work/impl-two-out"
bash "$h/compare.sh" "$work/poison" "$work/impl-two-out" || fail 'two impl dirs compare clean'
printf 'printf one | codex exec -\n' > "$h/scenarios/sample/scenario.sh"
run_out stdin-one
printf 'printf two | codex exec -\n' > "$h/scenarios/sample/scenario.sh"
run_out stdin-two
refused 'stdin difference detected' 'stdin.codex.1 differs' bash "$h/compare.sh" "$work/stdin-one" "$work/stdin-two"
mkdir "$work/numbered"
for n in 1 2; do
  mkdir "$work/numbered/$n"
  printf '%s\n' "$n" > "$work/numbered/$n/stdout"
  : > "$work/numbered/$n/stderr"
  printf '0\n' > "$work/numbered/$n/rc"
done
printf 'codex\ncodex\ncodex\n' > "$h/scenarios/sample/scenario.sh"
STUB_RECORDING="$work/numbered" run_out multi
printf '1\n2\n' > "$work/expected-multi"
cmp -s "$work/expected-multi" "$work/multi/sample/stdout" || fail 'multi-call replay'
[ "$(cat "$work/multi/sample/rc")" = 97 ] || fail 'missing replay step exits 97'
grep -q 'missing recording step 3' "$work/multi/sample/stderr" || fail 'missing step diagnostic'
printf 'codex\ncodex\ncodex\n' > "$work/expected-argv"
cmp -s "$work/expected-argv" "$work/multi/sample/argv" || fail 'zero arguments record no quotes'
# Missing newline and retry presence remain observable.
cp -R "$work/stdin-one" "$work/newline"
printf 'hello' > "$work/newline/sample/stdout"
printf 'hello\n' > "$work/stdin-one/sample/stdout"
refused 'missing final newline detected' 'stdout differs' bash "$h/compare.sh" "$work/stdin-one" "$work/newline"
cp "$work/stdin-one/sample/stdout" "$work/newline/sample/stdout"
: > "$work/newline/sample/retry.log"
bash "$h/compare.sh" "$work/stdin-one" "$work/newline"
rm "$h/BASELINE"
# baseline guards run before any worktree operation.
rc=0
bash "$h/baseline-tree.sh" --oops > "$work/baseline-log" 2>&1 || rc=$?
[ "$rc" = 2 ] && grep -q usage "$work/baseline-log" || fail 'baseline leading dash refused'
rc=0
bash "$h/baseline-tree.sh" "$work/baseline" > "$work/baseline-log" 2>&1 || rc=$?
[ "$rc" = 2 ] && grep -q 'missing BASELINE' "$work/baseline-log" || fail 'missing baseline refused'
# Positive baseline fixture follows this suite temporary-directory idiom.
git -C "$work" init -q
git -C "$work" -c user.name=Conformance -c user.email=conformance@example.invalid commit --allow-empty -qm fixture
sha=$(git -C "$work" rev-parse HEAD)
printf 'sha=%s\nsource=fixture\nnote=pinned\n' "$sha" > "$h/BASELINE"
bash "$h/baseline-tree.sh" "$work/pinned"
[ "$(git -C "$work/pinned" rev-parse HEAD)" = "$sha" ] || fail 'baseline pinned SHA'
bash "$h/baseline-tree.sh" --remove "$work/pinned"
printf 'sample\tknown-defect\tpublic-issue\t2\t0\n' > "$h/goldens.tsv"
printf 'exit 0\n' > "$h/scenarios/sample/scenario.sh"
run_out known-defect
# Commit identity, XDG isolation, and writable global git config.
cat > "$h/scenarios/sample/scenario.sh" <<'SCENARIO'
set -eu
for pair in "cache:$XDG_CACHE_HOME" "config:$XDG_CONFIG_HOME" "data:$XDG_DATA_HOME" "state:$XDG_STATE_HOME" "runtime:$XDG_RUNTIME_DIR"; do
  [ "${pair#*:}" = "$SCN_TMP/${pair%%:*}" ]
done
[ "$GIT_CONFIG_GLOBAL" = "$HOME/gitconfig" ]
git config --global fixture.value isolated
mkdir "$SCN_REPO"
git -C "$SCN_REPO" init -q
git -C "$SCN_REPO" commit --allow-empty -qm fixture
SCENARIO
run_out git-usable
[ "$(cat "$work/git-usable/sample/rc")" = 0 ] || fail 'git usable and isolated'
mkdir "$work/operator" "$work/known-tmp"
ln -s "$(command -v jq)" "$work/operator/jq"
printf '#!/bin/bash\nexit 0\n' > "$work/operator/operator-secret-tool"
chmod +x "$work/operator/operator-secret-tool"
printf 'command -v operator-secret-tool && exit 9; exit 0\n' > "$h/scenarios/sample/scenario.sh"
PATH="$work/operator:$PATH" run_out hidden
[ "$(cat "$work/hidden/sample/rc")" = 0 ] || fail 'operator tool hidden'
printf 'printf "%%s\n" "$SCN_TMP"\n' > "$h/scenarios/sample/scenario.sh"
(unset DISPATCH_CONFORMANCE_ROOT; TMPDIR="$work/known-tmp" HOME="$work/fake-home" run_out outside)
case "$(cat "$work/outside/sample/stdout")" in "$work/known-tmp"/*) fail 'scratch outside TMPDIR' ;; esac
# Relationships across files distinguish wrong commits and repeated commits.
cp -R "$work/a" "$work/sha-a"
cp -R "$work/a" "$work/sha-b"
sha1=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
sha2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
printf '%s %s base_sha=aaaaaaa\n' "$sha1" "$sha2" > "$work/sha-a/sample/stdout"
cp "$work/sha-a/sample/stdout" "$work/sha-b/sample/stdout"
printf '%s\n' "$sha1" > "$work/sha-a/sample/stderr"
printf '%s\n' "$sha2" > "$work/sha-b/sample/stderr"
refused 'wrong commit detected' 'stderr differs' bash "$h/compare.sh" "$work/sha-a" "$work/sha-b"
cp "$work/sha-a/sample/stderr" "$work/sha-b/sample/stderr"
bash "$h/compare.sh" "$work/sha-a" "$work/sha-b" || fail 'same commit twice same token'
mkdir -p "$work/numbered/codex/1" "$work/numbered/claude/1"
for runtime in codex claude; do
  printf '%s\n' "$runtime" > "$work/numbered/$runtime/1/stdout"
  : > "$work/numbered/$runtime/1/stderr"
  echo 0 > "$work/numbered/$runtime/1/rc"
done
printf 'codex\nclaude\n' > "$h/scenarios/sample/scenario.sh"
STUB_RECORDING="$work/numbered" run_out runtime
printf 'codex\nclaude\n' > "$work/runtime-expected"
cmp -s "$work/runtime-expected" "$work/runtime/sample/stdout" || fail 'per-runtime recording'
mkdir -p "$work/runtime-only/codex"
cp -R "$work/numbered/codex/1" "$work/runtime-only/codex/1"
printf 'codex\ncodex\n' > "$h/scenarios/sample/scenario.sh"
STUB_RECORDING="$work/runtime-only" run_out runtime-missing
[ "$(cat "$work/runtime-missing/sample/rc")" = 97 ] || fail 'per-runtime missing step exits 97'
grep -q 'missing recording step 2' "$work/runtime-missing/sample/stderr" || fail 'per-runtime missing step diagnostic'
# Signal only the runner started here, after its scenario is ready.
printf ': > %q\nsleep 10\n' "$work/term-ready" > "$h/scenarios/sample/scenario.sh"
bash "$h/run.sh" --impl "$work/impl" --out "$work/term" > "$work/term-stdout" 2> "$work/term-stderr" &
runner=$!
i=0
while [ ! -f "$work/term-ready" ] && [ "$i" -lt 100 ]; do
  sleep 0.1
  i=$((i + 1))
done
if [ ! -f "$work/term-ready" ]; then
  kill -KILL "$runner" 2>/dev/null || :
  wait "$runner" 2>/dev/null || :
  fail 'TERM scenario ready within 10 seconds'
fi
kill -TERM "$runner"
# Bash may defer its TERM trap until the scenario timer returns.
i=0
while kill -0 "$runner" 2>/dev/null && [ "$i" -lt 150 ]; do
  sleep 0.1
  i=$((i + 1))
done
if kill -0 "$runner" 2>/dev/null; then
  kill -KILL "$runner" 2>/dev/null || :
  wait "$runner" 2>/dev/null || :
  fail 'TERM runner exits within 15 seconds'
fi
rc=0
wait "$runner" || rc=$?
[ "$rc" = 143 ] || fail "TERM runner exit: got $rc"
grep -Fq 'conformance runner terminated' "$work/term-stderr" || fail 'TERM runner diagnostic'
[ -z "$(find "$work/root" -name 'run.*' -type d -print)" ] || fail 'TERM cleans run directory'
# Simulate helper failure without invoking a mutation tool or any implementation.
cat > "$work/bin/lib/failed-timer" <<'TIMER'
#!/usr/bin/env bash
exit 125
TIMER
chmod +x "$work/bin/lib/failed-timer"
cat > "$work/bin/lib/timeout-bin.sh" <<'HELPER'
dispatch_timeout_bin() { printf '%s/failed-timer\n' "$(dirname "${BASH_SOURCE[0]}")"; }
HELPER
refused 'timer failure refused' 'scenario timer failed' run_out timer-failed
grep -q 'scenario timer failed (rc=125)' "$work/refusal" || fail 'timer failure diagnostic'
[ ! -e "$(cat "$work/multi/sample/scn_tmp")" ] || fail 'scenario scratch removed'
echo 'PASS: conformance harness'
