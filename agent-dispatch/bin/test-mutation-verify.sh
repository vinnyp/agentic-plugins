#!/usr/bin/env bash
# shellcheck disable=SC2181
# test-mutation-verify.sh — TDD suite for mutation-verify.sh.
#
# Covers: RED (genuine test) -> exit 0; GREEN/false-green -> exit 1;
# no-op mutation -> exit 2; byte-identical restore in all cases; restore
# still happens when --test-cmd crashes UNDER MUTATION; a failing BASELINE
# (before mutation) aborts with exit 2 and leaves the file untouched; the
# load-bearing uncommitted-work case (the whole point of #115); a relative
# --file combined with a cd-ing --test-cmd (the #115 follow-up regression);
# a value-less trailing flag must exit 2 promptly instead of hanging; the
# --mutate-cmd happy path; temp-dir cleanup leaves no stray snapshot dirs;
# a failed restore KEEPS the snapshot and prints its path; and a static
# check that the script never invokes git; and --expect-fail-output, which
# rejects a RED run that failed for an unrelated reason (foundry#259).
# shellcheck source=lib/portable-stat.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/portable-stat.sh"
set -uo pipefail
unset MUTATION_VERIFY_COPY_ROOT MUTATION_VERIFY_FILE MUTATION_VERIFY_SWEEP_JOBS
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-mv-core.XXXXXX")
[ -n "$TMP" ] || exit 1
TMP=$(cd "$TMP" && pwd -P)
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
MV="$SELF_DIR/mutation-verify.sh"
fail() { echo "FAIL: $1"; exit 1; }

verdict_line() {
  sed -n '/^mutation-verify.sh: /{/^mutation-verify.sh: hint: /!p;}' "$1" | tail -1
}

# Installed entrypoints must produce precisely the direct invocation's result.
mkdir "$TMP/installed" "$TMP/symlink-root" "$TMP/reaper-tmp" "$TMP/broken"
ln -s "$MV" "$TMP/installed/mutation-verify.sh"
printf 'good\ncontrol\n' > "$TMP/symlink-root/subject"
cat > "$TMP/symlink-root/check" <<'CHECK'
grep -q control subject || { echo CONTROL; exit 1; }
grep -q good subject || { echo HAZARD; exit 1; }
CHECK
sleep 0 &
dead_owner=$!
wait "$dead_owner"
mkdir "$TMP/reaper-tmp/mutation-verify-copy.$dead_owner.stale" "$TMP/reaper-tmp/mutation-verify-copy.$$.live"
for invocation_mode in inplace copy; do
  copy_args=()
  [ "$invocation_mode" != copy ] || copy_args=(--copy-root .)
  for entry in direct symlink; do
    entry_path=$MV
    [ "$entry" != symlink ] || entry_path="$TMP/installed/mutation-verify.sh"
    (cd "$TMP/symlink-root" && TMPDIR="$TMP/reaper-tmp" bash "$entry_path" ${copy_args[@]+"${copy_args[@]}"} \
      --file subject --test-cmd 'bash check' --mutate-sed 's/good/bad/' \
      --control-sed 's/control/broken/' --expect-fail-output HAZARD \
      --control-expect-fail-output CONTROL) > "$TMP/$entry.out" 2> "$TMP/$entry.err"
    [ "$?" = 0 ] || { cat "$TMP/$entry.out" "$TMP/$entry.err"; fail "$invocation_mode $entry invocation failed"; }
  done
  [ "$(verdict_line "$TMP/direct.err")" = "$(verdict_line "$TMP/symlink.err")" ] || fail "$invocation_mode symlink verdict differs"
  direct_tree=$(sed -n 's/.* tree=//p' "$TMP/direct.err" | tail -1)
  [ "$invocation_mode" != copy ] || [ -n "$direct_tree" ] || fail "$invocation_mode direct tree missing"
  [ "$direct_tree" = "$(sed -n 's/.* tree=//p' "$TMP/symlink.err" | tail -1)" ] || fail "$invocation_mode symlink tree differs"
  cmp -s "$TMP/direct.out" "$TMP/symlink.out" || fail "$invocation_mode symlink stdout differs"
  cmp -s "$TMP/direct.err" "$TMP/symlink.err" || fail "$invocation_mode symlink stderr differs"
done
[ ! -d "$TMP/reaper-tmp/mutation-verify-copy.$dead_owner.stale" ] || fail 'dead owner copy survived'
[ -d "$TMP/reaper-tmp/mutation-verify-copy.$$.live" ] || fail 'live owner copy removed'
cp "$MV" "$TMP/broken/mutation-verify.sh"
bash "$TMP/broken/mutation-verify.sh" --help > "$TMP/broken.out" 2> "$TMP/broken.err"
[ "$?" = 2 ] || fail 'broken installation exit'
grep -F 'broken install:' "$TMP/broken.err" >/dev/null || fail 'broken installation diagnostic'

# Copy setup cases deliberately run before the legacy suite.
setup_root="$TMP/setup"
mkdir -p "$setup_root/tmp" "$TMP/copy-tmp"
printf 'hello world\n' > "$setup_root/subject.sh"
printf 'grep -q hello ./subject.sh\n' > "$setup_root/t.sh"
ln -s "$setup_root" "$TMP/setup-alias"
ln -s subject.sh "$setup_root/link.sh"
printf 'outside\n' > "$TMP/outside.sh"
copy_setup_case() {
  local message="$1"
  shift
  (cd "$setup_root" && TMPDIR="$TMP/copy-tmp" bash "$MV" \
    --file subject.sh --test-cmd 'bash ./t.sh' --mutate-sed 's/hello/goodbye/' \
    --expect-fail-output hazard --control-sed 's/world/control/' \
    --control-expect-fail-output control "$@") > "$TMP/setup-out" 2>&1
  local result=$?
  [ "$result" -eq 2 ] || fail "copy setup expected exit 2: $message"
  verdict_line "$TMP/setup-out" | grep -F -- "$message" >/dev/null || { cat "$TMP/setup-out"; fail "copy setup missing: $message"; }
}
copy_setup_case "--file does not exist: $setup_root/missing" --copy-root . --file missing
copy_setup_case "--file is not a regular file: $setup_root/tmp" --copy-root . --file tmp
copy_setup_case 'cannot resolve --file' --copy-root . --file missing-dir/x
copy_setup_case 'cannot resolve --copy-root' --copy-root ./missing-root
copy_setup_case '--copy-root given twice' --copy-root . --copy-root .
copy_setup_case '--file is not under --copy-root' --copy-root "$setup_root" --file "$TMP/outside.sh"
copy_setup_case '--file is a symlink; copy mode needs a regular file' --copy-root "$setup_root" --file link.sh
copy_setup_case 'ANCHOR NOT FOUND' --expect-anchor missing --copy-root "$TMP/setup-alias"
verdict_line "$TMP/setup-out" | grep -Eq 'tree=[0-9]+$' || fail 'alias verdict missing tree hash'
copy_setup_case 'ANCHOR NOT FOUND' --expect-anchor missing --copy-root .
verdict_line "$TMP/setup-out" | grep -Eq 'tree=[0-9]+$' || fail 'relative verdict missing tree hash'
for setup_flag in --test-cmd --mutate-cmd --syntax-cmd --control-cmd --knockout-cmd; do
  # Select mutually exclusive command variants when needed.
  case "$setup_flag" in
    --mutate-cmd)
      (cd "$setup_root" && bash "$MV" --file subject.sh --copy-root . \
        --test-cmd 'bash ./t.sh' --mutate-cmd "cat $setup_root/subject.sh" \
        --expect-fail-output hazard --control-sed 's/world/control/' \
        --control-expect-fail-output control) > "$TMP/setup-out" 2>&1
      [ "$?" -eq 2 ] || fail 'mutate command real path exit'
      grep -F 'command refers to the real tree (--mutate-cmd)' "$TMP/setup-out" >/dev/null || fail 'mutate command real path message'
      ;;
    --control-cmd) # The final occurrence replaces the default sed control below.
      (cd "$setup_root" && bash "$MV" --file subject.sh --copy-root . \
        --test-cmd 'bash ./t.sh' --mutate-sed 's/hello/goodbye/' \
        --expect-fail-output hazard --control-cmd "cat $setup_root/subject.sh" \
        --control-expect-fail-output control) > "$TMP/setup-out" 2>&1
      [ "$?" -eq 2 ] || fail 'control command real path exit'
      grep -F 'command refers to the real tree (--control-cmd)' "$TMP/setup-out" >/dev/null || fail 'control command real path message'
      ;;
    *) copy_setup_case "command refers to the real tree ($setup_flag)" --copy-root . "$setup_flag" "cat $setup_root/subject.sh" ;;
  esac
done
copy_setup_case 'command refers to the real tree (--test-cmd)' --copy-root . --test-cmd "cd $setup_root; ./t.sh"
copy_setup_case '--cover-check is not supported with --copy-root' --copy-root . --cover-check example
case "$setup_root" in
 /private/var/*)
  alternate_root="${setup_root#/private}"
  copy_setup_case 'command refers to the real tree (--test-cmd)' --copy-root . --test-cmd "cat $alternate_root/subject.sh"
  ;;
 /var/*)
  copy_setup_case 'command refers to the real tree (--test-cmd)' --copy-root . --test-cmd "cat /private$setup_root/subject.sh"
  ;;
esac
# Use a dedicated invocation because the helper intentionally fixes TMPDIR.
(cd "$setup_root" && TMPDIR="$setup_root/tmp" bash "$MV" --file subject.sh \
  --copy-root . --test-cmd 'bash ./t.sh' --mutate-sed 's/hello/goodbye/' \
  --expect-fail-output hazard --control-sed 's/world/control/' \
  --control-expect-fail-output control) > "$TMP/setup-out" 2>&1
[ "$?" -eq 2 ] || fail 'inside TMPDIR exit'
grep -F 'TMPDIR is inside --copy-root' "$TMP/setup-out" >/dev/null || fail 'inside TMPDIR message'
if [ "$(id -u)" -ne 0 ]; then
  printf 'unreadable\n' > "$setup_root/unreadable"
  chmod 000 "$setup_root/unreadable"
  copy_setup_case 'copy failed:' --copy-root .
  [ -z "$(find "$TMP/copy-tmp" -name 'mutation-verify-copy.*' -print)" ] || fail 'partial copy leaked'
  chmod 600 "$setup_root/unreadable"
else
  echo 'test copy failure SKIP (root)'
fi
(cd "$setup_root" && MUTATION_VERIFY_COPY_ROOT=/nonexistent MUTATION_VERIFY_FILE=/nonexistent \
  bash "$MV" --file subject.sh --test-cmd 'grep -q hello ./subject.sh' \
  --mutate-sed 's/hello/goodbye/') > "$TMP/setup-out" 2>&1
[ "$?" -eq 0 ] || fail 'output-only env changed in-place verdict'
grep -F 'CAUGHT' "$TMP/setup-out" >/dev/null || fail 'output-only env verdict'
! grep -q 'tree=' "$TMP/setup-out" || fail 'in-place tree hash'
[ "$(cat "$setup_root/subject.sh")" = 'hello world' ] || fail 'output-only env restore'
mkdir "$TMP/capture-tools"
cat > "$TMP/capture-tools/mktemp" <<EOF
#!/usr/bin/env bash
case "\${*: -1}" in
 */capture.*) printf '%s/missing/capture\\n' "\$(dirname "\${*: -1}")" ;;
 *) exec "$(command -v mktemp)" "\$@" ;;
esac
EOF
chmod +x "$TMP/capture-tools/mktemp"
(cd "$setup_root" && PATH="$TMP/capture-tools:$PATH" bash "$MV" --copy-root . --file subject.sh \
 --test-cmd 'bash ./t.sh' --mutate-sed s/hello/goodbye/ --expect-fail-output hazard \
 --control-sed s/world/control/ --control-expect-fail-output control) > "$TMP/capture-out" 2>&1
[ "$?" -eq 2 ] || fail 'capture failure status'
verdict_line "$TMP/capture-out" | grep -F 'capture failure:' >/dev/null || fail 'capture failure misreported as invalid instrument'
if [ "$(id -u)" -ne 0 ]; then
  (cd "$setup_root" && bash "$MV" --copy-root . --file subject.sh \
    --test-cmd 'parent=$(dirname "$MUTATION_VERIFY_COPY_ROOT"); chmod 500 "$parent"/capture.*; bash ./t.sh' \
    --mutate-sed s/hello/goodbye/ --expect-fail-output hazard \
    --control-sed s/world/control/ --control-expect-fail-output control) > "$TMP/probe-out" 2>&1
  [ "$?" -eq 2 ] || fail 'capture probe status'
  grep -F 'capture failure: cannot write output file' "$TMP/probe-out" >/dev/null || fail 'capture probe diagnostic'
fi
echo 'test copy setup and output-only environment PASS'
[ "${1:-all}" != setup ] || exit 0


# Routing fixtures use relative subjects; all command kinds log outside the tree.
route_root="$TMP/routing"
mkdir -p "$route_root/sub" "$route_root/.git" "$TMP/route-tmp"
printf 'private vcs\n' > "$route_root/.git/marker"
mkdir "$route_root/read-only"
printf 'retained file\n' > "$route_root/read-only/entry"
chmod 555 "$route_root/read-only"
touch "$route_root/.envrc"
printf 'guard=on\nother=on\n' > "$route_root/subject"
cat > "$route_root/sub/suite.sh" <<'EOF'
#!/usr/bin/env bash
kind=test
[ "${1:-}" != --deselect ] || kind=knockout
printf '%s %s\n' "$kind" "$(pwd -P)" >> "$MUTATION_VERIFY_TEST_ROUTE_LOG"
[ "$(pwd -P)" = "$(cd "$MUTATION_VERIFY_COPY_ROOT/sub" && pwd -P)" ] || exit 8
[ ! -e ../.git ] && [ -e ../.envrc ] || exit 7
parent="$(dirname "$MUTATION_VERIFY_COPY_ROOT")"
[ -d "$parent"/capture.* ] || { echo 'capture directory must be inside parent'; exit 9; }
case "$MUTATION_VERIFY_COPY_ROOT" in
 */control) [ ! -e "$parent/baseline" ] || { echo 'baseline copy retained'; exit 9; } ;;
 */main) [ ! -e "$parent/baseline" ] && [ ! -e "$parent/control" ] || { echo 'phase copies retained'; exit 9; } ;;
esac
if [ -n "${MUTATION_VERIFY_TEST_EDIT_REAL:-}" ]; then printf 'external\n' >> "$MUTATION_VERIFY_TEST_EDIT_REAL"; fi
if [ "${1:-}" = --deselect ]; then echo '1 deselected'; exit 0; fi
grep -q '^other=on$' ../subject || { echo control-failure; exit 1; }
grep -q '^guard=on$' ../subject || { echo hazard-failure; exit 1; }
echo '2 passed'
EOF
route_mtime() {
  pstat_mtime "$route_root/subject"
}
route_run() {
  (cd "$route_root/sub" && MUTATION_VERIFY_TEST_ROUTE_LOG="$TMP/route-log" TMPDIR="$TMP/route-tmp" bash "$MV" \
    --copy-root .. --file ../subject --test-cmd 'bash ./suite.sh' \
    --mutate-cmd 'printf "mutate %s\n" "$(pwd -P)" >> "$MUTATION_VERIFY_TEST_ROUTE_LOG"; printf "guard=off\nother=on\n" > ../subject' \
    --syntax-cmd 'printf "syntax %s\n" "$(pwd -P)" >> "$MUTATION_VERIFY_TEST_ROUTE_LOG"; test -s ../subject' \
    --control-cmd 'printf "control %s\n" "$(pwd -P)" >> "$MUTATION_VERIFY_TEST_ROUTE_LOG"; printf "guard=on\nother=off\n" > ../subject' \
    --expect-fail-output hazard-failure --control-expect-fail-output control-failure \
    --knockout-cmd 'bash ./suite.sh --deselect t.py::hazard' --knockout-expect-output '1 deselected')
}
touch -t 200001010000 "$route_root/subject"
route_sum="$(cksum < "$route_root/subject")"
route_time="$(route_mtime)"
case "$route_time" in ''|*[!0-9]*) fail 'mtime helper must return seconds' ;; esac
route_run > "$TMP/route-out" 2>&1
[ "$?" -eq 0 ] || { cat "$TMP/route-out"; fail 'copy routing verdict'; }
verdict_line "$TMP/route-out" | grep -Eq 'CAUGHT.*tree=[0-9a-f]+$' || fail 'copy routing terminal verdict'
[ "$(cksum < "$route_root/subject")" = "$route_sum" ] || fail 'copy changed real bytes'
[ "$(route_mtime)" = "$route_time" ] || fail 'copy changed real mtime'
! grep -q 'the real file changed' "$TMP/route-out" || fail 'spurious external-edit hint'
for kind in test mutate syntax knockout control; do
  grep -q "^$kind " "$TMP/route-log" || fail "missing routed $kind"
done
[ "$(grep -c '^test ' "$TMP/route-log")" -eq 3 ] || fail 'baseline, main and control must run'
[ "$(grep -c '^knockout ' "$TMP/route-log")" -eq 2 ] || fail 'both knock-outs must run'
while read -r kind location; do
  case "$location" in "$TMP/route-tmp"/mutation-verify-copy.*/pristine/*) fail 'command ran in pristine' ;;
    "$TMP/route-tmp"/mutation-verify-copy.*/*/sub) ;;
    *) fail "unmirrored $kind cwd: $location" ;;
  esac
done < "$TMP/route-log"
[ "$(awk '$1 == "test" {print $2}' "$TMP/route-log" | sort -u | wc -l | tr -d ' ')" -eq 3 ] || fail 'baseline control main copies must differ'
echo 'test copy-root: all five commands run in copies; cwd mirror, dotfiles, VCS and untouched real file PASS'
export MUTATION_VERIFY_TEST_EDIT_REAL="$route_root/subject"
route_run > "$TMP/route-edit-out" 2>&1
rc=$?
unset MUTATION_VERIFY_TEST_EDIT_REAL
[ "$rc" -eq 0 ] || { cat "$TMP/route-edit-out"; fail 'external edit changed verdict status'; }
grep -q '^mutation-verify.sh: hint: the real file changed' "$TMP/route-edit-out" || fail 'external edit hint absent'
verdict_line "$TMP/route-edit-out" | grep -Eq 'CAUGHT.*tree=[0-9a-f]+$' || fail 'external edit verdict'
echo 'test copy-root: external-edit hint preserves verdict PASS'

# Canary fixtures keep escapes inside scripts, invisible to command validation.
canary_root="$TMP/canary"
mkdir -p "$canary_root/tools"
printf 'guard=on\nother=on\n' > "$canary_root/subject.sh"
ln -s "$canary_root" "$TMP/canary-alias"
export FIXTURE_REAL="$canary_root" FIXTURE_ALIAS="$TMP/canary-alias"
cat > "$canary_root/tools/subject-tool" <<'EOF'
#!/usr/bin/env bash
cat "$(dirname "$0")/../subject.sh"
EOF
chmod +x "$canary_root/tools/subject-tool"
cat > "$canary_root/suite.sh" <<'EOF'
#!/usr/bin/env bash
case "$FIXTURE_MODE" in
 env) content="$(cat "$FIXTURE_REAL/subject.sh")" ;;
 cd) cd "$FIXTURE_REAL"; content="$(cat ./subject.sh)" ;;
 alias) content="$(cat "$FIXTURE_ALIAS/subject.sh")" ;;
 path) PATH="$FIXTURE_REAL/tools:$PATH"; content="$(subject-tool)" ;;
 cd-twin) cd "$MUTATION_VERIFY_COPY_ROOT"; content="$(cat ./subject.sh)" ;;
 alias-twin) ln -s "$MUTATION_VERIFY_COPY_ROOT" ./copy-alias; content="$(cat ./copy-alias/subject.sh)" ;;
 path-twin) PATH="$MUTATION_VERIFY_COPY_ROOT/tools:$PATH"; content="$(subject-tool)" ;;
 *) content="$(cat ./subject.sh)" ;;
esac
if ! echo "$content" | grep -q 'other=on'; then
  [ "$FIXTURE_MODE" != unrelated ] && echo control-failure
  [ "$FIXTURE_MODE" != exit3 ] || echo hazard-failure
  exit 1
fi
if ! echo "$content" | grep -q 'guard=on'; then
  [ "$FIXTURE_MODE" != weak ] || exit 0
  [ "$FIXTURE_MODE" != exit3 ] || { echo unrelated; exit 1; }
  [ "${1:-}" != --deselect ] || [ "$FIXTURE_MODE" = persists ] || { echo '1 deselected'; exit 0; }
  echo hazard-failure
  exit 1
fi
[ "${1:-}" != --deselect ] || echo '1 deselected'
EOF
canary_run() {
  (cd "$canary_root" && bash "$MV" --copy-root . --file subject.sh \
    --test-cmd 'bash ./suite.sh' --mutate-sed "${FIXTURE_MUTATION:-s/guard=on/guard=off/}" \
    --expect-fail-output hazard-failure --control-sed "${FIXTURE_CONTROL:-s/other=on/other=off/}" \
    --control-expect-fail-output control-failure "$@")
}
canary_check() {
  local want="$1" keyword="$2"
  shift 2
  canary_run "$@" > "$TMP/canary-out" 2>&1
  local actual=$?
  if [ "$FIXTURE_MODE" = env ] && [ "$actual" -ne 2 ]; then
    fail 'copy-root escape via env did not exit 2'
  fi
  [ "$actual" -eq "$want" ] || { cat "$TMP/canary-out"; fail "canary $FIXTURE_MODE exit $actual expected $want"; }
  verdict_line "$TMP/canary-out" | grep -F -- "$keyword" >/dev/null || fail "canary $FIXTURE_MODE verdict $keyword"
  verdict_line "$TMP/canary-out" | grep -Eq ' tree=[0-9a-f]+$' || fail 'canary tree suffix'
}
canary_message='CONTROL STAYED GREEN IN THE COPY — the test did not read the copy, or the control is inert; run the control in place to tell which'
for FIXTURE_MODE in env cd alias path; do
  export FIXTURE_MODE
  canary_check 2 "$canary_message"
  case "$FIXTURE_MODE" in cd) FIXTURE_MODE=cd-twin ;; alias) FIXTURE_MODE=alias-twin ;; path) FIXTURE_MODE=path-twin ;; *) FIXTURE_MODE=relative ;; esac
  canary_check 0 CAUGHT
  verdict_line "$TMP/canary-out" | grep -F '; control ran first (canary)' >/dev/null || fail 'canary suffix'
done
export FIXTURE_MODE=path-twin
canary_check 0 CAUGHT
export FIXTURE_MODE=relative FIXTURE_CONTROL='s/other=on/other=on # comment/'
canary_check 2 "$canary_message"
export FIXTURE_CONTROL='s/absent/unused/'
canary_check 2 'control mutation did not change subject.sh (no-op control)'
unset FIXTURE_CONTROL
canary_check 2 'CONTROL MARKER ABSENT' --control-marker missing-marker
canary_check 2 'CONTROL FILE INVALID' --syntax-cmd "grep -q 'other=on' ./subject.sh"
export FIXTURE_MODE=unrelated
canary_check 2 'CONTROL RED FOR AN UNRELATED REASON'
export FIXTURE_MODE=weak
canary_check 1 'NOT caught'
verdict_line "$TMP/canary-out" | grep -F '; INCONCLUSIVE in copy mode — confirm with a serial in-place run tree=' >/dev/null || fail 'exit 1 inconclusive'
export FIXTURE_MODE=exit3
canary_check 3 'RED FOR AN UNRELATED REASON'
verdict_line "$TMP/canary-out" | grep -F '; control ran first (canary)' >/dev/null || fail 'exit 3 canary'
verdict_line "$TMP/canary-out" | grep -F '; INCONCLUSIVE in copy mode — confirm with a serial in-place run tree=' >/dev/null || fail 'exit 3 inconclusive'
export FIXTURE_MODE=persists
canary_check 2 'TEXT PERSISTS' --knockout-cmd 'bash ./suite.sh --deselect t.py::hazard' --knockout-expect-output '1 deselected'
export FIXTURE_MODE=relative
canary_check 0 CAUGHT --knockout-cmd 'bash ./suite.sh --deselect t.py::hazard' --knockout-expect-output '1 deselected'
canary_sum="$(cksum < "$canary_root/subject.sh")"
canary_time="$(ls -lnT "$canary_root/subject.sh" 2>/dev/null || ls -ln --full-time "$canary_root/subject.sh")"
canary_run > "$TMP/solo-one" 2>&1
FIXTURE_MUTATION='s/guard=on/guard=disabled/' canary_run > "$TMP/solo-two" 2>&1
canary_run > "$TMP/parallel-one" 2>&1 &
canary_pid_one=$!
FIXTURE_MUTATION='s/guard=on/guard=disabled/' canary_run > "$TMP/parallel-two" 2>&1 &
canary_pid_two=$!
wait "$canary_pid_one" || fail 'parallel one'
wait "$canary_pid_two" || fail 'parallel two'
[ "$(verdict_line "$TMP/solo-one")" = "$(verdict_line "$TMP/parallel-one")" ] || fail 'parallel one verdict'
[ "$(verdict_line "$TMP/solo-two")" = "$(verdict_line "$TMP/parallel-two")" ] || fail 'parallel two verdict'
for canary_output in solo-one solo-two parallel-one parallel-two; do
  verdict_line "$TMP/$canary_output" | grep -Eq 'CAUGHT.* tree=[0-9a-f]+$' || fail 'concurrent verdict keyword and tree'
done
[ "$canary_sum" = "$(cksum < "$canary_root/subject.sh")" ] || fail 'parallel real bytes'
[ "$canary_time" = "$(ls -lnT "$canary_root/subject.sh" 2>/dev/null || ls -ln --full-time "$canary_root/subject.sh")" ] || fail 'parallel real mtime'
(cd "$canary_root" && bash "$MV" --copy-root . --file subject.sh --test-cmd true --mutate-sed s/on/off/) > "$TMP/no-control" 2>&1
[ "$?" -eq 2 ] || fail 'copy requires control status'
verdict_line "$TMP/no-control" | grep -F -- '--copy-root requires a control' >/dev/null || fail 'copy requires control message'
! grep -q 'tree=' "$TMP/no-control" || fail 'no-control refusal must precede snapshot'
# Fingerprints include every file's content and mode, but exclude mtimes.
export FIXTURE_MODE=relative
printf 'first\n' > "$canary_root/non-subject"
canary_check 0 CAUGHT
hash_first="$(verdict_line "$TMP/canary-out" | sed 's/.* tree=//')"
printf 'second\n' > "$canary_root/non-subject"
canary_check 0 CAUGHT
hash_second="$(verdict_line "$TMP/canary-out" | sed 's/.* tree=//')"
[ "$hash_first" != "$hash_second" ] || fail 'tree ignores non-subject content'
touch -t 200101010000 "$canary_root/non-subject"
canary_check 0 CAUGHT
[ "$hash_second" = "$(verdict_line "$TMP/canary-out" | sed 's/.* tree=//')" ] || fail 'tree includes mtime'
chmod +x "$canary_root/non-subject"
canary_check 0 CAUGHT
[ "$hash_second" != "$(verdict_line "$TMP/canary-out" | sed 's/.* tree=//')" ] || fail 'tree ignores file mode'
# Both commands expand the output-only file variable inside their copy.
(cd "$canary_root" && bash "$MV" --copy-root . --file subject.sh \
 --test-cmd 'content=$(cat "$MUTATION_VERIFY_FILE"); echo "$content" | grep -q other=on || { echo control-failure; exit 1; }; echo "$content" | grep -q guard=on || { echo hazard-failure; exit 1; }' \
 --mutate-cmd 'printf "guard=off\nother=on\n" > "$MUTATION_VERIFY_FILE"' \
 --expect-fail-output hazard-failure --control-sed s/other=on/other=off/ \
 --control-expect-fail-output control-failure) > "$TMP/file-env-out" 2>&1
[ "$?" -eq 0 ] || fail 'copy exported file command status'
verdict_line "$TMP/file-env-out" | grep -Eq 'CAUGHT.* tree=[0-9a-f]+$' || fail 'copy exported file verdict'
[ "$canary_sum" = "$(cksum < "$canary_root/subject.sh")" ] || fail 'exported file changed real bytes'
[ "$canary_time" = "$(ls -lnT "$canary_root/subject.sh" 2>/dev/null || ls -ln --full-time "$canary_root/subject.sh")" ] || fail 'exported file changed real mtime'
(cd "$TMP" && bash "$MV" --copy-root "$canary_root" --file "$canary_root/subject.sh" \
 --test-cmd true --mutate-sed s/on/off/ --control-sed s/on/off/ \
 --expect-fail-output hazard-failure --control-expect-fail-output control-failure) > "$TMP/outside-cwd" 2>&1
[ "$?" -eq 2 ] || fail 'outside cwd refusal status'
verdict_line "$TMP/outside-cwd" | grep -F 'caller cwd is outside --copy-root' >/dev/null || fail 'outside cwd refusal message'
echo 'test copy canary escapes, twins, verdicts and concurrency PASS'

# In-place output goldens normalise only the fixture path.
golden_check() {
  local name="$1" wanted_rc="$2"; shift 2
  bash "$MV" --file "$setup_root/subject.sh" --test-cmd 'grep -q hello "$MUTATION_VERIFY_TEST_GOLDEN_FILE"' \
    --mutate-sed s/hello/goodbye/ "$@" > "$TMP/golden-out" 2>&1
  local actual_rc=$?
  [ "$actual_rc" -eq "$wanted_rc" ] || fail "golden $name status"
  sed "s|$setup_root/subject.sh|<subject>|g" "$TMP/golden-out" > "$TMP/golden-normalised"
  cat > "$TMP/golden-expected"
  cmp -s "$TMP/golden-normalised" "$TMP/golden-expected" || { cat "$TMP/golden-normalised"; fail "golden $name output"; }
}
export MUTATION_VERIFY_TEST_GOLDEN_FILE="$setup_root/subject.sh"
golden_check caught 0 <<'EOF'
mutation-verify.sh: [UNVERIFIED APPLICATION] mutation CAUGHT (test-cmd exited 1 under mutation; reachability was NOT verified; failure cause was NOT checked, pass --expect-fail-output) — test went RED
EOF
golden_check survived 1 --test-cmd true <<'EOF'
mutation-verify.sh: [UNVERIFIED APPLICATION] mutation NOT caught (test-cmd exited 0 under mutation; reachability was NOT verified) — false-green test
EOF
golden_check unrelated 3 --expect-fail-output hazard-text <<'EOF'
mutation-verify.sh: [UNVERIFIED APPLICATION] RED FOR AN UNRELATED REASON (test-cmd exited 1 under mutation; reachability was NOT verified) — expected failure text absent: hazard-text
mutation-verify.sh: hint: the hazard assertion is not shown to have caught this mutant; treat it as a surviving mutant (a test gap). Change the expected text only if this output shows the hazard assertion itself failing at its own location (see docs/commands.md)
EOF
golden_check anchor 2 --expect-anchor missing-anchor <<'EOF'
mutation-verify.sh: ANCHOR NOT FOUND — expected anchor is absent from the unmutated <subject>: missing-anchor
mutation-verify.sh: hint: the mutation would target zero sites; fix the anchor, do not trust a verdict from this run
EOF
unset MUTATION_VERIFY_TEST_GOLDEN_FILE
echo 'test in-place verdict goldens PASS'

# ---------------------------------------------------------------------------
# Test 1: RED case — a genuine test that checks the file's content. Mutating
# the file must break the test (test-cmd exits non-zero) -> mutation-verify
# reports the mutation was CAUGHT: exit 0.
# ---------------------------------------------------------------------------
F1="$TMP/red_target.txt"
printf 'hello world\n' > "$F1"
before1="$(cat "$F1")"
cat > "$TMP/red_test.sh" <<EOF
#!/usr/bin/env bash
grep -q "hello world" "$F1"
EOF
chmod +x "$TMP/red_test.sh"
bash "$MV" --file "$F1" --test-cmd "$TMP/red_test.sh" --mutate-sed 's/hello/goodbye/' >"$TMP/out1" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out1"; fail "RED case: expected exit 0 (mutation caught), got $rc"; }
[ "$(cat "$F1")" = "$before1" ] || fail "RED case: file not byte-identical after restore"
echo "test RED case (genuine test) -> exit 0 PASS"

# ---------------------------------------------------------------------------
# Test 2: GREEN/false-green case — a test that ignores the file entirely.
# Mutating the file leaves test-cmd green -> mutation-verify must report
# the test does NOT isolate the fix: exit 1.
# ---------------------------------------------------------------------------
F2="$TMP/green_target.txt"
printf 'hello world\n' > "$F2"
before2="$(cat "$F2")"
printf '#!/usr/bin/env bash\ntrue\n' > "$TMP/green_test.sh"
chmod +x "$TMP/green_test.sh"
bash "$MV" --file "$F2" --test-cmd "$TMP/green_test.sh" --mutate-sed 's/hello/goodbye/' >"$TMP/out2" 2>&1
rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out2"; fail "GREEN/false-green case: expected exit 1, got $rc"; }
[ "$(cat "$F2")" = "$before2" ] || fail "GREEN/false-green case: file not byte-identical after restore"
echo "test GREEN/false-green case -> exit 1 PASS"

# ---------------------------------------------------------------------------
# Test 3: no-op mutation — the sed expression matches nothing, so the file
# is unchanged post-mutation. This must be caught as a hard error: exit 2.
# ---------------------------------------------------------------------------
F3="$TMP/noop_target.txt"
printf 'hello world\n' > "$F3"
before3="$(cat "$F3")"
printf '#!/usr/bin/env bash\ntrue\n' > "$TMP/noop_test.sh"
chmod +x "$TMP/noop_test.sh"
bash "$MV" --file "$F3" --test-cmd "$TMP/noop_test.sh" --mutate-sed 's/nonexistent-pattern/x/' >"$TMP/out3" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out3"; fail "no-op mutation: expected exit 2, got $rc"; }
grep -qi "unchanged\|no-op\|no changes\|did not change" "$TMP/out3" || { cat "$TMP/out3"; fail "no-op mutation: expected a clear error message"; }
[ "$(cat "$F3")" = "$before3" ] || fail "no-op mutation: file not byte-identical after restore"
echo "test no-op mutation -> exit 2 PASS"

# ---------------------------------------------------------------------------
# Test 4: restore still happens when --test-cmd crashes UNDER MUTATION (as
# opposed to a baseline failure — that's test 4b below). The test-cmd passes
# cleanly against the unmutated content (so it clears the baseline run) but
# execs a nonexistent command once the file has been mutated, so the
# under-mutation run dies with a command-not-found rather than a clean
# assertion failure. Restore must still run on every path.
# ---------------------------------------------------------------------------
F4="$TMP/crash_target.txt"
printf 'hello world\n' > "$F4"
before4="$(cat "$F4")"
cat > "$TMP/crash_test.sh" <<EOF
#!/usr/bin/env bash
if grep -q "hello world" "$F4"; then
  exit 0
else
  exec "$TMP/this-command-does-not-exist-anywhere"
fi
EOF
chmod +x "$TMP/crash_test.sh"
bash "$MV" --file "$F4" --test-cmd "$TMP/crash_test.sh" --mutate-sed 's/hello/goodbye/' >"$TMP/out4" 2>&1
rc=$?
# The under-mutation run command-not-founds (non-zero) -> mutation was
# "caught" (exit 0), same as any other non-zero test-cmd exit. The
# load-bearing assertion here is that the file is restored regardless.
[ "$rc" -eq 0 ] || { cat "$TMP/out4"; fail "crashing test-cmd under mutation: expected exit 0 (non-zero test-cmd = caught), got $rc"; }
[ "$(cat "$F4")" = "$before4" ] || fail "crashing test-cmd under mutation: file not restored/byte-identical"
echo "test restore happens when test-cmd crashes under mutation PASS"

# ---------------------------------------------------------------------------
# Test 4b (MAJOR 5): a --test-cmd that is already broken/failing BEFORE
# mutation must be caught by the baseline run and abort with exit 2 — a
# false green inside the false-green detector otherwise (if the baseline
# had been skipped, this would have exited 0 "mutation caught" for the
# wrong reason). The file must be left completely untouched: no mutation is
# ever attempted once the baseline fails.
# ---------------------------------------------------------------------------
F4B="$TMP/baseline_fail_target.txt"
printf 'hello world\n' > "$F4B"
before4b="$(cat "$F4B")"
bash "$MV" --file "$F4B" --test-cmd "$TMP/this-command-does-not-exist-anywhere" --mutate-sed 's/hello/goodbye/' >"$TMP/out4b" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out4b"; fail "baseline-fails: expected exit 2, got $rc"; }
grep -qi "baseline\|before mutation" "$TMP/out4b" || { cat "$TMP/out4b"; fail "baseline-fails: expected a message naming the baseline failure"; }
grep -q "SIGPIPE" "$TMP/out4b" && { cat "$TMP/out4b"; fail "baseline-fails: non-141 baseline failure must not emit SIGPIPE hint"; }
[ "$(cat "$F4B")" = "$before4b" ] || fail "baseline-fails: file was NOT left untouched"
echo "test baseline-fails (broken test-cmd) -> exit 2, file untouched PASS"

# ---------------------------------------------------------------------------
# Test 5 (the whole point of #115): a file with UNCOMMITTED modifications
# (staged or unstaged, ahead of HEAD) must be preserved EXACTLY after a
# mutation-verify run — not reverted to the last commit. This is the case
# that `git checkout -- <file>` gets wrong three times over (#33/#43/#115).
# ---------------------------------------------------------------------------
REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
F5="$REPO/dirty.txt"
printf 'committed baseline\n' > "$F5"
git -C "$REPO" add -A
git -C "$REPO" commit -qm baseline
# Now make an UNCOMMITTED edit — this is the "in-flight fix" the helper must protect.
printf 'committed baseline\nUNCOMMITTED fix in progress\n' > "$F5"
uncommitted_content="$(cat "$F5")"
[ -n "$(git -C "$REPO" status --porcelain -- dirty.txt)" ] || fail "setup: dirty.txt should show as modified before the run"
cat > "$TMP/dirty_test.sh" <<EOF
#!/usr/bin/env bash
grep -q "UNCOMMITTED fix in progress" "$F5"
EOF
chmod +x "$TMP/dirty_test.sh"
bash "$MV" --file "$F5" --test-cmd "$TMP/dirty_test.sh" --mutate-sed 's/UNCOMMITTED/MUTATED/' >"$TMP/out5" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out5"; fail "uncommitted-work case: expected exit 0 (mutation caught), got $rc"; }
[ "$(cat "$F5")" = "$uncommitted_content" ] || fail "uncommitted-work case: file was NOT preserved exactly (reverted to HEAD instead of the uncommitted edit?)"
[ "$(cat "$F5")" != "committed baseline" ] || fail "uncommitted-work case: file was reverted to the committed baseline — this is exactly the #33/#43/#115 bug"
echo "test uncommitted-work preserved exactly (not reverted to HEAD) PASS"

# ---------------------------------------------------------------------------
# Test 6: static assertion — the script must NEVER invoke git in any form.
# Strip full-line comments first (the doc header legitimately DISCUSSES git
# as the anti-pattern this helper replaces) and check only the executable
# code for a "git" token.
# ---------------------------------------------------------------------------
never_git_hits() {
  grep -v '^[[:space:]]*#' "$1" | grep -E '(^|[^a-zA-Z0-9_.-])git($|[^a-zA-Z0-9_-])'
}
never_git_hits "$SELF_DIR/mutation-sweep.sh" >"$TMP/sweep_never_git_hits" && fail "mutation-sweep.sh must NEVER invoke git"
never_git_hits "$MV" >"$TMP/never_git_hits" && fail "mutation-verify.sh must NEVER invoke git in any form (outside comments)"

# Exercise the same guard against executable tokens anywhere on a line.
while IFS= read -r git_line; do
  cp "$MV" "$TMP/never_git_subject.sh"
  printf '\n%s\n' "$git_line" >> "$TMP/never_git_subject.sh"
  never_git_hits "$TMP/never_git_subject.sh" >"$TMP/never_git_hits" || fail "never-git guard missed: $git_line"
done <<'GIT_INVOCATIONS'
git -C x status
x=$(git rev-parse HEAD)
x=`git log`
x; git status
if git rev-parse --git-dir >/dev/null; then :; fi
command git status
exec git status
! git diff
eval "git status"
GIT_INVOCATIONS
cp "$MV" "$TMP/never_git_subject.sh"
printf '\n%s\n' 'VCS_DIR_NAME=.git' >> "$TMP/never_git_subject.sh"
never_git_hits "$TMP/never_git_subject.sh" >"$TMP/never_git_hits" && fail "never-git guard must allow VCS_DIR_NAME=.git"
echo "test script contains no git invocation PASS"

# ---------------------------------------------------------------------------
# Test 7: bad args -> usage + exit 2.
# ---------------------------------------------------------------------------
bash "$MV" >"$TMP/out_usage" 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "missing args: expected exit 2, got $rc"
bash "$MV" --file "$TMP/does-not-exist.txt" --test-cmd true --mutate-sed 's/a/b/' >"$TMP/out_missing" 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "missing --file target: expected exit 2, got $rc"
F7="$TMP/both_mutate.txt"; printf 'x\n' > "$F7"
bash "$MV" --file "$F7" --test-cmd true --mutate-sed 's/a/b/' --mutate-cmd true >"$TMP/out_both" 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "both --mutate-sed and --mutate-cmd given: expected exit 2, got $rc"
bash "$MV" --file "$F7" --test-cmd true >"$TMP/out_neither" 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "neither --mutate-sed nor --mutate-cmd given: expected exit 2, got $rc"
echo "test bad args -> exit 2 with usage PASS"

# ---------------------------------------------------------------------------
# Test 8 (BLOCKER 2 regression): a value-less trailing flag (--file as the
# LAST argument, with no value after it) must exit 2 PROMPTLY. Before the
# fix, `shift 2` on a `$#`-of-1 arg list left `$#` unchanged and the parse
# loop spun forever. Wrapped in `timeout 15` so a regression fails loudly
# (timeout's 124) instead of hanging the whole suite.
# ---------------------------------------------------------------------------
timeout 15 bash "$MV" --file >"$TMP/out_trailing_flag" 2>&1
rc=$?
[ "$rc" -ne 124 ] || { cat "$TMP/out_trailing_flag"; fail "value-less trailing --file: HUNG (timeout 124) — BLOCKER 2 regression"; }
[ "$rc" -eq 2 ] || { cat "$TMP/out_trailing_flag"; fail "value-less trailing --file: expected exit 2, got $rc"; }
echo "test value-less trailing flag -> exit 2 promptly (no hang) PASS"

# ---------------------------------------------------------------------------
# Test 9 (BLOCKER 1 regression): a RELATIVE --file combined with a --test-cmd
# that `cd`s elsewhere. Before the fix, restore_file's `cp -p "$snap_file"
# "$file"` ran from the test-cmd's new cwd and wrote to the WRONG path,
# leaving the real target file MUTATED (and a stray copy at the wrong
# location) while the script still exited 0. The file must be restored
# byte-identically at its ORIGINAL absolute path, with no stray copy
# anywhere under the relative subdirectory the test-cmd cd'd into.
# ---------------------------------------------------------------------------
CDCASE="$TMP/cdcase"; mkdir -p "$CDCASE/sub"
(
  cd "$CDCASE" || exit 1
  printf 'hello world\n' > target.txt
  before9="$(cat target.txt)"
  # Content-aware test-cmd: cd's into sub/ (changing cwd) then checks the
  # target file's content via a path relative to sub/. Passes on the
  # original content (clears the baseline run) and fails once mutated, so
  # this proves cwd-independence rather than short-circuiting on a
  # permanently-broken test-cmd.
  bash "$MV" --file target.txt --test-cmd "cd sub && grep -q 'hello world' ../target.txt" --mutate-sed 's/hello/goodbye/' >out9 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || { cat out9; fail "relative --file + cd-ing test-cmd: expected exit 0 (mutation caught), got $rc"; }
  [ "$(cat target.txt)" = "$before9" ] || fail "relative --file + cd-ing test-cmd: target.txt not byte-identical at its original path after restore"
  [ ! -e sub/target.txt ] || fail "relative --file + cd-ing test-cmd: a stray copy was left at sub/target.txt"
)
[ $? -eq 0 ] || fail "relative --file + cd-ing test-cmd subshell reported failure"
echo "test relative --file + cd-ing test-cmd restores at the original path, no stray copy PASS"

# ---------------------------------------------------------------------------
# Test 10: --mutate-cmd HAPPY PATH. Previously --mutate-cmd was only
# exercised in the bad-args (--mutate-sed + --mutate-cmd together) test, so
# the actual mutation branch was entirely unverified. Use --mutate-cmd to
# perform the same content mutation as the sed cases and confirm the RED
# verdict + byte-identical restore.
# ---------------------------------------------------------------------------
F10="$TMP/mutate_cmd_target.txt"
printf 'hello world\n' > "$F10"
before10="$(cat "$F10")"
cat > "$TMP/mutate_cmd_test.sh" <<EOF
#!/usr/bin/env bash
grep -q "hello world" "$F10"
EOF
chmod +x "$TMP/mutate_cmd_test.sh"
bash "$MV" --file "$F10" --test-cmd "$TMP/mutate_cmd_test.sh" --mutate-cmd "printf 'goodbye world\n' > '$F10'" >"$TMP/out10" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out10"; fail "--mutate-cmd happy path: expected exit 0 (mutation caught), got $rc"; }
[ "$(cat "$F10")" = "$before10" ] || fail "--mutate-cmd happy path: file not byte-identical after restore"
echo "test --mutate-cmd happy path -> exit 0, byte-identical restore PASS"

# ---------------------------------------------------------------------------
# Test 11: temp-dir cleanup. Point TMPDIR at a controlled, empty directory;
# after a successful run it must contain NO leftover mutation-verify.*
# snapshot dirs. Reviewer-proven necessity: deleting the trap and the
# `rm -rf` leaves the rest of the suite fully green today, so this is the
# only test that would catch that regression.
# ---------------------------------------------------------------------------
CLEANTMP="$TMP/cleantmp"; mkdir -p "$CLEANTMP"
F11="$TMP/cleanup_target.txt"
printf 'hello world\n' > "$F11"
TMPDIR="$CLEANTMP" bash "$MV" --file "$F11" --test-cmd true --mutate-sed 's/hello/goodbye/' >"$TMP/out11" 2>&1
rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out11"; fail "temp-dir cleanup setup: expected exit 1 (false-green, test-cmd=true), got $rc"; }
leftover="$(find "$CLEANTMP" -mindepth 1 -name 'mutation-verify.*')"
[ -z "$leftover" ] || fail "temp-dir cleanup: leftover snapshot dir(s) after a successful run: $leftover"
echo "test temp-dir cleanup leaves no leftover mutation-verify.* dirs PASS"

# ---------------------------------------------------------------------------
# Test 12 (BLOCKER 4 regression): restore-failure KEEPS the snapshot. Force
# a restore failure by making the mutated file itself read-only (via
# --mutate-cmd, since the file must still be writable at mutation time) so
# the later `cp -p` restore is denied. The script must exit 2 AND the
# snapshot dir must still exist (not deleted by cleanup), with its path
# printed to stderr so the work is recoverable by hand.
# ---------------------------------------------------------------------------
F12="$TMP/restore_fail_target.txt"
printf 'hello world\n' > "$F12"
before12="$(cat "$F12")"
CLEANTMP12="$TMP/cleantmp12"; mkdir -p "$CLEANTMP12"
TMPDIR="$CLEANTMP12" bash "$MV" --file "$F12" --test-cmd true \
  --mutate-cmd "printf 'MUTATED\n' > '$F12' && chmod 444 '$F12'" \
  >"$TMP/out12" 2>&1
rc=$?
chmod 644 "$F12" 2>/dev/null || true
[ "$rc" -eq 2 ] || { cat "$TMP/out12"; fail "restore-failure: expected exit 2, got $rc"; }
grep -qi "restore failed" "$TMP/out12" || { cat "$TMP/out12"; fail "restore-failure: expected a RESTORE FAILED message"; }
snap_path="$(grep -oE '/[^ ]*mutation-verify\.[A-Za-z0-9]+' "$TMP/out12" | head -1)"
[ -n "$snap_path" ] || { cat "$TMP/out12"; fail "restore-failure: expected the snapshot dir's path to be printed"; }
[ -d "$snap_path" ] || fail "restore-failure: snapshot dir $snap_path was NOT kept (cleanup deleted the only surviving backup)"
[ -f "$snap_path/snapshot" ] || fail "restore-failure: snapshot file missing under $snap_path"
[ "$(cat "$snap_path/snapshot")" = "$before12" ] || fail "restore-failure: kept snapshot does not match the original content"
rm -rf "$snap_path"
echo "test restore-failure keeps the snapshot and prints its path PASS"

# ---------------------------------------------------------------------------
# Test 14 (applied-verification): --expect-anchor present. The anchor is checked
# against the original snapshot before mutation; a valid anchor must preserve
# the existing caught verdict and restore the file byte-identically.
# ---------------------------------------------------------------------------
F14="$TMP/expect_anchor_present.txt"
printf 'hello anchor world\n' > "$F14"
before14="$(cat "$F14")"
cat > "$TMP/expect_anchor_present_test.sh" <<EOF
#!/usr/bin/env bash
grep -q "hello anchor world" "$F14"
EOF
chmod +x "$TMP/expect_anchor_present_test.sh"
bash "$MV" --file "$F14" --test-cmd "$TMP/expect_anchor_present_test.sh" \
  --expect-anchor "anchor world" \
  --mutate-sed 's/hello/goodbye/' >"$TMP/out14" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out14"; fail "--expect-anchor present: expected exit 0, got $rc"; }
[ "$(cat "$F14")" = "$before14" ] || fail "--expect-anchor present: file not byte-identical after restore"
echo "test --expect-anchor present preserves verdict PASS"

# ---------------------------------------------------------------------------
# Test 15 (applied-verification): --expect-anchor absent. This is a harness error:
# the mutation target is not present in the original snapshot, so the helper
# must exit 2 before mutating and leave the file byte-identical.
# ---------------------------------------------------------------------------
F15="$TMP/expect_anchor_absent.txt"
printf 'hello world\n' > "$F15"
before15="$(cat "$F15")"
bash "$MV" --file "$F15" --test-cmd true \
  --expect-anchor "missing anchor" \
  --mutate-sed 's/hello/goodbye/' >"$TMP/out15" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out15"; fail "--expect-anchor absent: expected exit 2, got $rc"; }
grep -q "ANCHOR NOT FOUND" "$TMP/out15" || { cat "$TMP/out15"; fail "--expect-anchor absent: expected ANCHOR NOT FOUND"; }
[ "$(cat "$F15")" = "$before15" ] || fail "--expect-anchor absent: file not byte-identical after restore"
echo "test --expect-anchor absent -> exit 2 PASS"

# ---------------------------------------------------------------------------
# Test 16 (applied-verification): --expect-marker present after mutation. The marker
# proves the intended edit landed, while the content-aware test still drives
# the normal caught verdict.
# ---------------------------------------------------------------------------
F16="$TMP/expect_marker_present.txt"
printf 'hello world\n' > "$F16"
before16="$(cat "$F16")"
cat > "$TMP/expect_marker_present_test.sh" <<EOF
#!/usr/bin/env bash
grep -q "hello world" "$F16"
EOF
chmod +x "$TMP/expect_marker_present_test.sh"
bash "$MV" --file "$F16" --test-cmd "$TMP/expect_marker_present_test.sh" \
  --expect-marker "goodbye world" \
  --mutate-sed 's/hello/goodbye/' >"$TMP/out16" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out16"; fail "--expect-marker present: expected exit 0, got $rc"; }
[ "$(cat "$F16")" = "$before16" ] || fail "--expect-marker present: file not byte-identical after restore"
echo "test --expect-marker present preserves verdict PASS"

# ---------------------------------------------------------------------------
# Test 17 (applied-verification, load-bearing): bytes change, but the intended marker
# is absent and the test fails for an unrelated command-not-found reason.
# Without marker verification, this would be misreported as mutation CAUGHT
# (exit 0). The correct result is a harness error: exit 2.
# ---------------------------------------------------------------------------
F17="$TMP/marker_absent_unrelated_failure.txt"
printf 'state=original\n' > "$F17"
before17="$(cat "$F17")"
cat > "$TMP/marker_absent_unrelated_failure_test.sh" <<EOF
#!/usr/bin/env bash
if grep -q "state=original" "$F17"; then
  exit 0
fi
exec "$TMP/marker-absent-command-does-not-exist"
EOF
chmod +x "$TMP/marker_absent_unrelated_failure_test.sh"
bash "$MV" --file "$F17" --test-cmd "$TMP/marker_absent_unrelated_failure_test.sh" \
  --expect-marker "state=intended_marker" \
  --mutate-sed 's/state=original/state=wrong_edit/' >"$TMP/out17" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out17"; fail "marker absent with unrelated failure: expected exit 2, got $rc"; }
grep -q "MARKER ABSENT" "$TMP/out17" || { cat "$TMP/out17"; fail "marker absent with unrelated failure: expected MARKER ABSENT"; }
[ "$(cat "$F17")" = "$before17" ] || fail "marker absent with unrelated failure: file not byte-identical after restore"
echo "test marker absent blocks unrelated failure false-pass PASS"

# ---------------------------------------------------------------------------
# Test 18 (applied-verification): --syntax-cmd failing after mutation. A syntactically
# invalid mutated file is a harness error, because any later test failure
# would be the wrong red.
# ---------------------------------------------------------------------------
F18="$TMP/syntax_failing_target.sh"
printf 'echo ok\n' > "$F18"
before18="$(cat "$F18")"
bash "$MV" --file "$F18" --test-cmd true \
  --syntax-cmd "bash -n '$F18'" \
  --mutate-sed 's/echo ok/if then/' >"$TMP/out18" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out18"; fail "--syntax-cmd failing: expected exit 2, got $rc"; }
grep -q "MUTATED FILE INVALID" "$TMP/out18" || { cat "$TMP/out18"; fail "--syntax-cmd failing: expected MUTATED FILE INVALID"; }
[ "$(cat "$F18")" = "$before18" ] || fail "--syntax-cmd failing: file not byte-identical after restore"
echo "test --syntax-cmd failing -> exit 2 PASS"

# ---------------------------------------------------------------------------
# Test 19 (applied-verification): --syntax-cmd passing. A valid syntax command is
# enough to verify application for verdict-label purposes and must preserve
# the existing caught exit code.
# ---------------------------------------------------------------------------
F19="$TMP/syntax_passing_target.sh"
printf 'echo hello\n' > "$F19"
before19="$(cat "$F19")"
cat > "$TMP/syntax_passing_test.sh" <<EOF
#!/usr/bin/env bash
grep -q "echo hello" "$F19"
EOF
chmod +x "$TMP/syntax_passing_test.sh"
bash "$MV" --file "$F19" --test-cmd "$TMP/syntax_passing_test.sh" \
  --syntax-cmd "bash -n '$F19'" \
  --mutate-sed 's/echo hello/echo goodbye/' >"$TMP/out19" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out19"; fail "--syntax-cmd passing: expected exit 0, got $rc"; }
grep -q "\[UNVERIFIED APPLICATION\]" "$TMP/out19" && { cat "$TMP/out19"; fail "--syntax-cmd passing: verdict should not be labelled unverified"; }
[ "$(cat "$F19")" = "$before19" ] || fail "--syntax-cmd passing: file not byte-identical after restore"
echo "test --syntax-cmd passing preserves verified verdict PASS"

# ---------------------------------------------------------------------------
# Test 20 (applied-verification): no applied-verification flags supplied. Exit code
# remains identical to the legacy false-green path, but the verdict is
# labelled unverified.
# ---------------------------------------------------------------------------
F20="$TMP/unverified_no_flags.txt"
printf 'hello world\n' > "$F20"
before20="$(cat "$F20")"
bash "$MV" --file "$F20" --test-cmd true \
  --mutate-sed 's/hello/goodbye/' >"$TMP/out20" 2>&1
rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out20"; fail "no verification flags: expected legacy exit 1, got $rc"; }
grep -q "\[UNVERIFIED APPLICATION\]" "$TMP/out20" || { cat "$TMP/out20"; fail "no verification flags: expected unverified verdict label"; }
grep -qi "reachability was NOT verified" "$TMP/out20" || { cat "$TMP/out20"; fail "no cover-check flag: expected reachability-not-verified summary"; }
[ "$(cat "$F20")" = "$before20" ] || fail "no verification flags: file not byte-identical after restore"
echo "test no verification flags labels unchanged verdict PASS"

# ---------------------------------------------------------------------------
# Test 21 (applied-verification): two --expect-marker flags, second missing. Every
# supplied marker must be present; a partial match is still a harness error.
# ---------------------------------------------------------------------------
F21="$TMP/two_markers_second_missing.txt"
printf 'hello world\n' > "$F21"
before21="$(cat "$F21")"
bash "$MV" --file "$F21" --test-cmd true \
  --expect-marker "goodbye world" \
  --expect-marker "second marker missing" \
  --mutate-sed 's/hello/goodbye/' >"$TMP/out21" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out21"; fail "two markers second missing: expected exit 2, got $rc"; }
grep -q "MARKER ABSENT" "$TMP/out21" || { cat "$TMP/out21"; fail "two markers second missing: expected MARKER ABSENT"; }
[ "$(cat "$F21")" = "$before21" ] || fail "two markers second missing: file not byte-identical after restore"
echo "test repeated --expect-marker requires every marker PASS"

# ---------------------------------------------------------------------------
# Test 22 (bash-3.2 regression): explicitly use /bin/bash with
# none of the new array-backed flags. On macOS bash 3.2, unguarded empty
# array expansion under set -u fails with "unbound variable"; PATH-resolved
# bash may be newer and would not catch the regression.
# ---------------------------------------------------------------------------
if /bin/bash --version 2>/dev/null | head -1 | grep -q 'version 3\.'; then
  F22="$TMP/bash32_empty_arrays.txt"
  printf 'hello world\n' > "$F22"
  before22="$(cat "$F22")"
  /bin/bash "$MV" --file "$F22" --test-cmd true \
    --mutate-sed 's/hello/goodbye/' >"$TMP/out22" 2>&1
  rc=$?
  [ "$rc" -ne 127 ] || { cat "$TMP/out22"; fail "bash-3.2 empty arrays: command failed with rc 127"; }
  grep -q "unbound variable" "$TMP/out22" && { cat "$TMP/out22"; fail "bash-3.2 empty arrays: unguarded empty array expansion"; }
  [ "$(cat "$F22")" = "$before22" ] || fail "bash-3.2 empty arrays: file not byte-identical after restore"
  echo "test /bin/bash 3.x empty-array guarded expansion PASS"
else
  echo "SKIP bash-3.2 empty-array regression: /bin/bash is not 3.x"
fi

# ---------------------------------------------------------------------------
# Tests 29-33 (foundry#259): --expect-fail-output names the failure's cause.
# The target holds two lines; the test checks both and prints a distinct
# failure message for each. Mutating the "guard" line trips the hazard
# assertion; mutating the "banner" line trips only the incidental one.
# ---------------------------------------------------------------------------
F29="$TMP/cause_target.txt"
printf 'guard=on\nbanner=hello\n' > "$F29"
before29="$(cat "$F29")"
cat > "$TMP/cause_test.sh" <<EOF
#!/usr/bin/env bash
echo "running cause checks"
grep -q '^banner=hello\$' "$F29" || { echo "INCIDENTAL: banner text changed"; exit 1; }
grep -q '^guard=on\$' "$F29" || { echo "--- FAIL: guard[on].x disabled"; exit 1; }
exit 0
EOF
chmod +x "$TMP/cause_test.sh"

# 29: RED by the hazard assertion, needle present -> CAUGHT, text present.
bash "$MV" --file "$F29" --test-cmd "$TMP/cause_test.sh" --mutate-sed 's/^guard=on$/guard=off/' \
  --expect-fail-output "--- FAIL: guard[on].x disabled" >"$TMP/out29" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out29"; fail "--expect-fail-output present: expected exit 0, got $rc"; }
grep -q "expected failure text present in output" "$TMP/out29" || { cat "$TMP/out29"; fail "--expect-fail-output present: verdict must say the expected text was present"; }
grep -q "control NOT run, so the text's specificity is unchecked" "$TMP/out29" || { cat "$TMP/out29"; fail "--expect-fail-output without a control: verdict must say the control did not run"; }
grep -q "knock-out NOT run, so the text is not attributed to the hazard test" "$TMP/out29" || { cat "$TMP/out29"; fail "--expect-fail-output without a knock-out: verdict must say the knock-out did not run"; }
grep -F -q "matched: '--- FAIL: guard[on].x disabled'" "$TMP/out29" || { cat "$TMP/out29"; fail "--expect-fail-output present: verdict must name the matched text"; }
[ "$(grep -c "running cause checks" "$TMP/out29")" -eq 2 ] || { cat "$TMP/out29"; fail "--expect-fail-output present: both captured runs (baseline and mutated) must be printed back"; }
[ "$(cat "$F29")" = "$before29" ] || fail "--expect-fail-output present: file not byte-identical after restore"
echo "test --expect-fail-output: hazard RED -> exit 0 PASS"

# 30: RED for an unrelated reason (the incidental message) -> exit 3, not CAUGHT.
bash "$MV" --file "$F29" --test-cmd "$TMP/cause_test.sh" --mutate-sed 's/^banner=hello$/banner=bye/' \
  --expect-fail-output "--- FAIL: guard[on].x disabled" >"$TMP/out30" 2>&1
rc=$?
[ "$rc" -eq 3 ] || { cat "$TMP/out30"; fail "--expect-fail-output unrelated RED: expected exit 3, got $rc"; }
grep -q "RED FOR AN UNRELATED REASON" "$TMP/out30" || { cat "$TMP/out30"; fail "--expect-fail-output unrelated RED: expected the unrelated-reason message"; }
grep -q "INCIDENTAL: banner text changed" "$TMP/out30" || { cat "$TMP/out30"; fail "--expect-fail-output unrelated RED: the captured mutated-run output must be printed back"; }
grep -q "\[UNVERIFIED APPLICATION\] RED FOR AN UNRELATED REASON" "$TMP/out30" || { cat "$TMP/out30"; fail "--expect-fail-output unrelated RED: exit-3 line must carry the verdict prefix"; }
grep -q "RED FOR AN UNRELATED REASON (test-cmd exited 1 under mutation; reachability was NOT verified)" "$TMP/out30" || { cat "$TMP/out30"; fail "--expect-fail-output unrelated RED: exit-3 line must carry the reachability context"; }
grep -q "mutation CAUGHT" "$TMP/out30" && { cat "$TMP/out30"; fail "--expect-fail-output unrelated RED: must not report CAUGHT"; }
[ "$(cat "$F29")" = "$before29" ] || fail "--expect-fail-output unrelated RED: file not byte-identical after restore"
echo "test --expect-fail-output: unrelated RED -> exit 3 PASS"

# 31: a repeated flag requires every needle; the second is absent -> exit 3.
bash "$MV" --file "$F29" --test-cmd "$TMP/cause_test.sh" --mutate-sed 's/^guard=on$/guard=off/' \
  --expect-fail-output "--- FAIL: guard[on].x disabled" --expect-fail-output "never printed" >"$TMP/out31" 2>&1
rc=$?
[ "$rc" -eq 3 ] || { cat "$TMP/out31"; fail "repeated --expect-fail-output: expected exit 3, got $rc"; }
grep -q "never printed" "$TMP/out31" || { cat "$TMP/out31"; fail "repeated --expect-fail-output: message must name the missing text"; }
# 31b: the same with the missing text listed FIRST, so a loop that checks only
# the last text cannot pass.
bash "$MV" --file "$F29" --test-cmd "$TMP/cause_test.sh" --mutate-sed 's/^guard=on$/guard=off/' \
  --expect-fail-output "never printed" --expect-fail-output "--- FAIL: guard[on].x disabled" >"$TMP/out31b" 2>&1
rc=$?
[ "$rc" -eq 3 ] || { cat "$TMP/out31b"; fail "repeated --expect-fail-output, missing first: expected exit 3, got $rc"; }
grep -q "never printed" "$TMP/out31b" || { cat "$TMP/out31b"; fail "repeated --expect-fail-output, missing first: message must name the missing text"; }
# 31c: several texts, ALL present (one on stdout, one on stderr) -> CAUGHT,
# and the verdict lists every matched text.
cat > "$TMP/cause_two_test.sh" <<EOF
#!/usr/bin/env bash
grep -q '^guard=on\$' "$F29" || { echo "--- FAIL: guard[on].x disabled"; echo "detail: guard=off seen" >&2; exit 1; }
exit 0
EOF
chmod +x "$TMP/cause_two_test.sh"
bash "$MV" --file "$F29" --test-cmd "$TMP/cause_two_test.sh" --mutate-sed 's/^guard=on$/guard=off/' \
  --expect-fail-output "--- FAIL: guard[on].x disabled" --expect-fail-output "detail: guard=off seen" >"$TMP/out31c" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out31c"; fail "repeated --expect-fail-output, all present: expected exit 0, got $rc"; }
grep -F -q "matched: '--- FAIL: guard[on].x disabled', 'detail: guard=off seen'" "$TMP/out31c" || { cat "$TMP/out31c"; fail "repeated --expect-fail-output, all present: verdict must list every matched text"; }
[ "$(cat "$F29")" = "$before29" ] || fail "repeated --expect-fail-output, all present: file not byte-identical"
echo "test repeated --expect-fail-output requires every text PASS"

# 32: text the passing baseline already prints cannot identify a failure -> exit 2.
bash "$MV" --file "$F29" --test-cmd "$TMP/cause_test.sh" --mutate-sed 's/^guard=on$/guard=off/' \
  --expect-fail-output "running cause checks" >"$TMP/out32" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out32"; fail "baseline-printed --expect-fail-output: expected exit 2, got $rc"; }
grep -q "already appears in the passing baseline output" "$TMP/out32" || { cat "$TMP/out32"; fail "baseline-printed --expect-fail-output: expected the baseline message"; }
[ "$(cat "$F29")" = "$before29" ] || fail "baseline-printed --expect-fail-output: file not byte-identical"
# 32b: with several texts, a baseline-printed text listed SECOND is refused too.
bash "$MV" --file "$F29" --test-cmd "$TMP/cause_test.sh" --mutate-sed 's/^guard=on$/guard=off/' \
  --expect-fail-output "--- FAIL: guard[on].x disabled" --expect-fail-output "running cause checks" >"$TMP/out32b" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out32b"; fail "baseline-printed second --expect-fail-output: expected exit 2, got $rc"; }
grep -q "already appears in the passing baseline output" "$TMP/out32b" || { cat "$TMP/out32b"; fail "baseline-printed second --expect-fail-output: expected the baseline message"; }
echo "test --expect-fail-output text in baseline -> exit 2 PASS"

# 33: GREEN under mutation stays exit 1 with the flag; without the flag a
# CAUGHT verdict says its cause was not verified.
bash "$MV" --file "$F29" --test-cmd "$TMP/cause_test.sh" --mutate-cmd "printf 'extra=1\\n' >> '$F29'" \
  --expect-fail-output "--- FAIL: guard[on].x disabled" >"$TMP/out33a" 2>&1
rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out33a"; fail "--expect-fail-output GREEN: expected exit 1, got $rc"; }
bash "$MV" --file "$F29" --test-cmd "$TMP/cause_test.sh" --mutate-sed 's/^banner=hello$/banner=bye/' >"$TMP/out33b" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out33b"; fail "no --expect-fail-output: expected exit 0, got $rc"; }
grep -q "failure cause was NOT checked" "$TMP/out33b" || { cat "$TMP/out33b"; fail "no --expect-fail-output: CAUGHT must say the cause was not checked"; }
[ "$(cat "$F29")" = "$before29" ] || fail "--expect-fail-output GREEN/no-flag: file not byte-identical"
echo "test --expect-fail-output GREEN -> exit 1, unflagged CAUGHT names unverified cause PASS"

# 34: with --expect-fail-output the baseline is captured to a file; a
# baseline that FAILS must still abort (exit 2) before anything is mutated.
printf '#!/usr/bin/env bash\necho "HAZARD: guard disabled"\nexit 3\n' > "$TMP/cause_fail_test.sh"
chmod +x "$TMP/cause_fail_test.sh"
bash "$MV" --file "$F29" --test-cmd "$TMP/cause_fail_test.sh" --mutate-sed 's/^guard=on$/guard=off/' \
  --expect-fail-output "never printed" >"$TMP/out34" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out34"; fail "--expect-fail-output failing baseline: expected exit 2, got $rc"; }
grep -q "baseline exited 3" "$TMP/out34" || { cat "$TMP/out34"; fail "--expect-fail-output failing baseline: expected the baseline message with its exit code"; }
[ "$(cat "$F29")" = "$before29" ] || fail "--expect-fail-output failing baseline: file not byte-identical"
echo "test --expect-fail-output failing baseline -> exit 2 PASS"

# 35/36: an empty, whitespace-only or multi-line --expect-fail-output is refused at
# parse time (exit 2): grep -F would match every line, or OR the lines together.
for bad in "" "   " "$(printf 'HAZARD: guard disabled\nINCIDENTAL')" "$(printf 'a\rb')" "$(printf '\t')"; do
  bash "$MV" --file "$F29" --test-cmd "$TMP/cause_test.sh" --mutate-sed 's/^banner=hello$/banner=bye/' \
    --expect-fail-output "$bad" >"$TMP/out35" 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || { cat "$TMP/out35"; fail "degenerate --expect-fail-output: expected exit 2, got $rc"; }
  grep -q "must not be empty\|must be a single line" "$TMP/out35" || { cat "$TMP/out35"; fail "degenerate --expect-fail-output: expected a validation message"; }
  grep -q "mutation CAUGHT" "$TMP/out35" && { cat "$TMP/out35"; fail "degenerate --expect-fail-output: must not report CAUGHT"; }
  [ "$(cat "$F29")" = "$before29" ] || fail "degenerate --expect-fail-output: file not byte-identical"
done
echo "test empty/whitespace/multi-line --expect-fail-output -> exit 2 PASS"

# 37: the hazard message printed only on STDERR still counts (the mutated run's
# stderr is captured).
cat > "$TMP/cause_stderr_test.sh" <<EOF
#!/usr/bin/env bash
grep -q '^guard=on\$' "$F29" || { echo "HAZARD-ERR: guard disabled" >&2; exit 1; }
exit 0
EOF
chmod +x "$TMP/cause_stderr_test.sh"
bash "$MV" --file "$F29" --test-cmd "$TMP/cause_stderr_test.sh" --mutate-sed 's/^guard=on$/guard=off/' \
  --expect-fail-output "HAZARD-ERR: guard disabled" >"$TMP/out37" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out37"; fail "stderr hazard text: expected exit 0, got $rc"; }
echo "test --expect-fail-output reads the RED run's stderr PASS"

# 38: text the passing baseline prints only on STDERR is refused too (the
# baseline's stderr is captured).
cat > "$TMP/cause_stderr_baseline.sh" <<EOF
#!/usr/bin/env bash
echo "--- progress: checking guard [1]." >&2
grep -q '^guard=on\$' "$F29" || exit 1
exit 0
EOF
chmod +x "$TMP/cause_stderr_baseline.sh"
bash "$MV" --file "$F29" --test-cmd "$TMP/cause_stderr_baseline.sh" --mutate-sed 's/^guard=on$/guard=off/' \
  --expect-fail-output "--- progress: checking guard [1]." >"$TMP/out38" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out38"; fail "stderr baseline text: expected exit 2, got $rc"; }
grep -q "already appears in the passing baseline output" "$TMP/out38" || { cat "$TMP/out38"; fail "stderr baseline text: expected the baseline message"; }
echo "test --expect-fail-output refuses text the baseline prints on stderr PASS"

# 41: an empty --expect-fail-output with a SILENT passing baseline (nothing for
# the baseline refusal to match) must still never report CAUGHT: the parse-time
# refusal is the only guard on this route.
printf '#!/usr/bin/env bash\ngrep -q "^banner=hello$" "%s" || { echo "INCIDENTAL: banner text changed"; exit 1; }\nexit 0\n' "$F29" > "$TMP/cause_silent_test.sh"
chmod +x "$TMP/cause_silent_test.sh"
bash "$MV" --file "$F29" --test-cmd "$TMP/cause_silent_test.sh" --mutate-sed 's/^banner=hello$/banner=bye/' \
  --expect-fail-output "" >"$TMP/out41" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out41"; fail "empty --expect-fail-output, silent baseline: expected exit 2, got $rc"; }
grep -q "must not be empty" "$TMP/out41" || { cat "$TMP/out41"; fail "empty --expect-fail-output, silent baseline: expected the empty-text refusal"; }
grep -q "mutation CAUGHT" "$TMP/out41" && { cat "$TMP/out41"; fail "empty --expect-fail-output, silent baseline: must not report CAUGHT"; }
[ "$(cat "$F29")" = "$before29" ] || fail "empty --expect-fail-output, silent baseline: file not byte-identical"
echo "test empty --expect-fail-output with a silent baseline -> exit 2 PASS"

# ---------------------------------------------------------------------------
# Tests 43-52 (foundry#259): the control mutant. The control breaks a
# different behavior on a fresh copy; only a control that goes RED without the
# expected text lets the main verdict stand.
# ---------------------------------------------------------------------------
HZ="--- FAIL: guard[on].x disabled"
control_run() {
  # $1 = output file; remaining args passed to mutation-verify.sh
  _out="$1"; shift
  bash "$MV" --file "$F29" --test-cmd "$TMP/cause_test.sh" "$@" >"$_out" 2>&1
}

# 43: inert control (the test stays green under it) -> exit 2.
control_run "$TMP/out43" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "$HZ" \
  --control-cmd "printf 'extra=1\\n' >> '$F29'" --control-expect-fail-output "INCIDENTAL: banner text changed"
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out43"; fail "inert control: expected exit 2, got $rc"; }
grep -q "CONTROL INERT" "$TMP/out43" || { cat "$TMP/out43"; fail "inert control: expected the inert-control message"; }
grep -q "mutation CAUGHT" "$TMP/out43" && { cat "$TMP/out43"; fail "inert control: must not report CAUGHT"; }
[ "$(cat "$F29")" = "$before29" ] || fail "inert control: file not byte-identical after restore"
echo "test inert control -> exit 2 PASS"

# 44: the control's RED output also carries the expected text -> exit 2, naming it.
cat > "$TMP/cause_generic_test.sh" <<EOF
#!/usr/bin/env bash
grep -q '^banner=hello\$' "$F29" || { echo "--- FAIL: check[x]. banner"; exit 1; }
grep -q '^guard=on\$' "$F29" || { echo "--- FAIL: check[x]. guard"; exit 1; }
exit 0
EOF
chmod +x "$TMP/cause_generic_test.sh"
bash "$MV" --file "$F29" --test-cmd "$TMP/cause_generic_test.sh" --mutate-sed 's/^guard=on$/guard=off/' \
  --expect-fail-output "--- FAIL: check[x]." --control-sed 's/^banner=hello$/banner=bye/' \
  --control-expect-fail-output "--- FAIL: check[x]. banner" >"$TMP/out44" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out44"; fail "non-specific text: expected exit 2, got $rc"; }
grep -F -q "EXPECTED TEXT NOT SPECIFIC TO THE HAZARD — the control mutant's RED run also printed: --- FAIL: check[x]." "$TMP/out44" || { cat "$TMP/out44"; fail "non-specific text: expected the not-specific message naming the text"; }
grep -q "mutation CAUGHT" "$TMP/out44" && { cat "$TMP/out44"; fail "non-specific text: must not report CAUGHT"; }
[ "$(cat "$F29")" = "$before29" ] || fail "non-specific text: file not byte-identical after restore"
echo "test non-specific expected text (control prints it) -> exit 2 PASS"

# 45: valid control (RED without the text), main mutant carries the text -> CAUGHT.
control_run "$TMP/out45" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "$HZ" --syntax-cmd "grep -q . '$F29'" \
  --control-sed 's/^banner=hello$/banner=bye/' --control-anchor 'banner=hello' --control-marker 'banner=bye' \
  --control-expect-fail-output "INCIDENTAL: banner text changed"
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out45"; fail "valid control, main caught: expected exit 0, got $rc"; }
grep -q "mutation CAUGHT (.*; control went RED for its own reason without the expected text)" "$TMP/out45" || { cat "$TMP/out45"; fail "valid control, main caught: CAUGHT line must record the control"; }
grep -q "UNVERIFIED CONTROL" "$TMP/out45" && { cat "$TMP/out45"; fail "valid control, main caught: a control with a --syntax-cmd is verified"; }
[ "$(grep -c "INCIDENTAL: banner text changed" "$TMP/out45")" -eq 1 ] || { cat "$TMP/out45"; fail "valid control, main caught: the control run's output must be printed back"; }
[ "$(cat "$F29")" = "$before29" ] || fail "valid control, main caught: file not byte-identical after restore"
echo "test valid control with a caught main mutant -> exit 0 PASS"

# 46: valid control, main mutant RED without the text -> exit 3 stands.
control_run "$TMP/out46" --mutate-sed 's/^banner=hello$/banner=bye/' --expect-fail-output "$HZ" \
  --control-sed 's/^banner=hello$/banner=other/' --control-expect-fail-output "INCIDENTAL: banner text changed"
rc=$?
[ "$rc" -eq 3 ] || { cat "$TMP/out46"; fail "valid control, main unrelated: expected exit 3, got $rc"; }
grep -q "RED FOR AN UNRELATED REASON (.*; control not run)" "$TMP/out46" || { cat "$TMP/out46"; fail "valid control, main unrelated: exit-3 line must say the control did not run"; }
[ "$(cat "$F29")" = "$before29" ] || fail "valid control, main unrelated: file not byte-identical after restore"
echo "test valid control with an unrelated-RED main mutant -> exit 3 PASS"

# 47: a control without --expect-fail-output is refused before anything runs.
control_run "$TMP/out47" --mutate-sed 's/^guard=on$/guard=off/' --control-sed 's/^banner=hello$/banner=bye/'
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out47"; fail "control without --expect-fail-output: expected exit 2, got $rc"; }
grep -q "requires --expect-fail-output" "$TMP/out47" || { cat "$TMP/out47"; fail "control without --expect-fail-output: expected the refusal message"; }
grep -q "running cause checks" "$TMP/out47" && { cat "$TMP/out47"; fail "control without --expect-fail-output: must refuse before running the test"; }
echo "test control without --expect-fail-output -> exit 2 PASS"

# 48: control argument errors: both forms, and anchor/marker without a control.
control_run "$TMP/out48a" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "$HZ" \
  --control-sed 's/^banner=hello$/banner=bye/' --control-cmd 'true'
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out48a"; fail "--control-sed with --control-cmd: expected exit 2, got $rc"; }
grep -q "mutually exclusive" "$TMP/out48a" || { cat "$TMP/out48a"; fail "--control-sed with --control-cmd: expected the exclusivity message"; }
control_run "$TMP/out48b" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "$HZ" --control-marker 'banner=bye'
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out48b"; fail "--control-marker without a control: expected exit 2, got $rc"; }
grep -q "require --control-sed or --control-cmd" "$TMP/out48b" || { cat "$TMP/out48b"; fail "--control-marker without a control: expected the message"; }
echo "test control argument errors -> exit 2 PASS"

# 49: control applied-verification: missing anchor, absent marker, no-op.
control_run "$TMP/out49a" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "$HZ" \
  --control-sed 's/^banner=hello$/banner=bye/' --control-anchor 'not in the file' --control-expect-fail-output "INCIDENTAL: banner text changed"
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out49a"; fail "control anchor missing: expected exit 2, got $rc"; }
grep -q "CONTROL ANCHOR NOT FOUND" "$TMP/out49a" || { cat "$TMP/out49a"; fail "control anchor missing: expected the message"; }
control_run "$TMP/out49b" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "$HZ" \
  --control-sed 's/^banner=hello$/banner=bye/' --control-marker 'banner=never' --control-expect-fail-output "INCIDENTAL: banner text changed"
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out49b"; fail "control marker absent: expected exit 2, got $rc"; }
grep -q "CONTROL MARKER ABSENT" "$TMP/out49b" || { cat "$TMP/out49b"; fail "control marker absent: expected the message"; }
control_run "$TMP/out49c" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "$HZ" \
  --control-sed 's/no such text/x/' --control-expect-fail-output "INCIDENTAL: banner text changed"
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out49c"; fail "no-op control: expected exit 2, got $rc"; }
grep -q "no-op control" "$TMP/out49c" || { cat "$TMP/out49c"; fail "no-op control: expected the message"; }
grep -q "mutation CAUGHT" "$TMP/out49c" && { cat "$TMP/out49c"; fail "no-op control: must not report CAUGHT"; }
[ "$(cat "$F29")" = "$before29" ] || fail "control applied-verification: file not byte-identical after restore"
echo "test control anchor/marker/no-op verification -> exit 2 PASS"

# 50: --syntax-cmd also checks the control's copy.
control_run "$TMP/out50" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "$HZ" \
  --syntax-cmd "! grep -q '^banner=bye\$' '$F29'" --control-sed 's/^banner=hello$/banner=bye/' --control-expect-fail-output "INCIDENTAL: banner text changed"
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out50"; fail "control syntax check: expected exit 2, got $rc"; }
grep -q "CONTROL FILE INVALID" "$TMP/out50" || { cat "$TMP/out50"; fail "control syntax check: expected the message"; }
[ "$(cat "$F29")" = "$before29" ] || fail "control syntax check: file not byte-identical after restore"
echo "test --syntax-cmd checks the control copy -> exit 2 PASS"

# 51: the control runs on a fresh copy of the ORIGINAL, not on the main mutant:
# a control that needs guard=on to apply must still find it.
control_run "$TMP/out51" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "$HZ" \
  --control-sed 's/^banner=hello$/banner=bye/' --control-marker 'guard=on' --control-expect-fail-output "INCIDENTAL: banner text changed"
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out51"; fail "control on a fresh copy: expected exit 0, got $rc"; }
echo "test control runs on a fresh copy of the original PASS"

# 52: a GREEN main mutant stays exit 1; the control does not run.
control_run "$TMP/out52" --mutate-cmd "printf 'extra=1\\n' >> '$F29'" --expect-fail-output "$HZ" \
  --control-sed 's/^banner=hello$/banner=bye/' --control-expect-fail-output "INCIDENTAL: banner text changed"
rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out52"; fail "green main with control: expected exit 1, got $rc"; }
grep -q "INCIDENTAL: banner text changed" "$TMP/out52" && { cat "$TMP/out52"; fail "green main with control: the control must not run"; }
[ "$(cat "$F29")" = "$before29" ] || fail "green main with control: file not byte-identical after restore"
echo "test green main mutant skips the control -> exit 1 PASS"

# 53/54: an unrelated-RED main mutant stays exit 3 whatever the control is:
# the control never runs, so an inert or text-printing control cannot turn a
# survivor into a harness error.
control_run "$TMP/out53" --mutate-sed 's/^banner=hello$/banner=bye/' --expect-fail-output "$HZ" \
  --control-cmd "printf 'extra=1\\n' >> '$F29'" --control-expect-fail-output "INCIDENTAL: banner text changed"
rc=$?
[ "$rc" -eq 3 ] || { cat "$TMP/out53"; fail "unrelated main + inert control: expected exit 3, got $rc"; }
grep -q "CONTROL INERT" "$TMP/out53" && { cat "$TMP/out53"; fail "unrelated main + inert control: the control must not run"; }
control_run "$TMP/out54" --mutate-sed 's/^banner=hello$/banner=bye/' --expect-fail-output "$HZ" \
  --control-sed 's/^guard=on$/guard=off/' --control-expect-fail-output "INCIDENTAL: banner text changed"
rc=$?
[ "$rc" -eq 3 ] || { cat "$TMP/out54"; fail "unrelated main + text-printing control: expected exit 3, got $rc"; }
grep -q "NOT SPECIFIC" "$TMP/out54" && { cat "$TMP/out54"; fail "unrelated main + text-printing control: the control must not run"; }
[ "$(cat "$F29")" = "$before29" ] || fail "unrelated main + control: file not byte-identical after restore"
echo "test an unrelated-RED main mutant stays exit 3 with any control PASS"

# 55: a control without --control-expect-fail-output is refused before anything runs.
control_run "$TMP/out55" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "$HZ" \
  --control-sed 's/^banner=hello$/banner=bye/'
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out55"; fail "control without --control-expect-fail-output: expected exit 2, got $rc"; }
grep -q "requires --control-expect-fail-output" "$TMP/out55" || { cat "$TMP/out55"; fail "control without --control-expect-fail-output: expected the message"; }
grep -q "running cause checks" "$TMP/out55" && { cat "$TMP/out55"; fail "control without --control-expect-fail-output: must refuse before running the test"; }
echo "test control without --control-expect-fail-output -> exit 2 PASS"

# 56: a control RED without its own text (a crash, a build break) is not a control.
control_run "$TMP/out56" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "$HZ" \
  --control-sed 's/^banner=hello$/banner=bye/' --control-expect-fail-output "the control's own failure line"
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out56"; fail "control red for an unrelated reason: expected exit 2, got $rc"; }
grep -q "CONTROL RED FOR AN UNRELATED REASON" "$TMP/out56" || { cat "$TMP/out56"; fail "control red for an unrelated reason: expected the message"; }
grep -q "mutation CAUGHT" "$TMP/out56" && { cat "$TMP/out56"; fail "control red for an unrelated reason: must not report CAUGHT"; }
[ "$(cat "$F29")" = "$before29" ] || fail "control red for an unrelated reason: file not byte-identical after restore"
echo "test control RED without its own text -> exit 2 PASS"

# 57: the control's text already in the main run cannot separate the failures.
control_run "$TMP/out57" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "$HZ" \
  --control-sed 's/^banner=hello$/banner=bye/' --control-expect-fail-output "--- FAIL: guard"
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out57"; fail "control text in the main run: expected exit 2, got $rc"; }
grep -q "CONTROL TEXT IN THE MAIN RUN" "$TMP/out57" || { cat "$TMP/out57"; fail "control text in the main run: expected the message"; }
grep -q "INCIDENTAL: banner text changed" "$TMP/out57" && { cat "$TMP/out57"; fail "control text in the main run: must refuse before the control runs"; }
echo "test control text already in the main run -> exit 2 PASS"

# 58: a control with neither --control-marker nor --syntax-cmd is flagged unverified.
control_run "$TMP/out58" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "$HZ" \
  --control-sed 's/^banner=hello$/banner=bye/' --control-expect-fail-output "INCIDENTAL: banner text changed"
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out58"; fail "unverified control: expected exit 0, got $rc"; }
grep -q "\[UNVERIFIED CONTROL\] control went RED for its own reason" "$TMP/out58" || { cat "$TMP/out58"; fail "unverified control: verdict must flag it"; }
echo "test a control without marker or syntax check is flagged unverified PASS"

# 59: duplicate control flags and a baseline-printed control text are refused.
control_run "$TMP/out59a" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "$HZ" \
  --control-sed 's/^banner=hello$/banner=bye/' --control-sed 's/^banner=hello$/banner=x/' --control-expect-fail-output "INCIDENTAL: banner text changed"
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out59a"; fail "duplicate --control-sed: expected exit 2, got $rc"; }
grep -q "given twice" "$TMP/out59a" || { cat "$TMP/out59a"; fail "duplicate --control-sed: expected the message"; }
control_run "$TMP/out59b" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "$HZ" \
  --control-sed 's/^banner=hello$/banner=bye/' --control-expect-fail-output "running cause checks"
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out59b"; fail "baseline-printed control text: expected exit 2, got $rc"; }
grep -q "already appears in the passing baseline output" "$TMP/out59b" || { cat "$TMP/out59b"; fail "baseline-printed control text: expected the baseline message"; }
echo "test duplicate control flags and baseline-printed control text -> exit 2 PASS"

# 60: with two expected texts, a control that prints only the SECOND is still
# refused: any expected text in the control's output is a refusal.
cat > "$TMP/cause_two_ctl_test.sh" <<EOF
#!/usr/bin/env bash
grep -q '^banner=hello\$' "$F29" || { echo "INCIDENTAL: banner text changed"; echo "--- FAIL: guard (shared helper line)"; exit 1; }
grep -q '^guard=on\$' "$F29" || { echo "$HZ"; exit 1; }
exit 0
EOF
chmod +x "$TMP/cause_two_ctl_test.sh"
bash "$MV" --file "$F29" --test-cmd "$TMP/cause_two_ctl_test.sh" --mutate-sed 's/^guard=on$/guard=off/' \
  --expect-fail-output "$HZ" --expect-fail-output "--- FAIL: guard" \
  --control-sed 's/^banner=hello$/banner=bye/' --control-expect-fail-output "INCIDENTAL: banner text changed" >"$TMP/out60" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out60"; fail "control prints the second expected text: expected exit 2, got $rc"; }
grep -F -q "the control mutant's RED run also printed: --- FAIL: guard" "$TMP/out60" || { cat "$TMP/out60"; fail "control prints the second expected text: expected the not-specific message naming it"; }
[ "$(cat "$F29")" = "$before29" ] || fail "control prints the second expected text: file not byte-identical after restore"
echo "test any expected text in the control output is a refusal PASS"

# 61: a --control-cmd that fails is not a control.
control_run "$TMP/out61" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "$HZ" \
  --control-cmd "printf 'x=1\n' >> '$F29'; false" --control-expect-fail-output "INCIDENTAL: banner text changed"
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out61"; fail "failing --control-cmd: expected exit 2, got $rc"; }
grep -q "control mutation command failed" "$TMP/out61" || { cat "$TMP/out61"; fail "failing --control-cmd: expected the message"; }
[ "$(cat "$F29")" = "$before29" ] || fail "failing --control-cmd: file not byte-identical after restore"
echo "test failing --control-cmd -> exit 2 PASS"

# 62: a --control-cmd edits a fresh copy of the ORIGINAL (the main mutant was
# restored first): its marker needs guard=on, which only the original has.
control_run "$TMP/out62" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "$HZ" \
  --control-cmd "sed 's/^banner=hello\$/banner=bye/' '$F29' > '$TMP/ctl62' && cat '$TMP/ctl62' > '$F29'" \
  --control-marker 'guard=on' --control-expect-fail-output "INCIDENTAL: banner text changed"
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out62"; fail "--control-cmd on a fresh copy: expected exit 0, got $rc"; }
[ "$(cat "$F29")" = "$before29" ] || fail "--control-cmd on a fresh copy: file not byte-identical after restore"
echo "test --control-cmd runs on a fresh copy of the original PASS"

# 63: a failed restore after the control run exits 2, never CAUGHT.
control_run "$TMP/out63" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "$HZ" \
  --control-cmd "printf 'guard=on\nbanner=bye\n' > '$F29' && chmod 444 '$F29'" \
  --control-expect-fail-output "INCIDENTAL: banner text changed"
rc=$?
chmod 644 "$F29" 2>/dev/null || true
snap63="$(grep -oE '/[^ ]*mutation-verify\.[A-Za-z0-9]+' "$TMP/out63" | head -1)"
if [ -n "$snap63" ] && [ -f "$snap63/snapshot" ]; then cp "$snap63/snapshot" "$F29"; rm -rf "$snap63"; fi
[ "$rc" -eq 2 ] || { cat "$TMP/out63"; fail "failed control restore: expected exit 2, got $rc"; }
grep -qi "restore failed" "$TMP/out63" || { cat "$TMP/out63"; fail "failed control restore: expected a RESTORE FAILED message"; }
grep -q "mutation CAUGHT" "$TMP/out63" && { cat "$TMP/out63"; fail "failed control restore: must not report CAUGHT"; }
[ "$(cat "$F29")" = "$before29" ] || fail "failed control restore: could not put the original back"
echo "test failed restore after the control -> exit 2 PASS"

# 64: deferred round-6 rows. Control-text validation mirrors tests 35/36.
for bad in "" "   " "$(printf 'INCIDENTAL: banner text changed\nTraceback')" "$(printf 'a\rb')"; do
  control_run "$TMP/out64" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "$HZ" \
    --control-sed 's/^banner=hello$/banner=bye/' --control-expect-fail-output "$bad"
  rc=$?
  [ "$rc" -eq 2 ] || { cat "$TMP/out64"; fail "degenerate --control-expect-fail-output: expected exit 2, got $rc"; }
  grep -q "must not be empty\|must be a single line" "$TMP/out64" || { cat "$TMP/out64"; fail "degenerate --control-expect-fail-output: expected a validation message"; }
  grep -q "mutation CAUGHT" "$TMP/out64" && { cat "$TMP/out64"; fail "degenerate --control-expect-fail-output: must not report CAUGHT"; }
done
echo "test empty/whitespace/multi-line --control-expect-fail-output -> exit 2 PASS"

# 65: two control texts: the control's red run must print EVERY one (absent
# text listed first, then second), and NONE may appear in the main run.
for order in first second; do
  if [ "$order" = first ]; then
    set -- --control-expect-fail-output "never printed by the control" --control-expect-fail-output "INCIDENTAL: banner text changed"
  else
    set -- --control-expect-fail-output "INCIDENTAL: banner text changed" --control-expect-fail-output "never printed by the control"
  fi
  control_run "$TMP/out65" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "$HZ" \
    --control-sed 's/^banner=hello$/banner=bye/' "$@"
  rc=$?
  [ "$rc" -eq 2 ] || { cat "$TMP/out65"; fail "two control texts, absent $order: expected exit 2, got $rc"; }
  grep -q "CONTROL RED FOR AN UNRELATED REASON .*never printed by the control" "$TMP/out65" || { cat "$TMP/out65"; fail "two control texts, absent $order: expected the message naming the absent text"; }
done
set --
control_run "$TMP/out65c" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "$HZ" \
  --control-sed 's/^banner=hello$/banner=bye/' --control-expect-fail-output "INCIDENTAL: banner text changed" \
  --control-expect-fail-output "--- FAIL: guard"
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out65c"; fail "second control text in the main run: expected exit 2, got $rc"; }
grep -F -q "CONTROL TEXT IN THE MAIN RUN — the main mutated run already printed the control's failure text, so the two failures cannot be told apart: --- FAIL: guard" "$TMP/out65c" || { cat "$TMP/out65c"; fail "second control text in the main run: expected the message naming it"; }
[ "$(cat "$F29")" = "$before29" ] || fail "two control texts: file not byte-identical after restore"
echo "test several control texts (all required, none in the main run) PASS"

# 66: a control is verified only by --syntax-cmd: a marker alone stays flagged,
# a syntax check alone clears the flag; and duplicate --control-cmd is refused.
control_run "$TMP/out66a" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "$HZ" \
  --control-sed 's/^banner=hello$/banner=bye/' --control-marker 'banner=bye' --control-expect-fail-output "INCIDENTAL: banner text changed"
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out66a"; fail "marker-only control: expected exit 0, got $rc"; }
grep -q "\[UNVERIFIED CONTROL\]" "$TMP/out66a" || { cat "$TMP/out66a"; fail "marker-only control: a marker proves the edit landed, not that the file is valid; must stay flagged"; }
control_run "$TMP/out66b" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "$HZ" --syntax-cmd "grep -q . '$F29'" \
  --control-sed 's/^banner=hello$/banner=bye/' --control-expect-fail-output "INCIDENTAL: banner text changed"
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out66b"; fail "syntax-only control: expected exit 0, got $rc"; }
grep -q "UNVERIFIED CONTROL" "$TMP/out66b" && { cat "$TMP/out66b"; fail "syntax-only control: a --syntax-cmd verifies the control"; }
control_run "$TMP/out66c" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "$HZ" \
  --control-cmd "true" --control-cmd "true" --control-expect-fail-output "INCIDENTAL: banner text changed"
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out66c"; fail "duplicate --control-cmd: expected exit 2, got $rc"; }
grep -q "given twice" "$TMP/out66c" || { cat "$TMP/out66c"; fail "duplicate --control-cmd: expected the message"; }
control_run "$TMP/out66d" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "$HZ" \
  --control-sed 's/^banner=hello$/banner=bye/' --control-expect-fail-output "running cause checks"
grep -F -q -- "--control-expect-fail-output text already appears in the passing baseline output" "$TMP/out66d" || { cat "$TMP/out66d"; fail "baseline-printed control text: the refusal must name --control-expect-fail-output"; }
echo "test control verification by --syntax-cmd and duplicate --control-cmd PASS"

# ---------------------------------------------------------------------------
# Tests 67-74 (foundry#259): the knock-out. A suite whose two tests share one
# helper message; --knockout-cmd re-runs the same mutant with only the hazard
# test deselected, and the expected text must disappear.
# ---------------------------------------------------------------------------
F67="$TMP/ko_target.txt"
printf 'guard=on\nbanner=hello\n' > "$F67"
before67="$(cat "$F67")"
cat > "$TMP/ko_suite.sh" <<EOF
#!/usr/bin/env bash
deselect=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --deselect) deselect="\${2#t.py::}"; shift 2 ;;
    *) echo "unknown flag \$1"; exit 2 ;;
  esac
done
# ids: hazard, sibling; hazard_echo (= hazard, and prints the helper text);
# none (deselects nothing, prints no count); anything else is an error.
case "\$deselect" in
  ""|hazard|sibling|none) : ;;
  hazard_echo) echo "AssertionError: value mismatch"; deselect=hazard ;;
  *) echo "error: no test with id \$deselect"; exit 4 ;;
esac
check() { [ "\$1" = "\$2" ] || { echo "AssertionError: value mismatch"; return 1; }; }
rc=0
if [ "\$deselect" != hazard ]; then
  check "\$(sed -n 's/^guard=//p' "$F67")" on || { echo "--- FAIL: hazard"; rc=1; }
fi
if [ "\$deselect" != sibling ]; then
  check "\$(sed -n 's/^banner=//p' "$F67")" hello || { echo "--- FAIL: sibling"; rc=1; }
fi
case "\$deselect" in hazard|sibling) echo "1 deselected" ;; esac
exit \$rc
EOF
chmod +x "$TMP/ko_suite.sh"
KO="$TMP/ko_suite.sh --deselect t.py::hazard"
ko_run() {
  _out="$1"; shift
  bash "$MV" --file "$F67" --test-cmd "$TMP/ko_suite.sh" "$@" >"$_out" 2>&1
}

# 67: the text disappears without the hazard test -> CAUGHT, attributed.
ko_run "$TMP/out67" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "AssertionError: value mismatch" --knockout-cmd "$KO" --knockout-expect-output "1 deselected"
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out67"; fail "knock-out removes the text: expected exit 0, got $rc"; }
grep -F -q "; knock-out \`$KO\` (exited 0 on the mutant, deselection shown by '1 deselected') removed the expected text, so it is attributed to the test(s) that command deselects" "$TMP/out67" || { cat "$TMP/out67"; fail "knock-out removes the text: CAUGHT line must record the knock-out command, its exit code and the count line"; }
[ "$(grep -c "^1 deselected$" "$TMP/out67")" -eq 2 ] || { cat "$TMP/out67"; fail "knock-out removes the text: the baseline and mutated knock-out runs must both run and print"; }
[ "$(cat "$F67")" = "$before67" ] || fail "knock-out removes the text: file not byte-identical after restore"
echo "test knock-out removes the text -> CAUGHT PASS"

# 68: the reviewer's shared-helper case: the hazard test PASSES, a sibling
# fails through the same helper message -> the text persists -> exit 2.
ko_run "$TMP/out68" --mutate-sed 's/^banner=hello$/banner=bye/' --expect-fail-output "AssertionError: value mismatch" --knockout-cmd "$KO" --knockout-expect-output "1 deselected"
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out68"; fail "text persists under the knock-out: expected exit 2, got $rc"; }
grep -F -q "TEXT PERSISTS WITHOUT THE HAZARD TEST — the knock-out run on the same mutant also printed: AssertionError: value mismatch" "$TMP/out68" || { cat "$TMP/out68"; fail "text persists under the knock-out: expected the message naming the text"; }
grep -q "mutation CAUGHT" "$TMP/out68" && { cat "$TMP/out68"; fail "text persists under the knock-out: must not report CAUGHT"; }
[ "$(cat "$F67")" = "$before67" ] || fail "text persists under the knock-out: file not byte-identical after restore"
echo "test text persisting without the hazard test -> exit 2 PASS"

# 69: a broken knock-out (red on the unmutated copy) is refused before mutating.
ko_run "$TMP/out69" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "AssertionError: value mismatch" --knockout-cmd "$TMP/ko_suite.sh --deselect t.py::bogus" --knockout-expect-output "1 deselected"
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out69"; fail "broken knock-out: expected exit 2, got $rc"; }
grep -q "KNOCK-OUT BROKEN" "$TMP/out69" || { cat "$TMP/out69"; fail "broken knock-out: expected the message"; }
grep -q -- "--- FAIL: hazard" "$TMP/out69" && { cat "$TMP/out69"; fail "broken knock-out: must refuse before mutating"; }
echo "test broken knock-out (red baseline) -> exit 2 PASS"

# 70: a knock-out whose passing baseline already prints the text is refused.
ko_run "$TMP/out70" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "AssertionError: value mismatch" \
  --knockout-cmd "$TMP/ko_suite.sh --deselect t.py::hazard_echo" --knockout-expect-output "1 deselected"
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out70"; fail "knock-out baseline prints the text: expected exit 2, got $rc"; }
grep -q "already appears in the passing knock-out baseline output" "$TMP/out70" || { cat "$TMP/out70"; fail "knock-out baseline prints the text: expected the message"; }
echo "test knock-out baseline printing the text -> exit 2 PASS"

# 71: a knock-out identical to --test-cmd is refused.
ko_run "$TMP/out71" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "AssertionError: value mismatch" --knockout-cmd "$TMP/ko_suite.sh"
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out71"; fail "knock-out identical to test-cmd: expected exit 2, got $rc"; }
grep -q "identical to --test-cmd" "$TMP/out71" || { cat "$TMP/out71"; fail "knock-out identical to test-cmd: expected the message"; }
echo "test knock-out identical to --test-cmd -> exit 2 PASS"

# 72: a knock-out without --expect-fail-output is refused before anything runs;
# and a repeated --knockout-cmd is refused.
ko_run "$TMP/out72" --mutate-sed 's/^guard=on$/guard=off/' --knockout-cmd "$KO"
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out72"; fail "knock-out without --expect-fail-output: expected exit 2, got $rc"; }
grep -q "requires --expect-fail-output" "$TMP/out72" || { cat "$TMP/out72"; fail "knock-out without --expect-fail-output: expected the message"; }
grep -q "^1 deselected$" "$TMP/out72" && { cat "$TMP/out72"; fail "knock-out without --expect-fail-output: must refuse before running"; }
ko_run "$TMP/out72b" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "AssertionError: value mismatch" --knockout-cmd "$KO" --knockout-cmd "$KO"
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out72b"; fail "duplicate --knockout-cmd: expected exit 2, got $rc"; }
grep -q "given twice" "$TMP/out72b" || { cat "$TMP/out72b"; fail "duplicate --knockout-cmd: expected the message"; }
echo "test knock-out argument errors -> exit 2 PASS"

# 73: ordering: a RED main run without the expected text stays exit 3; the
# knock-out does not run on the mutant.
ko_run "$TMP/out73" --mutate-sed 's/^banner=hello$/banner=bye/' --expect-fail-output "--- FAIL: hazard" --knockout-cmd "$KO" --knockout-expect-output "1 deselected"
rc=$?
[ "$rc" -eq 3 ] || { cat "$TMP/out73"; fail "knock-out ordering: expected exit 3, got $rc"; }
grep -q "RED FOR AN UNRELATED REASON (.*; knock-out not run)" "$TMP/out73" || { cat "$TMP/out73"; fail "knock-out ordering: exit-3 line must say the knock-out did not run"; }
[ "$(grep -c "^1 deselected$" "$TMP/out73")" -eq 1 ] || { cat "$TMP/out73"; fail "knock-out ordering: the knock-out must run only on the baseline"; }
echo "test a RED main run without the text stays exit 3 with a knock-out PASS"

# 74: a GREEN main run stays exit 1 and the knock-out does not run on the mutant.
ko_run "$TMP/out74" --mutate-cmd "printf 'extra=1\n' >> '$F67'" --expect-fail-output "AssertionError: value mismatch" --knockout-cmd "$KO" --knockout-expect-output "1 deselected"
rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out74"; fail "green main with knock-out: expected exit 1, got $rc"; }
[ "$(grep -c "^1 deselected$" "$TMP/out74")" -eq 1 ] || { cat "$TMP/out74"; fail "green main with knock-out: the knock-out must run only on the baseline"; }
[ "$(cat "$F67")" = "$before67" ] || fail "knock-out tests: file not byte-identical after restore"
echo "test a GREEN main run skips the knock-out -> exit 1 PASS"

# 75: an empty or whitespace-only --knockout-cmd is refused at parse time.
for bad in "" "   "; do
  ko_run "$TMP/out75" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "AssertionError: value mismatch" --knockout-cmd "$bad"
  rc=$?
  [ "$rc" -eq 2 ] || { cat "$TMP/out75"; fail "empty --knockout-cmd: expected exit 2, got $rc"; }
  grep -q "must not be empty" "$TMP/out75" || { cat "$TMP/out75"; fail "empty --knockout-cmd: expected the message"; }
  grep -q "must start with --test-cmd" "$TMP/out75" && { cat "$TMP/out75"; fail "empty --knockout-cmd: must be refused at parse time, before the prefix check"; }
done
echo "test empty --knockout-cmd -> exit 2 PASS"

# 76: a knock-out that is not the test command plus a deselect is refused
# (`true` would otherwise pass every other check and print nothing).
ko_run "$TMP/out76" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "AssertionError: value mismatch" --knockout-cmd "echo knock-out"
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out76"; fail "knock-out not starting with test-cmd: expected exit 2, got $rc"; }
grep -q "must start with --test-cmd" "$TMP/out76" || { cat "$TMP/out76"; fail "knock-out not starting with test-cmd: expected the message"; }
echo "test knock-out that is not test-cmd plus a deselect -> exit 2 PASS"

# 77: a knock-out whose baseline output is byte-identical to the full
# baseline's (it deselected nothing visible) is refused before mutating.
ko_run "$TMP/out77" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "AssertionError: value mismatch" --knockout-cmd "$TMP/ko_suite.sh --deselect t.py::none" --knockout-expect-output "1 deselected"
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out77"; fail "knock-out changed nothing: expected exit 2, got $rc"; }
grep -q "KNOCK-OUT CHANGED NOTHING" "$TMP/out77" || { cat "$TMP/out77"; fail "knock-out changed nothing: expected the message"; }
grep -q -- "--- FAIL: hazard" "$TMP/out77" && { cat "$TMP/out77"; fail "knock-out changed nothing: must refuse before mutating"; }
echo "test knock-out that changes nothing -> exit 2 PASS"

# 78: --knockout-expect-output (the runner's deselection count) must appear in
# the knock-out baseline; the CAUGHT verdict quotes it; it needs a knock-out.
ko_run "$TMP/out78a" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "AssertionError: value mismatch" --knockout-cmd "$KO" \
  --knockout-expect-output "1 deselected"
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out78a"; fail "knock-out scope shown: expected exit 0, got $rc"; }
grep -F -q "deselection shown by '1 deselected') removed the expected text" "$TMP/out78a" || { cat "$TMP/out78a"; fail "knock-out scope shown: verdict must quote the scope line"; }
ko_run "$TMP/out78b" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "AssertionError: value mismatch" --knockout-cmd "$KO" \
  --knockout-expect-output "2 deselected"
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out78b"; fail "knock-out count other than 1: expected exit 2, got $rc"; }
grep -q "must declare a count of exactly 1" "$TMP/out78b" || { cat "$TMP/out78b"; fail "knock-out count other than 1: expected the message"; }
ko_run "$TMP/out78c" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "AssertionError: value mismatch" --knockout-expect-output "1 deselected"
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out78c"; fail "--knockout-expect-output without a knock-out: expected exit 2, got $rc"; }
grep -q "requires --knockout-cmd" "$TMP/out78c" || { cat "$TMP/out78c"; fail "--knockout-expect-output without a knock-out: expected the message"; }
[ "$(cat "$F67")" = "$before67" ] || fail "knock-out scope: file not byte-identical after restore"
echo "test --knockout-expect-output scope proof PASS"

# 80: the knock-out with SEVERAL expected texts: every one must disappear.
# Both lines are mutated, so the hazard and the sibling both fail; the hazard's
# own line disappears under the knock-out, the shared helper line does not.
for order in second first; do
  if [ "$order" = second ]; then
    set -- --expect-fail-output "--- FAIL: hazard" --expect-fail-output "AssertionError: value mismatch"
  else
    set -- --expect-fail-output "AssertionError: value mismatch" --expect-fail-output "--- FAIL: hazard"
  fi
  ko_run "$TMP/out80" --mutate-cmd "printf 'guard=off\nbanner=bye\n' > '$F67'" "$@" --knockout-cmd "$KO" --knockout-expect-output "1 deselected"
  rc=$?
  [ "$rc" -eq 2 ] || { cat "$TMP/out80"; fail "knock-out, several texts, shared one listed $order: expected exit 2, got $rc"; }
  grep -F -q "TEXT PERSISTS WITHOUT THE HAZARD TEST — the knock-out run on the same mutant also printed: AssertionError: value mismatch" "$TMP/out80" || { cat "$TMP/out80"; fail "knock-out, several texts, shared one listed $order: expected the message naming the shared text"; }
done
set --
[ "$(cat "$F67")" = "$before67" ] || fail "knock-out, several texts: file not byte-identical after restore"
echo "test knock-out with several expected texts (every one must disappear) PASS"

# 81: a knock-out baseline that prints the SECOND of two expected texts is refused.
ko_run "$TMP/out81" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "--- FAIL: hazard" \
  --expect-fail-output "AssertionError: value mismatch" --knockout-cmd "$TMP/ko_suite.sh --deselect t.py::hazard_echo" --knockout-expect-output "1 deselected"
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out81"; fail "knock-out baseline prints the second text: expected exit 2, got $rc"; }
grep -F -q "already appears in the passing knock-out baseline output: AssertionError: value mismatch" "$TMP/out81" || { cat "$TMP/out81"; fail "knock-out baseline prints the second text: expected the message naming it"; }
echo "test knock-out baseline printing the second expected text -> exit 2 PASS"

# 82: knock-out plus control: the CAUGHT line carries both clauses in order;
# when the text persists, the control never runs.
ko_run "$TMP/out82a" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "--- FAIL: hazard" --knockout-cmd "$KO" --knockout-expect-output "1 deselected" \
  --syntax-cmd "grep -q . '$F67'" --control-sed 's/^banner=hello$/banner=bye/' --control-expect-fail-output "--- FAIL: sibling"
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out82a"; fail "knock-out plus control: expected exit 0, got $rc"; }
grep -q "removed the expected text, so it is attributed to the test(s) that command deselects; control went RED for its own reason without the expected text)" "$TMP/out82a" || { cat "$TMP/out82a"; fail "knock-out plus control: CAUGHT line must carry the knock-out then the control clause"; }
ko_run "$TMP/out82b" --mutate-sed 's/^banner=hello$/banner=bye/' --expect-fail-output "AssertionError: value mismatch" --knockout-cmd "$KO" --knockout-expect-output "1 deselected" \
  --control-sed 's/^guard=on$/guard=off/' --control-expect-fail-output "--- FAIL: hazard"
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out82b"; fail "text persists with a control: expected exit 2, got $rc"; }
grep -q "TEXT PERSISTS WITHOUT THE HAZARD TEST" "$TMP/out82b" || { cat "$TMP/out82b"; fail "text persists with a control: expected the persists message"; }
grep -q -- "--- FAIL: hazard" "$TMP/out82b" && { cat "$TMP/out82b"; fail "text persists with a control: the control must not run"; }
[ "$(cat "$F67")" = "$before67" ] || fail "knock-out plus control: file not byte-identical after restore"
echo "test knock-out plus control ordering and verdict PASS"

# Fixture for tests 83-85: a suite with a weak hazard test and ten tests that
# share its name prefix, one of which really catches the mutant.
F83="$TMP/prefix_target.txt"
printf 'value=1\n' > "$F83"
before83="$(cat "$F83")"
cat > "$TMP/prefix_suite.sh" <<EOF
#!/usr/bin/env bash
# tests: haz (weak), haz_1 (the real catcher), haz_2..haz_10, other.
# --deselect <prefix> removes every test whose name starts with <prefix>
# (pytest's node-id prefix match / cargo's substring --skip).
shape="\$1"; shift
prefixes=""
while [ "\${1:-}" = "--deselect" ]; do prefixes="\$prefixes \${2#t.py::}"; shift 2; done
ran=0; gone=0; rc=0
for t in haz haz_1 haz_2 haz_3 haz_4 haz_5 haz_6 haz_7 haz_8 haz_9 haz_10 other; do
  skip=0
  for p in \$prefixes; do case "\$t" in "\$p"*) skip=1 ;; esac; done
  if [ "\$skip" -eq 1 ]; then gone=\$((gone+1)); continue; fi
  ran=\$((ran+1))
  if [ "\$t" = haz_1 ] && ! grep -q '^value=1\$' "$F83"; then echo "SIBLING_SAW_WRONG_VALUE"; rc=1; fi
done
if [ "\$shape" = pytest ]; then
  if [ "\$gone" -gt 0 ]; then echo "\$ran passed, \$gone deselected"; else echo "\$ran passed"; fi
else
  echo "test result: ok. \$ran passed; 0 failed; 0 ignored; 0 measured; \$gone filtered out"
fi
exit \$rc
EOF
chmod +x "$TMP/prefix_suite.sh"

# 83/84: the round-8 false CAUGHT through a substring count line. A prefix /
# substring deselect removes the hazard AND ten same-prefix tests (one of them
# the sibling that really catches the mutant); the runner reports "11". The
# declared "1" must not match "11", so the run is refused, not CAUGHT.
for shape in pytest cargo; do
  if [ "$shape" = pytest ]; then count="1 deselected"; else count="1 filtered out"; fi
  bash "$MV" --file "$F83" --test-cmd "$TMP/prefix_suite.sh $shape" --mutate-sed 's/^value=1$/value=2/' \
    --expect-fail-output "SIBLING_SAW_WRONG_VALUE" --knockout-cmd "$TMP/prefix_suite.sh $shape --deselect t.py::haz" \
    --knockout-expect-output "$count" >"$TMP/out83" 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || { cat "$TMP/out83"; fail "$shape over-broad deselect with count '$count': expected exit 2, got $rc"; }
  grep -q "KNOCK-OUT SCOPE UNPROVEN .*as a whole number" "$TMP/out83" || { cat "$TMP/out83"; fail "$shape over-broad deselect: expected the whole-number refusal"; }
  grep -q "mutation CAUGHT" "$TMP/out83" && { cat "$TMP/out83"; fail "$shape over-broad deselect: must not report CAUGHT"; }
  [ "$(cat "$F83")" = "$before83" ] || fail "$shape over-broad deselect: file not byte-identical"
done
echo "test a count line matches as a whole number (1 vs 11) PASS"

# 85: a count line the full, unmutated run already prints (a filter in
# --test-cmd) cannot show the knock-out's deselection.
bash "$MV" --file "$F83" --test-cmd "$TMP/prefix_suite.sh pytest --deselect t.py::other" --mutate-sed 's/^value=1$/value=2/' \
  --expect-fail-output "SIBLING_SAW_WRONG_VALUE" --knockout-cmd "$TMP/prefix_suite.sh pytest --deselect t.py::other --deselect t.py::haz_1" \
  --knockout-expect-output "1 deselected" >"$TMP/out85" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out85"; fail "count line in the full run: expected exit 2, got $rc"; }
grep -q "the full, unmutated run already prints the --knockout-expect-output line" "$TMP/out85" || { cat "$TMP/out85"; fail "count line in the full run: expected the message"; }
echo "test a count line the full run already prints -> exit 2 PASS"

# 86: --knockout-cmd without --knockout-expect-output is refused before running.
ko_run "$TMP/out86" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "AssertionError: value mismatch" --knockout-cmd "$KO"
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out86"; fail "knock-out without a count line: expected exit 2, got $rc"; }
grep -q "requires --knockout-expect-output" "$TMP/out86" || { cat "$TMP/out86"; fail "knock-out without a count line: expected the message"; }
grep -q -- "--- FAIL: hazard" "$TMP/out86" && { cat "$TMP/out86"; fail "knock-out without a count line: must refuse before running"; }
echo "test a knock-out without a count line -> exit 2 PASS"

# 90: count-line and delta-line validation.
for bad in "deselected" "1" "  1 deselected" "0 deselected" "0 xyzzy" "2 deselected"; do
  ko_run "$TMP/out90" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "AssertionError: value mismatch" --knockout-cmd "$KO" --knockout-expect-output "$bad"
  rc=$?
  [ "$rc" -eq 2 ] || { cat "$TMP/out90"; fail "count line '$bad': expected exit 2, got $rc"; }
  grep -q "must start with its number\|needs text after its number\|must declare a count of exactly 1" "$TMP/out90" || { cat "$TMP/out90"; fail "count line '$bad': expected a validation message"; }
done
ko_run "$TMP/out90b" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "AssertionError: value mismatch" --knockout-delta-line '=== RUN '
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out90b"; fail "--knockout-delta-line without a knock-out: expected exit 2, got $rc"; }
grep -q "requires --knockout-cmd" "$TMP/out90b" || { cat "$TMP/out90b"; fail "--knockout-delta-line without a knock-out: expected the message"; }
ko_run "$TMP/out90c" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "AssertionError: value mismatch" --knockout-cmd "$KO" \
  --knockout-delta-line '=== RUN ' --knockout-delta-line '=== RUN '
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out90c"; fail "duplicate --knockout-delta-line: expected exit 2, got $rc"; }
grep -q "given twice" "$TMP/out90c" || { cat "$TMP/out90c"; fail "duplicate --knockout-delta-line: expected the message"; }
for bad in "--- PASS" "=== RUN   TestParse" "=== RUN"; do
  ko_run "$TMP/out90d" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "AssertionError: value mismatch" --knockout-cmd "$KO" \
    --knockout-delta-line "$bad"
  rc=$?
  [ "$rc" -eq 2 ] || { cat "$TMP/out90d"; fail "delta line '$bad': expected exit 2, got $rc"; }
  grep -q "must be exactly '=== RUN '" "$TMP/out90d" || { cat "$TMP/out90d"; fail "delta line '$bad': expected the pinned-prefix message"; }
done
echo "test count-line and delta-line validation PASS"

# 91: the knock-out run on the MUTANT must still show its scope: a run that
# crashes before printing its count line cannot attribute the text.
F91="$TMP/crash_target.txt"
printf 'guard=on\n' > "$F91"
cat > "$TMP/crash_suite.sh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--deselect" ]; then
  grep -q '^guard=off\$' "$F91" && { echo "runner crashed"; exit 3; }
  echo "1 deselected"; exit 0
fi
grep -q '^guard=on\$' "$F91" || { echo "--- FAIL: hazard"; exit 1; }
exit 0
EOF
chmod +x "$TMP/crash_suite.sh"
bash "$MV" --file "$F91" --test-cmd "$TMP/crash_suite.sh" --mutate-sed 's/^guard=on$/guard=off/' \
  --expect-fail-output "--- FAIL: hazard" --knockout-cmd "$TMP/crash_suite.sh --deselect t.py::hazard" \
  --knockout-expect-output "1 deselected" >"$TMP/out91" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out91"; fail "knock-out crashed on the mutant: expected exit 2, got $rc"; }
grep -q "KNOCK-OUT SCOPE UNPROVEN ON THE MUTANT" "$TMP/out91" || { cat "$TMP/out91"; fail "knock-out crashed on the mutant: expected the message"; }
grep -q "mutation CAUGHT" "$TMP/out91" && { cat "$TMP/out91"; fail "knock-out crashed on the mutant: must not report CAUGHT"; }
echo "test a knock-out that loses its count line on the mutant -> exit 2 PASS"

# 92: the part of --knockout-cmd after --test-cmd must be exactly one documented
# deselect; extra runner flags (a cargo --lib, a pytest --ignore), an
# unanchored go -skip, a cargo --skip without --exact, or anything chained
# after it are refused before any test runs.
for suffix in " --lib -- --exact --skip tests::hazard" " -- --skip tests::hazard" " -skip TestHazard" \
              " -skip '^TestHazard'" " --ignore=t.py --deselect t.py::hazard" " --deselect t.py::hazard; echo x" \
              " --deselect hazard" " --deselect {t.py::hazard,-x}" " --deselect t.py::hazard$(printf '\t')-x"; do
  ko_run "$TMP/out92" --mutate-sed 's/^guard=on$/guard=off/' --expect-fail-output "AssertionError: value mismatch" \
    --knockout-cmd "$TMP/ko_suite.sh$suffix" --knockout-expect-output "1 deselected"
  rc=$?
  [ "$rc" -eq 2 ] || { cat "$TMP/out92"; fail "off-form knock-out suffix '$suffix': expected exit 2, got $rc"; }
  grep -q "must be --test-cmd plus exactly one documented deselect" "$TMP/out92" || { cat "$TMP/out92"; fail "off-form knock-out suffix '$suffix': expected the shape refusal"; }
  grep -q -- "--- FAIL: hazard\|^1 deselected$" "$TMP/out92" && { cat "$TMP/out92"; fail "off-form knock-out suffix '$suffix': must refuse before running"; }
done
echo "test off-form knock-out suffixes are refused PASS"

# 93: a cargo test command with its own "--" section is refused: the appended
# "-- --exact --skip <name>" would become a second "--", and libtest would read
# every word after it as a name FILTER (run only the hazard test).
for tc in "$TMP/ko_suite.sh -- --nocapture" "$TMP/ko_suite.sh -- --test-threads=1"; do
  bash "$MV" --file "$F67" --test-cmd "$tc" --mutate-sed 's/^guard=on$/guard=off/' \
    --expect-fail-output "AssertionError: value mismatch" --knockout-cmd "$tc -- --exact --skip tests::hazard" \
    --knockout-expect-output "1 filtered out" >"$TMP/out93" 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || { cat "$TMP/out93"; fail "cargo test command with its own '--' ($tc): expected exit 2, got $rc"; }
  grep -q "needs a --test-cmd without its own '--' section" "$TMP/out93" || { cat "$TMP/out93"; fail "cargo test command with its own '--': expected the message"; }
  grep -q "mutation CAUGHT" "$TMP/out93" && { cat "$TMP/out93"; fail "cargo test command with its own '--': must not report CAUGHT"; }
done
[ "$(cat "$F67")" = "$before67" ] || fail "cargo double-dash: file not byte-identical"
echo "test a cargo test command with its own '--' section is refused PASS"

# ---------------------------------------------------------------------------
# Test 94 (main's SIGPIPE test, renumbered on merge): baseline exiting 141 (SIGPIPE under pipefail, e.g. piping a noisy
# test runner into `grep -q`) exits 2 and emits an actionable SIGPIPE /
# `grep -q` diagnostic hint, leaving the target file byte-identical.
# The writer is perl resetting SIGPIPE itself: a shell cannot un-ignore a signal
# it inherited as ignored (GitHub's runner starts jobs that way), so `trap - PIPE`
# left `yes` exiting 1 on EPIPE there instead of dying of SIGPIPE (141).
# ---------------------------------------------------------------------------
F94="$TMP/sigpipe_baseline.txt"
printf 'hello world\n' > "$F94"
before94="$(cat "$F94")"
bash "$MV" --file "$F94" \
  --test-cmd "perl -e '\$SIG{PIPE}=\"DEFAULT\"; print \"y\\n\" while 1' | grep -q y" \
  --mutate-sed 's/hello/goodbye/' >"$TMP/out94" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out94"; fail "sigpipe baseline: expected exit 2, got $rc"; }
grep -q "baseline exited 141" "$TMP/out94" || { cat "$TMP/out94"; fail "sigpipe baseline: expected baseline exited 141 message"; }
grep -q "SIGPIPE" "$TMP/out94" || { cat "$TMP/out94"; fail "sigpipe baseline: expected SIGPIPE diagnostic hint"; }
grep -q "grep -q" "$TMP/out94" || { cat "$TMP/out94"; fail "sigpipe baseline: expected grep -q diagnostic hint"; }
[ "$(cat "$F94")" = "$before94" ] || fail "sigpipe baseline: file not byte-identical after abort"
echo "test baseline exit 141 emits SIGPIPE / grep -q hint -> PASS"

# Cross-dialect regression: unchanged verifier and sweep trees agree.

echo "ALL PASS"
