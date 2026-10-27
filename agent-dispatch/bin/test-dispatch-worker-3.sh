#!/usr/bin/env bash
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/test-dispatch-worker-lib.sh
. "$SELF_DIR/lib/test-dispatch-worker-lib.sh"

# The preceding roster case originally enabled errexit for these blocks.
set -e

# Recreate the populated global config, feature branch, and origin from test 44.
install_cfg_agy_stub
unset AGY_ROSTER_MODE
decoy="$TMP/decoy43"; make_git_repo "$decoy"
r44="$TMP/repo44"; make_config_fixture "$r44"
: > "$AGY_STUB_ACTIONS"

# Source-state contract: actions deliberately target only test-owned repos.
for i in $(seq 1 100); do printf 'Minor: REVIEW LINE %s src/x.go:1 ok\n' "$i"; done > "$TMP/expected-body"
export SRC="$TMP/state-source"
make_git_repo "$SRC"
git -C "$SRC" remote add origin https://example.invalid/source
cp "$SRC/.git/config" "$TMP/state-config.before"

# Snapshot bounds apply to git internals and worktree ignore reads.
# Bound the suite's own child even when the implementation bound regresses.
run_hostile_review() (
  local timer='' child guard rc=0
  timer=$(command -v timeout || command -v gtimeout) || timer=''
  if [ -n "$timer" ]; then
    export DW TMP BRIEF
    export -f run_cfg_review
    "$timer" -k 5 60 bash -c 'run_cfg_review "$1"' _ "$SRC" || rc=$?
  else
    set -m
    run_cfg_review "$SRC" &
    child=$!
    (
      set +m
      sleep 60
      kill -TERM -- "-$child" 2>/dev/null || true
      sleep 5
      kill -KILL -- "-$child" 2>/dev/null || true
    ) </dev/null >/dev/null 2>&1 &
    guard=$!
    wait "$child" || rc=$?
    kill -TERM -- "-$guard" 2>/dev/null || true
    wait "$guard" 2>/dev/null || true
  fi
  case "$rc" in
    124|137|143) fail "hostile $hostile: review hung (snapshot or pin-release unbounded)" ;;
  esac
  exit "$rc"
)

mkdir "$TMP/tagged-git"
export REAL_HOSTILE_GIT
REAL_HOSTILE_GIT=$(command -v git)
cat > "$TMP/tagged-git/git" <<'TAGGED'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$RUN_PID_FILE"
# git reads a "git-<x>" argv[0] as a dashed builtin; keep the tag elsewhere.
exec -a "tagged-$RUN_ID" "$REAL_HOSTILE_GIT" "$@"
TAGGED
chmod +x "$TMP/tagged-git/git"
for hostile in .git/objects/info/alternates .gitignore .git/FETCH_HEAD loose-object; do
  (
  fail() { echo "FAIL: $*" >&2; exit 1; }
  planted="$SRC/$hostile"
  trap 'rm -f "$planted" "$SRC/.git/review-pinned"; if [ "$hostile" = loose-object ]; then git -C "$SRC" update-ref -d refs/heads/fifo; fi' EXIT
  if [ "$hostile" = loose-object ]; then
    sha=$(git -C "$SRC" -c user.name=t -c user.email=t@e commit-tree -m fifo 'HEAD^{tree}')
    git -C "$SRC" update-ref refs/heads/fifo "$sha"
    # Put the branch in place only after the readable baseline.
    git -C "$SRC" update-ref -d refs/heads/fifo
    planted="$SRC/.git/objects/${sha:0:2}/${sha:2}"
    printf 'git -C "$SRC" update-ref refs/heads/fifo %s\nrm "%s"\nmkfifo "%s"\n' "$sha" "$planted" "$planted" > "$AGY_STUB_ACTIONS"
  else
    printf 'mkfifo "$SRC/%s"\n' "$hostile" > "$AGY_STUB_ACTIONS"
  fi
  (
    fail() { echo "FAIL: $*" >&2; exit 1; }
    trap 'rm -f "$planted"' EXIT
    snapshot_rc=0
    RUN_ID="hostile-$$-$(printf %s "$hostile" | tr -c 'A-Za-z0-9' _)"
    export RUN_ID RUN_PID_FILE="$TMP/hostile-pids"
    : > "$RUN_PID_FILE"
    PATH="$TMP/tagged-git:$PATH" DISPATCH_SNAPSHOT_TIMEOUT_SECS=5 run_hostile_review || snapshot_rc=$?
    while IFS= read -r tagged_pid; do
      if ps -p "$tagged_pid" -o command= 2>/dev/null | grep -Fq "tagged-$RUN_ID"; then
        fail "hostile $hostile left tagged git pid $tagged_pid"
      fi
    done < "$RUN_PID_FILE"
    [ "$snapshot_rc" = 10 ] || fail "hostile $hostile expected critical, got $snapshot_rc"
    ! grep -q 'baseline unreadable' "$TMP/cfg.err" || fail 'BEFORE snapshot unreadable'
    grep -q 'SOURCE REPO CHANGED' "$TMP/cfg.err" || fail 'missing source changes'
    if [ "$hostile" = .gitignore ]; then
      grep -q 'drift snapshot timed out' "$TMP/cfg.err" || fail 'snapshot timeout missing'
    else
      grep -q 'nonregular ' "$TMP/cfg.err" || fail 'nonregular file not listed'
    fi
  ) || fail "hostile $hostile failed"
  [ ! -e "$(git -C "$SRC" rev-parse --absolute-git-dir)/review-pinned" ] || fail "review pin not released hostile $hostile"
  if [ "$hostile" = loose-object ]; then git -C "$SRC" update-ref -d refs/heads/fifo; fi
  ) || fail "hostile $hostile failed"
  git -C "$SRC" status --porcelain >/dev/null || fail "hostile $hostile left unusable repo"
done
# Before-launch FIFO uses metadata that setup does not need to open.
: > "$AGY_STUB_ACTIONS"
hostile='before-FETCH_HEAD'
(
  fail() { echo "FAIL: $*" >&2; exit 1; }
  planted="$SRC/.git/FETCH_HEAD"
  trap 'rm -f "$planted"' EXIT
  mkfifo "$planted"
  snapshot_rc=0
  DISPATCH_SNAPSHOT_TIMEOUT_SECS=5 run_hostile_review || snapshot_rc=$?
  [ "$snapshot_rc" = 10 ] || fail "before FIFO expected critical, got $snapshot_rc"
) || fail "before-launch FIFO failed"
# Termination inside the after-snapshot window must leave a pessimistic EXIT status.
mkdir -p "$TMP/sentinel/bin/lib"
cp "$DW" "$TMP/sentinel/bin/dispatch-worker"
cp "$SELF_DIR/lib/"*.sh "$TMP/sentinel/bin/lib/"
cp "$SELF_DIR/review-pin.sh" "$SELF_DIR/agy-auth-probe.sh" "$TMP/sentinel/bin/"
# Inject only into the test-owned copy, before the bounded helper does any work.
sed '/^review_state_snapshot_bounded() {$/a\
  if [ "$2" = "$REVIEW_SNAPSHOT_DIR/after" ]; then kill -TERM "$$"; fi
' "$DW" > "$TMP/sentinel/bin/dispatch-worker"
actual=0
TIMEOUT=0 "$TMP/sentinel/bin/dispatch-worker" --runtime agy --review --brief "$BRIEF" --workdir "$SRC" > "$TMP/sentinel.out" 2> "$TMP/sentinel.err" || actual=$?
[ "$actual" = 143 ] || fail "sentinel TERM expected 143, got $actual"
grep -q 'DISPATCH_REVIEW_STATE=critical(incomplete)' "$TMP/sentinel.err" || fail 'after window status not critical'
DISPATCH_SNAPSHOT_TIMEOUT_SECS=00 run_cfg_review "$SRC" || fail '00 default review failed'
grep -q 'invalid DISPATCH_SNAPSHOT_TIMEOUT_SECS; using 120' "$TMP/cfg.err" || fail '00 accepted unbounded'
: > "$AGY_STUB_ACTIONS"

check_state_run() {
  local expected="$1" actual=0
  run_cfg_review "${2:-$SRC}" || actual=$?
  [ "$actual" -eq "$expected" ] || fail "state expected rc $expected, got $actual: $(cat "$TMP/cfg.err")"
}
for key in user.name core.hooksPath; do
  value=x
  [ "$key" != core.hooksPath ] || value="$(cd "$SRC/.git/hooks" && pwd -P)"
  # shellcheck disable=SC2016 # Expanded by the generated action script.
  printf 'git -C "$SRC" config %s "%s"\n' "$key" "$value" > "$AGY_STUB_ACTIONS"
  check_state_run 10
  grep -qi "config $key" "$TMP/cfg.err" || fail "missing $key change"
  grep -qF 'DISPATCH_REVIEW_STATE=critical(1) original_rc=0' "$TMP/cfg.err" || fail 'critical state count/rc'
  cmp -s "$TMP/expected-body" "$TMP/cfg.out" || fail 'state check changed stdout'
  cp "$TMP/state-config.before" "$SRC/.git/config"
done
# shellcheck disable=SC2016 # Expanded by the generated action script.
printf 'git -C "$SRC" config branch.review-main.remote origin\n' > "$AGY_STUB_ACTIONS"
check_state_run 0
grep -qF 'DISPATCH_REVIEW_STATE=warn(1)' "$TMP/cfg.err" || fail 'benign config not warn'
cp "$TMP/state-config.before" "$SRC/.git/config"
# shellcheck disable=SC2016 # Expanded by the generated action script.
printf 'echo hook > "$SRC/.git/hooks/pre-commit"\n' > "$AGY_STUB_ACTIONS"
check_state_run 10
rm "$SRC/.git/hooks/pre-commit"
# shellcheck disable=SC2016 # Expanded by the generated action script.
printf 'git -C "$SRC" -c user.name=t -c user.email=t@x.invalid commit --quiet --allow-empty -m x\n' > "$AGY_STUB_ACTIONS"
check_state_run 10
grep -q 'commit ' "$TMP/cfg.err" || fail 'foreign commit not named'
# shellcheck disable=SC2016 # Expanded by the generated action script.
printf 'printf "[core\\n bad" >> "$SRC/.git/config"\n' > "$AGY_STUB_ACTIONS"
check_state_run 10
grep -qF '<unreadable after review>' "$TMP/cfg.err" || fail 'unreadable after missing'
cp "$TMP/state-config.before" "$SRC/.git/config"
export AGY_STUB_RC=124
for call in 2 1; do
  # shellcheck disable=SC2016 # Expanded by the generated action script.
  printf '[ "$1" != %s ] || git -C "$SRC" config user.name x\n' "$call" > "$AGY_STUB_ACTIONS"
  check_state_run 10
  [ "$(cat "$AGY_STUB_COUNT_FILE")" = "$call" ] || fail 'drift retry count'
  if [ "$call" = 2 ]; then
    grep -qF 'original_rc=124' "$TMP/cfg.err" || fail 'retry original rc'
  else
    grep -qF 'original_rc=124' "$TMP/cfg.err" || fail 'skip original rc'
    grep -qF 'skipping the timeout retry' "$TMP/cfg.err" || fail 'skip message absent'
    ! grep -qF 'timed out again' "$TMP/cfg.err" || fail 'skip printed retry failure'
  fi
  cp "$TMP/state-config.before" "$SRC/.git/config"
done
# shellcheck disable=SC2016 # Expanded by the generated action script.
printf '[ "$1" != 1 ] || printf "[core\\n bad" >> "$SRC/.git/config"\n' > "$AGY_STUB_ACTIONS"
check_state_run 10
[ "$(cat "$AGY_STUB_COUNT_FILE")" = 1 ] || fail 'unreadable interim retried'
cp "$TMP/state-config.before" "$SRC/.git/config"
unset AGY_STUB_RC
cp "$decoy/.git/config" "$TMP/decoy.before"
printf 'git config user.name x\n' > "$AGY_STUB_ACTIONS"
GIT_DIR="$decoy/.git" GIT_INDEX_FILE="$decoy/.git/index" check_state_run 0
grep -qF 'DISPATCH_REVIEW_STATE=clean' "$TMP/cfg.err" || fail 'V10 not clean'
cmp -s "$decoy/.git/config" "$TMP/decoy.before" || fail 'decoy config changed'
# shellcheck disable=SC2016 # Expanded by the generated action script.
printf 'git -C "$SRC" config user.name x\n' > "$AGY_STUB_ACTIONS"
GIT_DIR="$decoy/.git" GIT_INDEX_FILE="$decoy/.git/index" check_state_run 10
cp "$TMP/state-config.before" "$SRC/.git/config"
git -C "$SRC" worktree add --quiet --detach "$TMP/state-linked" HEAD
check_state_run 10 "$TMP/state-linked"
cp "$TMP/state-config.before" "$SRC/.git/config"
# shellcheck disable=SC2016 # Expanded by the generated action script.
printf 'git -C "$SRC" branch concurrent\n' > "$AGY_STUB_ACTIONS"
check_state_run 0
grep -qF 'DISPATCH_REVIEW_STATE=warn(' "$TMP/cfg.err" || fail 'concurrent branch not warn'
: > "$AGY_STUB_ACTIONS"
AGY_MISSING_REVIEW=1 check_state_run 9
grep -qF 'DISPATCH_REVIEW_STATE=skipped(not-launched) original_rc=9' "$TMP/cfg.err" || fail 'prelaunch state missing'
echo 'test 45 (source state and critical precedence) PASS'

# Task 9: every review runtime checks the source, including fallback paths.
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
repo=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = -C ]; then repo="$2"; shift; fi
  shift
done
cat >/dev/null
if [ "${CODEX_STATE_DRIFT:-0}" = 1 ]; then
  [ -n "$repo" ] || exit 98
  git -C "$repo" config user.email x@x.invalid || exit 99
fi
exit "${CODEX_STATE_RC:-0}"
STUB
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
git -C "$SRC" config user.name changed || exit 99
STUB
run_state_runtime() {
  local runtime="$1" expected="$2" actual=0
  TIMEOUT=0 "$DW" --runtime "$runtime" --review --brief "$BRIEF" --workdir "$SRC" > "$TMP/cfg.out" 2> "$TMP/cfg.err" || actual=$?
  [ "$actual" -eq "$expected" ] || fail "$runtime state expected $expected, got $actual"
}
CODEX_STATE_DRIFT=1 CODEX_STATE_RC=124 run_state_runtime codex 10
grep -qF 'DISPATCH_REVIEW_STATE=critical(1) original_rc=124' "$TMP/cfg.err" || fail 'codex drift/timeout state absent'
cp "$TMP/state-config.before" "$SRC/.git/config"
(cd "$SRC" && run_state_runtime claude 10)
grep -qF 'DISPATCH_REVIEW_STATE=critical(1) original_rc=0' "$TMP/cfg.err" || fail 'claude drift state absent'
cp "$TMP/state-config.before" "$SRC/.git/config"
CODEX_STATE_RC=10 run_state_runtime codex 1
grep -qF 'DISPATCH_REVIEW_STATE=clean original_rc=10' "$TMP/cfg.err" || fail 'native 10 state absent'
grep -qF 'dispatch-worker: runtime exited 10 natively; reported as 1 (10 is reserved for source-repo drift).' "$TMP/cfg.err" || fail 'native 10 note absent'
git -C "$SRC" config filter.x.clean cat
# shellcheck disable=SC2016 # Expanded by the generated action script.
printf 'git -C "$SRC" config user.name changed\n' > "$AGY_STUB_ACTIONS"
actual=0
(cd "$TMP" && run_cfg_review "$SRC") || actual=$?
[ "$actual" -eq 10 ] || fail "V9 fallback expected 10, got $actual"
grep -qF 'unsuitable for a private clone' "$TMP/cfg.err" || fail 'V9 fallback reason absent'
grep -qF 'DISPATCH_REVIEW_STATE=critical(1)' "$TMP/cfg.err" || fail 'V9 fallback source drift absent'
cp "$TMP/state-config.before" "$SRC/.git/config"
: > "$AGY_STUB_ACTIONS"
mkdir "$TMP/non-git"
for runtime in codex agy; do
  actual=0
  TIMEOUT=0 "$DW" --runtime "$runtime" --review --brief "$BRIEF" --workdir "$TMP/non-git" > "$TMP/cfg.out" 2> "$TMP/cfg.err" || actual=$?
  [ "$actual" -eq 0 ] || fail "$runtime non-git review failed: $actual"
  grep -qF 'DISPATCH_REVIEW_STATE=skipped(not-a-git-repo)' "$TMP/cfg.err" || fail "$runtime non-git state absent"
done
"$DW" --help > "$TMP/help"
grep -qF "10  --review: the source repo's config" "$TMP/help" || fail 'help missing exit 10'
grep -qF 'DISPATCH_REVIEW_STATE=' "$TMP/help" || fail 'help missing state line'
echo 'test 46 (codex, claude, native 10, fallback and help) PASS'

# Claude ignores --workdir: watch the repository where it actually runs.
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
git -C "$PWD" config user.name changed || exit 99
STUB
claude_cwd_repo="$TMP/claude-cwd-repo"
make_git_repo "$claude_cwd_repo"
(cd "$claude_cwd_repo" && run_state_runtime claude 10)
grep -qF 'DISPATCH_REVIEW_STATE=critical(1)' "$TMP/cfg.err" || fail 'claude caller repository drift absent'
: > "$AGY_STUB_ACTIONS"
GIT_CONFIG_GLOBAL="$TMP/absent-global.gitconfig" run_cfg_review "$r44" > "$TMP/no-global.out" 2> "$TMP/no-global.err"
[ "$?" -eq 0 ] || fail 'review without global gitconfig failed'
grep -q 'fatal:' "$TMP/cfg.err" && fail 'missing global gitconfig emitted fatal diagnostic'

# No reviewer environment entry may identify the snapshot directory.
cat > "$AGY_STUB_ACTIONS" <<'ACTIONS'
env > "$AGY_ARGS_FILE.snapshot-env"
if [ -e "$(dirname "$GIT_CONFIG_GLOBAL")/before" ]; then
  printf shared > "$AGY_ARGS_FILE.shared-snapshot"
fi
ACTIONS
check_state_run 0
if grep -q 'dispatch-snapshots\.' "$AGY_ARGS_FILE.snapshot-env"; then fail 'snapshot directory exported'; fi
[ ! -e "$AGY_ARGS_FILE.shared-snapshot" ] || fail 'baseline beside global config'

# A reviewer can enumerate same-user temp files and forge a matching baseline.
export REPO_STATE_CHECK="$SELF_DIR/repo-state-check" SOURCE_GLOBAL="$GIT_CONFIG_GLOBAL"
cat > "$AGY_STUB_ACTIONS" <<'ACTIONS'
git -C "$SRC" config user.name compromised
for state in "$TMPDIR"/dispatch-snapshots.* "$TMPDIR"/dispatch-review-state.*; do
  [ ! -f "$state/before" ] || GIT_CONFIG_GLOBAL="$SOURCE_GLOBAL" "$REPO_STATE_CHECK" snapshot "$SRC" "$state/before"
done
ACTIONS
check_state_run 10
grep -qF 'DISPATCH_REVIEW_STATE=critical(' "$TMP/cfg.err" || fail 'agy baseline forgery passed'
grep -qF 'state: snapshot integrity' "$TMP/cfg.err" || fail 'agy integrity diagnostic absent'
cp "$TMP/state-config.before" "$SRC/.git/config"
# Loss of the baseline must also fail closed.
cat > "$AGY_STUB_ACTIONS" <<'ACTIONS'
for state in "$TMPDIR"/dispatch-snapshots.*; do
  [ ! -f "$state/before" ] || rm "$state/before"
done
ACTIONS
check_state_run 10
grep -qF 'state: snapshot integrity' "$TMP/cfg.err" || fail 'agy baseline loss passed'
if grep -q 'No such file or directory' "$TMP/cfg.err"; then fail 'missing snapshot leaked shell error'; fi
# Removing the whole state directory must preserve the critical exit and diagnostic.
# shellcheck disable=SC2016
printf 'rm -rf "$(dirname "$GIT_CONFIG_GLOBAL")"\n' > "$AGY_STUB_ACTIONS"
check_state_run 10
grep -qE 'DISPATCH_REVIEW_STATE=critical\([0-9]' "$TMP/cfg.err" || fail 'agy state loss count absent'
grep -qF '  state: review state directory missing or unreadable' "$TMP/cfg.err" || fail 'agy state loss diagnostic absent'
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
for state in "$TMPDIR"/dispatch-snapshots.*; do
  [ ! -d "$state" ] || rm "$state/before"
done
STUB
(cd "$SRC" && run_state_runtime claude 10)
grep -qF 'DISPATCH_REVIEW_STATE=critical(' "$TMP/cfg.err" || fail 'claude baseline loss passed'
grep -qF 'state: snapshot integrity' "$TMP/cfg.err" || fail 'claude compare diagnostic absent'

# Snapshot allocation failures must explain the failing allocation on both paths.
REAL_MKTEMP=$(command -v mktemp)
export REAL_MKTEMP
cat > "$TMP/bin/mktemp" <<'STUB'
#!/usr/bin/env bash
case "$*" in *dispatch-snapshots.*) exit 1 ;; esac
exec "$REAL_MKTEMP" "$@"
STUB
chmod +x "$TMP/bin/mktemp"
for runtime in agy claude; do
  (cd "$SRC" && run_state_runtime "$runtime" 3)
  grep -qF 'could not create the review snapshot directory' "$TMP/cfg.err" || fail "$runtime snapshot allocation diagnostic absent"
done
rm "$TMP/bin/mktemp"

# Count suite-local stubs and the definitions factored into the shared helper.
# There are 28 agy stubs across the three parts and shared helper;
# every definition must answer the roster subcommand instead of falling into cat.
agy_stub_defs="$(grep -h 'cat > .*bin/ag[y].*STUB' "$SELF_DIR"/test-dispatch-worker*.sh "$SELF_DIR/lib/test-dispatch-worker-lib.sh" | wc -l | tr -d ' ')"
agy_stub_arms="$(grep -h '^# PERSONA_ROSTER_STU[B]$' "$SELF_DIR"/test-dispatch-worker*.sh "$SELF_DIR/lib/test-dispatch-worker-lib.sh" | wc -l | tr -d ' ')"
[ "$agy_stub_defs" -eq 28 ] || fail "expected 28 agy stubs, found $agy_stub_defs"
[ "$agy_stub_arms" -eq "$agy_stub_defs" ] || fail "not every agy stub has an agent) arm ($agy_stub_arms/$agy_stub_defs)"
echo "test 42 (all 22 original agy stubs handle the agent subcommand) PASS"

restore_default_agy_stub
assert_no_review_residue
if [ "$FAILS" -ne 0 ]; then
  echo "$FAILS TEST(S) FAILED"
  exit 1
fi
echo "ALL PASS"
