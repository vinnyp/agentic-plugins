#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154
# Shared fixture setup and assertions; helper is intentionally not executable.
TEST_BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/run-tests-testlib.sh
. "$TEST_BIN/lib/run-tests-testlib.sh"
test_groups="changed only basics"
for g in $test_groups; do
 grep -q "group $g" "$0" || { echo "FAIL stale test group: $g"; exit 1; }
done
case "${RUN_TESTS__TEST_GROUP:-}" in
 *[[:space:]]*) echo "FAIL unknown test group: $RUN_TESTS__TEST_GROUP"; exit 1 ;;
esac
case " $test_groups " in
 *" ${RUN_TESTS__TEST_GROUP:-} "*) ;;
 *) if [ -n "${RUN_TESTS__TEST_GROUP:-}" ]; then echo "FAIL unknown test group: $RUN_TESTS__TEST_GROUP"; exit 1; fi ;;
esac
# Adjacent valid names used to pass the substring membership check.
if [ -z "${RUN_TESTS__TEST_GROUP:-}" ]; then
 for invalid_group in "${test_groups%% *} ${test_groups#* }" $'changed\tbasics' $'portable\naccounting'; do
  selector_rc=0
  RUN_TESTS__TEST_GROUP_EXPLICIT=1 RUN_TESTS__TEST_GROUP="$invalid_group" bash "$0" > "$TMP/selector-out" 2>&1 || selector_rc=$?
  [ "$selector_rc" = 1 ] && grep -qFx "FAIL unknown test group: $invalid_group" "$TMP/selector-out" || { echo 'FAIL whitespace test group accepted'; exit 1; }
 done
fi
if group changed; then
ROOT=$(make_repo)
printf '\n' >> "$ROOT/bin/test-b.sh"
run --changed
changed_selected test-b.sh
for scenario in committed pushed untracked outside lib tools rename union self explicitdiff entry runtime unmentioned empty nobase nogit deleted parsing exclusive explicit; do
 ROOT=$(make_repo)
 case "$scenario" in
 committed|pushed)
  echo edit >> "$ROOT/docs/a.md"
  git -C "$ROOT/.." add .
  git -C "$ROOT/.." -c user.name=Fixture -c user.email=fixture@example.com commit -qm edit
  if [ "$scenario" = pushed ]; then git -C "$ROOT/.." push -qu origin feat; fi ;;
 untracked) echo new > "$ROOT/docs/new.md" ;;
 outside) echo edit >> "$ROOT/../other/x.md" ;;
 lib) echo edit >> "$ROOT/bin/lib/h.sh" ;;
 tools) mkdir -p "$ROOT/tools"; echo code > "$ROOT/tools/tool.sh" ;;
 rename) git -C "$ROOT/.." mv agent-dispatch/bin/lib/h.sh agent-dispatch/docs/h.sh
  git -C "$ROOT/.." -c user.name=Fixture -c user.email=fixture@example.com commit -qm rename ;;
 self) suite test/extra.sh 'exit 0' ;;
 union) echo edit >> "$ROOT/docs/a.md"; echo edit >> "$ROOT/../other/x.md" ;;
 explicitdiff)
  echo edit >> "$ROOT/docs/a.md"; git -C "$ROOT/.." add .
  git -C "$ROOT/.." -c user.name=Fixture -c user.email=fixture@example.com commit -qm first
  explicit_base=$(git -C "$ROOT/.." rev-parse HEAD)
  echo edit >> "$ROOT/../other/x.md"; git -C "$ROOT/.." add .
  git -C "$ROOT/.." -c user.name=Fixture -c user.email=fixture@example.com commit -qm second
  run --changed; check test "$rc" = 4; check test "$(grep -c '^RUN  ' "$TMP/out")" = 2 ;;
 entry) echo edit >> "$ROOT/bin/tool.sh" ;;
 runtime) echo edit >> "$ROOT/docs/pre.md" ;;
 unmentioned) echo edit >> "$ROOT/README.md" ;;
 nobase) git -C "$ROOT/.." symbolic-ref --delete refs/remotes/origin/HEAD ;;
 nogit) mkdir "$TMP/no-git"; cp -R "$ROOT" "$TMP/no-git/agent-dispatch"; ROOT="$TMP/no-git/agent-dispatch" ;;
 deleted) rm "$ROOT/bin/test-c.sh" ;;
 parsing|exclusive|explicit) echo edit >> "$ROOT/docs/a.md" ;;
 esac
 case "$scenario" in
 explicitdiff) run --changed "$explicit_base" ;;
 parsing) run --changed -j 2 ;;
 exclusive) run --only test-a.sh --changed ;;
 explicit) run --changed origin/main ;;
 nogit) export GIT_CEILING_DIRECTORIES="$TMP"; run --changed; unset GIT_CEILING_DIRECTORIES ;;
 *) run --changed ;;
 esac
 case "$scenario" in
 committed|pushed|untracked|parsing|explicit) changed_selected test-a.sh ;;
 outside|explicitdiff) changed_selected test-b.sh ;;
 self) changed_selected extra.sh ;;
 union) check test "$rc" = 4; check test "$(grep -c '^RUN  ' "$TMP/out")" = 2 ;;
 lib|entry|tools|rename) changed_full 'code change' ;;
 runtime) changed_full 'runtime input of bin/' ;;
 empty) changed_full 'no changed files' ;;
 nobase) changed_full 'no base available' ;;
 nogit) changed_full 'git repository unavailable'
  export GIT_CEILING_DIRECTORIES="$TMP"
  run --changed nonexistent-ref
  unset GIT_CEILING_DIRECTORIES
  check test "$rc" = 2
  check grep -qFx 'run-tests.sh: not a git checkout' "$TMP/out" ;;
 deleted) changed_full 'suite deleted' 2 ;;
 unmentioned) changed_full 'changed file has no matching suite' ;;
 exclusive) check test "$rc" = 2 ;;
 esac
done
fi
if group only; then
fixture only
suite bin/test-a.sh 'exit 0'; suite bin/test-b.sh 'exit 7'; suite test/stray_commit.sh 'exit 0'
run --only test-a.sh
output_order
check test "$rc" = 4
check test "$(grep -c '^RUN  ' "$TMP/out")" = 1
check grep -qFx 'RUN  test-a.sh' "$TMP/out"
check test "$(tail -1 "$TMP/out")" = 'PARTIAL RUN: 1 of 3 suites — NOT the gate'
check test "$(grep -c '^GATE PASS' "$TMP/out")" = 0
rd=$(sed -n 's/^Run dir: //p' "$TMP/out"); check test ! -e "$rd"
run --only only/bin/test-a.sh --only test/stray_commit.sh
check test "$rc" = 4
check test "$(grep -c '^RUN  ' "$TMP/out")" = 2
check grep -qFx 'RUN  stray_commit.sh' "$TMP/out"
run --only nope.sh
check test "$rc" = 2; check grep -q 'no suite matches' "$TMP/out"
run --only test-a
check test "$rc" = 2; check grep -q 'no suite matches' "$TMP/out"
run --only test-b.sh
check test "$rc" = 1
check grep -qFx 'PARTIAL RUN: 1 of 3 suites — NOT the gate' "$TMP/out"
fixture ambiguous
suite bin/test-x.sh 'exit 0'; suite test/test-x.sh 'exit 0'
run --only test-x.sh
check test "$rc" = 2; check grep -q ambiguous "$TMP/out"
run --only test/test-x.sh
check test "$rc" = 4
check test "$(grep -c '^RUN  ' "$TMP/out")" = 1
if command -v shellcheck >/dev/null 2>&1; then
 fixture only-lint
 suite bin/test-a.sh 'exit 0'; suite bin/tool.sh 'unused_var=1'; chmod +x "$ROOT/bin/tool.sh"
 run --only test-a.sh
 check test "$rc" = 4
 check test "$(grep -c shellcheck "$TMP/out")" = 0
fi
fi
if group basics; then
full default
failures default
fixture exit255
suite bin/test-0.sh 'exit 255'; suite bin/test-1.sh 'touch "$TMPDIR/one"'; suite bin/test-2.sh 'touch "$TMPDIR/two"'
run -j 1
check test "$rc" = 1; check test -e "$TMP/one"; check test -e "$TMP/two"
check grep -q 'FAIL test-0.sh (exit 255,' "$TMP/out"
fixture missing
suite bin/test-b.sh 'exit 0'
export RUN_TESTS__TEST_DROP_RC=bin__test-b.sh
run
unset RUN_TESTS__TEST_DROP_RC
check test "$rc" = 1; check grep -qFx 'FAIL test-b.sh (no result)' "$TMP/out"
export RUN_TESTS__TEST_DROP_RC=junk:bin__test-b.sh
run
unset RUN_TESTS__TEST_DROP_RC
check test "$rc" = 1; check grep -qFx 'FAIL test-b.sh (no result)' "$TMP/out"
for args in '-j 0' '-j x' '--timeout 0' '--bogus' '-j' '--timeout' '--only'; do
 before_dirs=$(find "$TMP" -maxdepth 1 -name 'run-tests.*' -type d | wc -l | tr -d ' ')
 # Intentional word splitting for the argument pairs above.
 # shellcheck disable=SC2086
 rc=0; bash "$ROOT/bin/run-tests.sh" $args > "$TMP/usage-stdout" 2> "$TMP/out" || rc=$?
 check test ! -s "$TMP/usage-stdout"
 check test "$rc" = 2
 check test "$(find "$TMP" -maxdepth 1 -name 'run-tests.*' -type d | wc -l | tr -d ' ')" = "$before_dirs"
 check grep -q '^run-tests.sh: ' "$TMP/out"
 check grep -q '^usage: ' "$TMP/out"
 check test "$(grep -c '^Run dir:' "$TMP/out")" = 0
done
run -h; check test "$rc" = 0; check grep -q '^usage: ' "$TMP/out"
export RUN_TESTS_JOBS=-1
run; check test "$rc" = 2
export RUN_TESTS_JOBS=x
run -j 2; check test "$rc" = 0
unset RUN_TESTS_JOBS
fixture no-log
suite bin/test-a.sh 'rm "$TMPDIR"/run-tests.*/bin__test-a.sh.log; exit 7'
run
check test "$rc" = 1
check test "$(grep -c '^Log tail:' "$TMP/out")" = 0
check test "$(grep -c '^tail: ' "$TMP/out")" = 0
fixture sorted
suite bin/test-z.sh 'exit 0'; suite test/a.sh 'exit 0'
run
check test "$rc" = 0
check test "$(grep '^PASS ' "$TMP/out" | head -1 | sed 's/ ([0-9]*s)$//')" = 'PASS a.sh'
run --only bin/test-z.sh,test/a.sh
check test "$rc" = 4
check test "$(grep '^PASS ' "$TMP/out" | head -1 | sed 's/ ([0-9]*s)$//')" = 'PASS a.sh'
fixture serial
for name in a b c; do
 suite "bin/test-$name.sh" '[ -e "$TMPDIR/lock" ] && exit 9; touch "$TMPDIR/lock"; sleep 1; rm "$TMPDIR/lock"'
done
printf '%s\n' 'exit 7' >> "$ROOT/bin/test-b.sh"
printf '%s\n' 'touch "$TMPDIR/serial-c"' >> "$ROOT/bin/test-c.sh"
run -j 1
check test "$rc" = 1; check test -e "$TMP/serial-c"
check test "$(grep -c 'exit 9,' "$TMP/out")" = 0
rd=$(sed -n 's/^Run dir: //p' "$TMP/out")
check test -d "$rd"
case "$rd" in "$ROOT"/*) exit 1;; esac
fixture cleanup
suite bin/test-a.sh 'exit 0'
run; rd=$(sed -n 's/^Run dir: //p' "$TMP/out"); check test ! -e "$rd"
export RUN_TESTS_KEEP_LOGS=1
run; rd=$(sed -n 's/^Run dir: //p' "$TMP/out"); check test -d "$rd"
check test "$(find "$rd" -name '*.pid' | wc -l | tr -d ' ')" = 0
unset RUN_TESTS_KEEP_LOGS
zero default
if command -v shellcheck >/dev/null 2>&1; then
 fixture lint; suite bin/test-a.sh 'exit 0'; suite bin/tool.sh 'unused_var=1'; chmod +x "$ROOT/bin/tool.sh"
 run; check test "$rc" = 1; check test "$(grep -c '^GATE PASS' "$TMP/out")" = 0
else echo 'SKIP shellcheck failure'; fi
fi
if [ -n "${RUN_TESTS__TEST_GROUP:-}" ]; then echo "SKIP runner-basics: only group $RUN_TESTS__TEST_GROUP ran"; fi
echo 'PASS runner basics tests'
