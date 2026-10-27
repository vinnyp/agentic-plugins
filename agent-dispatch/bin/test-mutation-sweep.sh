#!/usr/bin/env bash
# shellcheck disable=SC2016
# shellcheck source=lib/portable-stat.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/portable-stat.sh"
set -eu
unset MUTATION_VERIFY_COPY_ROOT MUTATION_VERIFY_FILE MUTATION_VERIFY_SWEEP_JOBS MUTATION_VERIFY_SWEEP_TIMEOUT
BIN=$(cd "$(dirname "$0")" && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-mutation-sweep.XXXXXX")
[ -n "$TMP" ] || fail 'empty scratch directory'
TMP=$(cd -P "$TMP" && pwd -P)
cleanup() {
  local code=$? pid record
  # Failure paths own these child jobs and their unfinished mutant records.
  # Stop the controller first so a failing fixture cannot launch more work.
  for pid in $(jobs -pr); do kill -KILL "$pid" 2>/dev/null || :; done
  while IFS= read -r record; do
    [ ! -f "${record%.pid}.rc" ] || continue
    pid=$(cat "$record" 2>/dev/null) || continue
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill -TERM -- "-$pid" 2>/dev/null || :
    kill -KILL -- "-$pid" 2>/dev/null || :
  done < <(find "$TMP" -name '*.pid' -type f)
  wait 2>/dev/null || :
  chmod -R u+w "$TMP"; rm -rf "$TMP"
  return "$code"
}
trap cleanup EXIT
mkdir "$TMP/root" "$TMP/temps"
export TMPDIR="$TMP/temps"
cd "$TMP/root"
printf 'good\ncontrol\n' > subject
cat > check <<'CHECK'
grep -q control subject || { echo CONTROL; exit 1; }
grep -q good subject || { echo HAZARD; exit 1; }
grep -q odd subject && { echo OTHER; exit 1; }
exit 0
CHECK
base="--file subject --test-cmd 'bash check' --expect-fail-output HAZARD --control-sed 's/control/broken/' --control-expect-fail-output CONTROL"
verdict() { sed -n '/^mutation-verify.sh: /{/^mutation-verify.sh: hint: /!p;}' "$1" | tail -1; }
sweep() {
  local expected=$1 output=$2 lines=$3 actual=0
  shift 3
  bash "$BIN/mutation-sweep.sh" --copy-root . --mutants "$lines" --out "$TMP/$output" "$@" > "$TMP/$output.log" 2> "$TMP/$output.err" || actual=$?
  [ "$actual" = "$expected" ] || { cat "$TMP/$output.log" "$TMP/$output.err" >&2; fail "$output exit $actual expected $expected"; }
}
bad() {
  local message=$1 rc=0
  shift
  bash "$BIN/mutation-sweep.sh" "$@" > "$TMP/bad" 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "usage status for $message: $rc"
  grep -F -- "$message" "$TMP/bad" >/dev/null || fail "usage message: $message"
}
wait_file() {
  local path=$1 deadline=$((SECONDS+20))
  while [ ! -f "$path" ] && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.05; done
  [ -f "$path" ] || fail "timed out waiting for ${path##*/}"
}
no_copies() {
  local path
  for path in "$TMP/temps"/mutation-verify-copy.* "$TMP/temps"/mutation-sweep.[0-9]*; do
    [ ! -d "$path" ] || fail "temporary directory remains: ${path##*/}"
  done
}
known() {
  # The refused mutant's control escapes to the real subject via an environment
  # variable. This is the canary refusal, not a syntactically inert mutation.
  unset MUTATION_VERIFY__REAL_SUBJECT
  cat > escape-check <<'CHECK'
if [ -n "${MUTATION_VERIFY__REAL_SUBJECT:-}" ]; then
  grep -q control "$MUTATION_VERIFY__REAL_SUBJECT" || { echo CONTROL; exit 1; }
fi
grep -q good subject || { echo HAZARD; exit 1; }
exit 0
CHECK
  printf '%s\n' "$base --mutate-sed 's/good/bad/'" "$base --mutate-sed 's/good/good extra/'" "${base/bash check/bash escape-check} --mutate-sed 's/good/bad/'" "$base --mutate-sed 's/good/good odd/'" > "$TMP/lines"
  head -2 "$TMP/lines" >> "$TMP/lines.extra"
  head -2 "$TMP/lines" >> "$TMP/lines.extra"
  head -1 "$TMP/lines" >> "$TMP/lines.extra"
  tail -1 "$TMP/lines" >> "$TMP/lines.extra"
  cat "$TMP/lines.extra" >> "$TMP/lines"
  MUTATION_VERIFY__REAL_SUBJECT="$PWD/subject" sweep 4 known "$TMP/lines" -j 4
  [ "$(head -1 "$TMP/known.log")" = "Sweep dir: $TMP/known" ] || fail 'Sweep dir is first line'
  tree=$(sed -n 's/.* tree=//p' "$TMP/known/1.verdict")
  [[ "$tree" =~ ^[0-9a-f]+$ ]] || fail 'known tree is nonempty hex'
  [ "$(tail -1 "$TMP/known.log")" = "SWEEP: 4 caught, 3 unconfirmed-survived, 2 unconfirmed-unrelated, 1 errors, 0 missing of 10 tree=$tree" ] || { tail -3 "$TMP/known.log"; fail "exact known summary"; }
  n=0
  while IFS= read -r line; do
    n=$((n+1)); rc=0
    (set -f; eval "set -- $line"; MUTATION_VERIFY__REAL_SUBJECT="$PWD/subject" bash "$BIN/mutation-verify.sh" --copy-root . "$@") > "$TMP/serial" 2>&1 || rc=$?
    [ "$(cat "$TMP/known/$n.rc")" = "$rc" ] || fail "serial rc $n"
    [ "$(cat "$TMP/known/$n.verdict")" = "$(verdict "$TMP/serial")" ] || fail "serial verdict $n"
    [ "$(sed -n 's/.* tree=//p' "$TMP/known/$n.verdict")" = "$tree" ] || fail "summary tree matches mutant $n"
    [ "$(grep -Fc "MUTANT $n rc=$rc $(cat "$TMP/known/$n.verdict")" "$TMP/known.log")" = 1 ] || fail "one exact mutant output $n"
  done < "$TMP/lines"
  grep -q 'CONTROL STAYED GREEN' "$TMP/known/3.verdict" || fail 'canary escape verdict'
  [ "$(grep -c '^MUTANT ' "$TMP/known.err")" = 10 ] || fail 'one stderr progress line per mutant'
  MUTATION_VERIFY__REAL_SUBJECT="$PWD/subject" MUTATION_VERIFY__TEST_DROP=2 sweep 1 missing "$TMP/lines"
  grep -q '1 missing of 10' "$TMP/missing.log" || fail 'missing bucket'
  head -1 "$TMP/lines" > "$TMP/one"
  sweep 0 caught "$TMP/one"
  sed "s/s\/good\/bad\//s\/good\/good extra\//" "$TMP/one" > "$TMP/survivor"
  sweep 0 measured-survivor "$TMP/survivor"
  unset MUTATION_VERIFY__REAL_SUBJECT
}
interface() {
  printf '%s\n' "$base --mutate-sed '/good/d'" > "$TMP/slash-lines"
  sweep 0 slash "$TMP/slash-lines"
  grep -q CAUGHT "$TMP/slash/1.verdict" || fail 'slash sed accepted and caught'
  printf '%s\n' "$base --mutate-sed '/good/s/good/bad/' --syntax-cmd '/usr/bin/env bash -n check'" > "$TMP/absolute-command-lines"
  sweep 0 absolute-command "$TMP/absolute-command-lines"
  bad 'jobs must be a positive integer' --copy-root . --mutants "$TMP/slash-lines" -j 0
  bad 'timeout must be a positive integer' --copy-root . --mutants "$TMP/slash-lines" --timeout 0
  MUTATION_VERIFY_SWEEP_TIMEOUT=bad bad 'timeout must be a positive integer' --copy-root . --mutants "$TMP/slash-lines"
  bad '--copy-root and --mutants are required' --mutants "$TMP/slash-lines"
  printf '%s\n' '--file /absolute' > "$TMP/badlines"
  bad 'line 1: absolute --file' --copy-root . --mutants "$TMP/badlines"
  printf '%s\n' "--file subject --test-cmd 'cat $(pwd -P)/subject'" > "$TMP/badlines"
  bad 'line 1: references the real root' --copy-root . --mutants "$TMP/badlines"
  printf '%s\n' "--file '" > "$TMP/badlines"
  bad 'line 1: parse failure' --copy-root . --mutants "$TMP/badlines"
  for line in '--file $(echo subject)' '--file <(echo subject)' '--file >(cat)'; do
    printf '%s\n' "$line" > "$TMP/badlines"
    bad 'line 1: substitution refused' --copy-root . --mutants "$TMP/badlines"
  done
  printf '%s\n' "--file subject --test-cmd 'bash check' --mutate-sed 's/good/bad/'" > "$TMP/badlines"
  bad 'line 1: requires --control-sed or --control-cmd' --copy-root . --mutants "$TMP/badlines"
  no_copies
  bash "$BIN/mutation-sweep.sh" --help > "$TMP/help" || fail 'help status'
  for text in '--timeout S' 'trusted shell input' 'not a sandbox' 'MUTATION_VERIFY_SWEEP_JOBS' 'MUTATION_VERIFY_SWEEP_TIMEOUT' '130/143/129' 'unconfirmed'; do
    grep -F -- "$text" "$TMP/help" >/dev/null || fail "help includes $text"
  done
  bash "$BIN/mutation-sweep.sh" -h > "$TMP/short-help" || fail 'short help status'
  cmp "$TMP/help" "$TMP/short-help" || fail 'help aliases agree'
}
isolation() {
  printf '%s\n' "$base --mutate-sed 's/good/bad/'" > "$TMP/one"
  sweep 0 original "$TMP/one"
  expected=$(sed -n 's/.* tree=//p' "$TMP/original/1.verdict")
  [[ "$expected" =~ ^[0-9a-f]+$ ]] || fail 'isolation expected nonempty hex'
  for n in 1 2 3 4 5 6 7 8; do cat "$TMP/one"; done > "$TMP/eight"
  (
    wait_file "$TMP/isolation/1.rc"
    printf '# barrier edit\n' >> check
  ) &
  barrier=$!
  sweep 0 isolation "$TMP/eight" -j 2
  wait "$barrier" || fail 'isolation barrier failed'
  for n in 1 2 3 4 5 6 7 8; do
    [ "$(sed -n 's/.* tree=//p' "$TMP/isolation/$n.verdict")" = "$expected" ] || fail "isolation tree $n"
    grep -q CAUGHT "$TMP/isolation/$n.verdict" || fail "isolation caught $n"
    [ "$(cat "$TMP/isolation/$n.rc")" = 0 ] || fail "isolation rc $n"
  done
  (set -f; eval "set -- $(cat "$TMP/one")"; bash "$BIN/mutation-verify.sh" --copy-root . "$@") > "$TMP/edited-serial" 2>&1 || fail 'edited serial copy run'
  grep -q CAUGHT "$TMP/edited-serial" || fail 'edited serial caught'
  [ "$(verdict "$TMP/edited-serial" | sed -n 's/.* tree=//p')" != "$expected" ] || fail 'edited tree hash differs'
}
file_env() {
  before=$(cksum < subject); before_mtime=$(ls -lT subject 2>/dev/null || ls -l --full-time subject)
  cat > env-check <<'CHECK'
grep -q control "$MUTATION_VERIFY_FILE" || { echo CONTROL; exit 1; }
grep -q good "$MUTATION_VERIFY_FILE" || { echo HAZARD; exit 1; }
CHECK
  cat > "$TMP/env-line" <<'LINE'
--file subject --test-cmd 'bash env-check "$MUTATION_VERIFY_FILE"' --expect-fail-output HAZARD --mutate-cmd 'sed "s/good/bad/" "$MUTATION_VERIFY_FILE" > changed; cat changed > "$MUTATION_VERIFY_FILE"' --control-sed 's/control/broken/' --control-expect-fail-output CONTROL
LINE
  sweep 0 file-env "$TMP/env-line"
  grep -Eq 'CAUGHT.*tree=[0-9a-f]+$' "$TMP/file-env/1.verdict" || fail 'file env caught with hash'
  [ "$(cksum < subject)" = "$before" ] || fail 'file env real checksum'
  [ "$(ls -lT subject 2>/dev/null || ls -l --full-time subject)" = "$before_mtime" ] || fail 'file env real mtime'
}
parallel() {
  unset MUTATION_VERIFY__BARRIER
  mkdir "$TMP/rendezvous"
  cat > parallel-check <<'CHECK'
[ "${RUN_TESTS_JOBS:-}" = 1 ] || { echo INNER_JOBS; exit 1; }
# Every phase in each mutant pairs with the corresponding other mutant phase.
phase=baseline
grep -q control subject || phase=control
grep -q good subject || phase=mutant
: > "$MUTATION_VERIFY__BARRIER/$phase.$1"
deadline=$((SECONDS+15))
while [ ! -f "$MUTATION_VERIFY__BARRIER/$phase.$2" ] && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.05; done
[ -f "$MUTATION_VERIFY__BARRIER/$phase.$2" ] || { echo RENDEZVOUS; exit 1; }
grep -q control subject || { echo CONTROL; exit 1; }
grep -q good subject || { echo HAZARD; exit 1; }
CHECK
  printf '%s\n' "${base/bash check/bash parallel-check 1 2} --mutate-sed 's/good/bad/'" "${base/bash check/bash parallel-check 2 1} --mutate-sed 's/good/bad/'" > "$TMP/parallel-lines"
  MUTATION_VERIFY__BARRIER="$TMP/rendezvous" sweep 0 parallel "$TMP/parallel-lines" -j 2
  unset MUTATION_VERIFY__BARRIER
  for n in 1 2; do grep -q CAUGHT "$TMP/parallel/$n.verdict" || fail "parallel rendezvous $n"; done
}
subdirectory() {
  mkdir nested
  printf '%s\n' "--file ../subject --test-cmd 'cd ..; bash check' --expect-fail-output HAZARD --mutate-sed 's/good/bad/' --control-sed 's/control/broken/' --control-expect-fail-output CONTROL" > "$TMP/sub-lines"
  (cd nested && bash "$BIN/mutation-sweep.sh" --copy-root .. --mutants "$TMP/sub-lines" --out "$TMP/subdirectory" > "$TMP/subdirectory.log" 2> "$TMP/subdirectory.err") || fail 'subdirectory exit'
  grep -q CAUGHT "$TMP/subdirectory/1.verdict" || fail 'subdirectory caught'
}
timeouts() {
  printf '%s\n' "${base/bash check/sleep 5; bash check} --mutate-sed 's/good/bad/'" > "$TMP/timeout-lines"
  sweep 4 timeout "$TMP/timeout-lines" --timeout 1
  grep -q TIMEOUT "$TMP/timeout/1.verdict" || fail 'timeout verdict'
  case "$(cat "$TMP/timeout/1.rc")" in 124|137) ;; *) fail 'timeout status';; esac
  grep -q '1 errors, 0 missing of 1' "$TMP/timeout.log" || fail 'timeout error bucket'
  no_copies
  mkdir "$TMP/no-timeout-bin"
  for tool in bash dirname readlink sed tail mv rm chmod mktemp mkdir cp find sort cksum cut ls awk basename cat grep sleep getconf xargs stat date; do
    ln -s "$(command -v "$tool")" "$TMP/no-timeout-bin/$tool"
  done
  PATH="$TMP/no-timeout-bin" sweep 4 watchdog "$TMP/timeout-lines" --timeout 1 -j 1
  grep -q TIMEOUT "$TMP/watchdog/1.verdict" || fail 'fallback watchdog timeout verdict'
  no_copies
}
leftovers() {
  # Only the main phase leaks, after printing the real assertion failure.
  cat > leaking-check <<'CHECK'
grep -q control subject || { echo CONTROL; exit 1; }
if ! grep -q good subject; then
  sleep 30 >/dev/null 2>&1 &
  echo HAZARD
  exit 1
fi
CHECK
  printf '%s\n' "${base/bash check/bash leaking-check} --mutate-sed 's/good/bad/'" > "$TMP/leaking-lines"
  sweep 4 leftovers "$TMP/leaking-lines" --timeout 60
  grep -q 'left processes running' "$TMP/leftovers/1.verdict" || fail 'leftover process verdict'
  [ "$(grep -o ' tree=' "$TMP/leftovers/1.verdict" | wc -l | tr -d ' ')" = 1 ] || fail 'one leaked tree hash'
  no_copies
}
unsafe_lines() {
  local before before_mtime suffix
  before=$(cksum < subject)
  before_mtime=$(pstat_mtime subject)
  for suffix in '> subject' '& touch REAL_SIDE_EFFECT' '| cat' '< subject' '; touch REAL_SIDE_EFFECT' "$'subject'"; do
    printf '%s\n' "$base --mutate-sed 's/good/bad/' $suffix" > "$TMP/unsafe"
    bad 'line 1: substitution refused' --copy-root . --mutants "$TMP/unsafe"
    [ "$(cksum < subject)" = "$before" ] || fail 'unsafe checksum'
    [ "$(pstat_mtime subject)" = "$before_mtime" ] || fail 'unsafe mtime'
    [ ! -e REAL_SIDE_EFFECT ] || fail 'unsafe side effect'
  done
}
killed_label() {
  printf '%s\n' "${base/bash check/kill -9 \$\$} --mutate-sed 's/good/bad/'" > "$TMP/self-kill-lines"
  sweep 4 self-kill "$TMP/self-kill-lines"
  grep -F 'killed (rc 137)' "$TMP/self-kill/1.verdict" >/dev/null || fail 'SIGKILL label'
  no_copies
}
short_child() {
  cat > short-check <<'CHECK'
grep -q control subject || { echo CONTROL; exit 1; }
if ! grep -q good subject; then
  sleep 0.5 >/dev/null 2>&1 &
  echo HAZARD
  exit 1
fi
CHECK
  printf '%s\n' "${base/bash check/bash short-check} --mutate-sed 's/good/bad/'" > "$TMP/short-lines"
  sweep 0 short-child "$TMP/short-lines"
  grep -q CAUGHT "$TMP/short-child/1.verdict" || fail 'short child caught'
}
signal_case() {
  local label=$1 ignore=$2 rc=0 started worker deadline path
  export MUTATION_VERIFY__SIGNAL_READY="$TMP/$label.ready"
  if [ "$ignore" = yes ]; then
    cat > signal-check <<'CHECK'
if grep -q good subject && grep -q control subject; then
  trap '' TERM
  : > "$MUTATION_VERIFY__SIGNAL_READY"
  sleep 60
fi
bash check
CHECK
  else
    printf 'if grep -q good subject && grep -q control subject; then sleep 30; fi\nbash check\n' > signal-check
  fi
  printf '%s\n' "${base/bash check/bash signal-check} --mutate-sed 's/good/bad/'" > "$TMP/signal-lines"
  set -m
  bash "$BIN/mutation-sweep.sh" --copy-root . --mutants "$TMP/signal-lines" --out "$TMP/$label" > "$TMP/$label.log" 2>&1 &
  sweep_pid=$!
  set +m
  wait_file "$TMP/$label/1.pid"
  worker=$(cat "$TMP/$label/1.pid")
  # Poll for the actual copy, not a fixed sleep racing the launch.
  deadline=$((SECONDS+20)); found=0
  while [ "$SECONDS" -lt "$deadline" ]; do
    for path in "$TMP/temps"/mutation-verify-copy.*; do [ ! -d "$path" ] || found=1; done
    [ "$found" = 0 ] || break
    sleep 0.05
  done
  [ "$found" = 1 ] || fail "$label copy launch"
  if [ "$ignore" = yes ]; then wait_file "$MUTATION_VERIFY__SIGNAL_READY"; fi
  started=$SECONDS
  kill -INT "$sweep_pid"
  wait "$sweep_pid" || rc=$?
  elapsed=$((SECONDS-started))
  # This cleanup can only target the group this test started.
  alive=0
  if kill -0 -- "-$worker" 2>/dev/null; then
    alive=1; kill -TERM -- "-$worker" 2>/dev/null || :
    kill -KILL -- "-$worker" 2>/dev/null || :
  fi
  [ "$rc" = 130 ] || fail "$label signal status $rc"
  [ "$alive" = 0 ] || fail "$label child group remains"
  if [ "$ignore" = no ]; then [ "$elapsed" -lt 15 ] || fail 'INT returns before child sleep';
  else [ "$elapsed" -ge 16 ] || fail 'ignored TERM minimum grace'; [ "$elapsed" -le 30 ] || fail 'ignored TERM returns within grace plus ten'; fi
  tree=$(sed -n 's/^SWEEP: .* tree=//p' "$TMP/$label.log")
  grep -Fx "SWEEP: 0 caught, 0 unconfirmed-survived, 0 unconfirmed-unrelated, 0 errors, 1 missing of 1 tree=$tree" "$TMP/$label.log" >/dev/null || fail "$label partial summary"
  grep -q '^MUTANT ' "$TMP/$label.log" || fail "$label partial mutant output"
  no_copies
}
grace_case() {
  local sweep_pid rc=0
  export MUTATION_VERIFY__GRACE_READY="$TMP/grace.ready"
  export MUTATION_VERIFY__GRACE_DONE="$TMP/grace.done"
  cat > grace-check <<'CHECK'
if grep -q good subject && grep -q control subject; then
  trap 'trap "" TERM; sleep 4; : > "$MUTATION_VERIFY__GRACE_DONE"; exit 0' TERM
  : > "$MUTATION_VERIFY__GRACE_READY"
  sleep 30
fi
bash check
CHECK
  # Force a timeout leader that exits on TERM before its descendants, so the
  # fixture exercises worker/handler grace ownership on every platform.
  mkdir "$TMP/grace-bin"
  cat > "$TMP/grace-bin/timeout" <<'TIMEOUT'
#!/usr/bin/env bash
shift 3
trap 'exit 143' TERM
"$@" &
wait "$!"
TIMEOUT
  chmod +x "$TMP/grace-bin/timeout"
  printf '%s\n' "${base/bash check/bash grace-check} --mutate-sed 's/good/bad/'" > "$TMP/grace-lines"
  set -m
  PATH="$TMP/grace-bin:$PATH" bash "$BIN/mutation-sweep.sh" --copy-root . --mutants "$TMP/grace-lines" --out "$TMP/grace" > "$TMP/grace.log" 2>&1 &
  sweep_pid=$!
  set +m
  wait_file "$MUTATION_VERIFY__GRACE_READY"
  kill -INT "$sweep_pid"
  wait "$sweep_pid" || rc=$?
  [ "$rc" = 130 ] || fail 'grace signal exit'
  [ -f "$MUTATION_VERIFY__GRACE_DONE" ] || fail 'inner cleanup receives full signal grace'
  no_copies
}
finished_record() {
  local canary_pid sweep_pid rc=0 parent path
  printf 'sleep 30\nbash check\n' > record-check
  printf '%s\n' "$base --mutate-sed 's/good/bad/'" "${base/bash check/bash record-check} --mutate-sed 's/good/bad/'" > "$TMP/record-lines"
  set -m
  bash -c 'trap "exit 0" TERM; sleep 30' &
  canary_pid=$!
  bash "$BIN/mutation-sweep.sh" --copy-root . --mutants "$TMP/record-lines" -j 1 --out "$TMP/record" > "$TMP/record.log" 2>&1 &
  sweep_pid=$!
  set +m
  wait_file "$TMP/record/1.rc"
  wait_file "$TMP/record/2.pid"
  parent=
  for path in "$TMP/temps/mutation-sweep.$sweep_pid."*; do [ ! -d "$path" ] || parent=$path; done
  [ -n "$parent" ] || fail 'finished record parent directory'
  # Simulate a reused finished pgid, using only a process this fixture started.
  printf '%s\n' "$canary_pid" > "$parent/1.owner"
  kill -INT "$sweep_pid"
  wait "$sweep_pid" || rc=$?
  alive=0
  kill -0 "$canary_pid" 2>/dev/null && alive=1
  kill -TERM -- "-$canary_pid" 2>/dev/null || :
  wait "$canary_pid" || :
  [ "$rc" = 130 ] || fail 'finished record signal exit'
  [ "$alive" = 1 ] || fail 'finished record must not signal reused pgid'
  no_copies
}
sigkill_case() {
  local n worker before after rc=0
  printf 'sleep 30\nbash check\n' > kill-check
  for n in 1 2 3 4 5 6; do printf '%s\n' "${base/bash check/bash kill-check} --mutate-sed 's/good/bad/'"; done > "$TMP/kill-lines"
  set -m
  bash "$BIN/mutation-sweep.sh" --copy-root . --mutants "$TMP/kill-lines" -j 1 --out "$TMP/killed" > "$TMP/killed.log" 2>&1 &
  sweep_pid=$!
  set +m
  wait_file "$TMP/killed/1.pid"
  worker=$(cat "$TMP/killed/1.pid")
  kill -KILL "$sweep_pid"
  wait "$sweep_pid" || rc=$?
  [ "$rc" = 137 ] || fail 'SIGKILL parent status'
  sleep 8
  # Queued wrappers may record not-run, but must never launch another mutant.
  for n in 2 3 4 5 6; do
    [ ! -e "$TMP/killed/$n.out" ] || fail "SIGKILL launched queued mutant $n"
    [ ! -f "$TMP/killed/$n.rc" ] || [ "$(cat "$TMP/killed/$n.rc")" = not-run ] || fail "SIGKILL measured queued mutant $n"
  done
  before=$(find "$TMP/killed" -name '*.rc' | wc -l | tr -d ' ')
  sleep 1
  after=$(find "$TMP/killed" -name '*.rc' | wc -l | tr -d ' ')
  [ "$before" = "$after" ] || fail 'SIGKILL no further result appears'
  if kill -0 -- "-$worker" 2>/dev/null; then
    kill -TERM -- "-$worker" 2>/dev/null || :
    kill -KILL -- "-$worker" 2>/dev/null || :
    fail 'SIGKILL orphan mutant group remains'
  fi
  # A new invocation must reap the dead sweep and dead verifier directories.
  printf '%s\n' "$base --mutate-sed 's/good/bad/'" > "$TMP/one"
  mkdir "$TMP/temps/mutation-verify-copy.$sweep_pid.stale"
  sweep 0 reaper "$TMP/one"
  no_copies
}
selected=${1:-all}
for test in known unsafe_lines killed_label short_child interface isolation file_env parallel subdirectory timeouts leftovers signal ignored grace_case finished_record sigkill; do
  [ "$selected" = all ] || [ "$selected" = "$test" ] || continue
  case "$test" in signal) signal_case signal no;; ignored) signal_case ignored yes;; sigkill) sigkill_case;; *) "$test";; esac
  echo "$test sweep PASS"
done
echo 'ALL PASS (sweep)'
