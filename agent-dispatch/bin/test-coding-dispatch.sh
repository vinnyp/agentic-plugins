#!/usr/bin/env bash
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"; TMP="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT
# shellcheck disable=SC1091
. "$SELF_DIR/lib/test-env-reset.sh"
# shellcheck disable=SC1091
. "$SELF_DIR/lib/hash.sh"
reset_dispatch_env  # neutralize any operator-exported dispatch vars before the suite runs
CD="$SELF_DIR/coding-dispatch.sh"
fail() { echo "FAIL: $1"; exit 1; }

# A stub agent on PATH that "does work": writes a file into the workdir, mimicking codex/agy.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
# args: exec --dangerously-... -C <workdir> -   ; find the workdir after -C
wd=""; while [ $# -gt 0 ]; do [ "$1" = "-C" ] && { wd="$2"; shift 2; continue; }; shift; done
: "${wd:=$PWD}"
echo "changed line" > "$wd/agent_made_this.txt"
STUB
chmod +x "$TMP/bin/codex"; export PATH="$TMP/bin:$PATH"

# Build a NON-Go git repo (no go.mod).
REPO="$TMP/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
echo "base" > "$REPO/existing.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm base
printf 'do the task\n' > "$TMP/prompt"

# 1. FAILING build-cmd on a non-Go repo MUST fail (rc 1) and REVERT the agent's work.
bash "$CD" codex "$REPO" "$TMP/prompt" "false" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] || fail "failing --build-cmd on non-Go repo should exit 1, got $rc (gate was skipped!)"
[ -f "$REPO/agent_made_this.txt" ] && fail "failing build should have reverted the agent's file"
echo "test 1 (non-Go failing gate reverts) PASS"

# 2. PASSING build-cmd on a non-Go repo keeps the work (rc 0) and writes the marker.
git -C "$REPO" reset --hard -q HEAD; git -C "$REPO" clean -fdq
bash "$CD" codex "$REPO" "$TMP/prompt" "true" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "passing --build-cmd should exit 0, got $rc"
[ -f "$REPO/agent_made_this.txt" ] || fail "passing build should KEEP the agent's file"
echo "test 2 (non-Go passing gate keeps work) PASS"

# ============================ --worktree mode ============================
# Helper: a fresh parent repo with one tracked file + one commit (physical path).
new_parent() {
  local p="$1"; mkdir -p "$p"; git -C "$p" init -q
  git -C "$p" config user.email t@t; git -C "$p" config user.name t
  echo base > "$p/tracked.txt"; git -C "$p" add -A; git -C "$p" commit -qm base
}

review_pin_marker() {
  printf '%s/review-pinned\n' "$(git -C "$1" rev-parse --absolute-git-dir)"
}

write_review_pin_marker() {
  local workdir="$1" label="$2" marker sha
  marker="$(review_pin_marker "$workdir")"
  sha="$(git -C "$workdir" rev-parse HEAD)"
  {
    printf 'sha=%s\n' "$sha"
    printf 'pinned_at=%s\n' "$(date +%s)"
    printf 'pid=%s\n' "$$"
    printf 'label=%s\n' "$label"
  } > "$marker"
}

expected_wt() {
  local p="$1" slug="$2"
  # Compute expected namespaced worktree path (matches new coding-dispatch.sh formula)
  local p_real p_bn p_hash
  p_real="$(cd "$p" && git rev-parse --show-toplevel)"
  p_bn=$(basename "$p_real" | tr -cs 'A-Za-z0-9_-' '_')
  p_hash=$(printf '%s' "$p_real" | md5_hex | cut -c1-8)
  printf '%s/.worktrees/%s_%s/%s\n' "$(cd "$p_real/.." && pwd -P)" "$p_bn" "$p_hash" "$slug"
}

new_parent_with_local_remote() {
  local p="$1" remote="$2"
  new_parent "$p"
  git -C "$p" branch -M main
  git init --bare -q "$remote"
  git -C "$p" remote add origin "$remote"
  git -C "$p" push -q -u origin main
  git --git-dir="$remote" symbolic-ref HEAD refs/heads/main
}

advance_local_remote_main() {
  local remote="$1" clone="$2"
  git clone -q "$remote" "$clone"
  git -C "$clone" config user.email t@t
  git -C "$clone" config user.name t
  printf 'remote ahead\n' >> "$clone/tracked.txt"
  git -C "$clone" add -A
  git -C "$clone" commit -qm "remote ahead"
  git -C "$clone" push -q origin main
}

make_invocation_codex_stub() {
  local d="$1"; mkdir -p "$d"
  cat > "$d/codex" <<'STUB'
#!/usr/bin/env bash
printf 'invoked\n' >> "$AGENT_INVOKED_FILE"
wd=""; while [ $# -gt 0 ]; do [ "$1" = "-C" ] && { wd="$2"; shift 2; continue; }; shift; done
: "${wd:=$PWD}"
echo "pin guard change" > "$wd/pin_guard_change.txt"
STUB
  chmod +x "$d/codex"
}

# #140: active review pins refuse dispatch before the agent can mutate the tree.
P_pin="$TMP/pin_active_parent"; new_parent "$P_pin"
pin_sha="$(git -C "$P_pin" rev-parse HEAD)"
write_review_pin_marker "$P_pin" "review one"
make_invocation_codex_stub "$TMP/pin_active_bin"
old_path="$PATH"
AGENT_INVOKED_FILE="$TMP/pin_active.invoked" PATH="$TMP/pin_active_bin:$old_path" bash "$CD" codex "$P_pin" "$TMP/prompt" "true" >"$TMP/out_pin_active" 2>&1; rc=$?
PATH="$old_path"
[ "$rc" -eq 9 ] || { cat "$TMP/out_pin_active"; fail "#140 active review pin should exit 9, got $rc"; }
grep -q "$pin_sha" "$TMP/out_pin_active" || { cat "$TMP/out_pin_active"; fail "#140 active pin refusal should name pinned SHA $pin_sha"; }
grep -q "label=review one" "$TMP/out_pin_active" || { cat "$TMP/out_pin_active"; fail "#140 active pin refusal should name label"; }
grep -q "age=" "$TMP/out_pin_active" || { cat "$TMP/out_pin_active"; fail "#140 active pin refusal should name age"; }
grep -q "review-pin.sh release" "$TMP/out_pin_active" || { cat "$TMP/out_pin_active"; fail "#140 active pin refusal should print release command"; }
[ ! -e "$TMP/pin_active.invoked" ] || fail "#140 active pin should refuse before invoking the agent"
[ ! -e "$P_pin/pin_guard_change.txt" ] || fail "#140 active pin should refuse before mutating the tree"
echo "test #140 active review pin refuses dispatch before agent PASS"

# #140 negative: the same dispatch shape succeeds when no review pin exists.
P_unpin="$TMP/pin_negative_parent"; new_parent "$P_unpin"
make_invocation_codex_stub "$TMP/pin_negative_bin"
old_path="$PATH"
AGENT_INVOKED_FILE="$TMP/pin_negative.invoked" PATH="$TMP/pin_negative_bin:$old_path" bash "$CD" codex "$P_unpin" "$TMP/prompt" "true" >"$TMP/out_pin_negative" 2>&1; rc=$?
PATH="$old_path"
[ "$rc" -eq 0 ] || { cat "$TMP/out_pin_negative"; fail "#140 unpinned dispatch should succeed, got $rc"; }
[ -e "$TMP/pin_negative.invoked" ] || fail "#140 unpinned dispatch should invoke the agent"
[ -f "$P_unpin/pin_guard_change.txt" ] || fail "#140 unpinned dispatch should keep the agent change"
echo "test #140 unpinned dispatch still succeeds PASS"

# #140 stale pins fall through: status removes the stale marker and dispatch proceeds.
P_stale="$TMP/pin_stale_parent"; new_parent "$P_stale"
stale_marker="$(review_pin_marker "$P_stale")"
stale_sha="$(git -C "$P_stale" rev-parse HEAD)"
stale_time="$(( $(date +%s) - 10 ))"
{
  printf 'sha=%s\n' "$stale_sha"
  printf 'pinned_at=%s\n' "$stale_time"
  printf 'pid=%s\n' "$$"
  printf 'label=%s\n' "stale review"
} > "$stale_marker"
make_invocation_codex_stub "$TMP/pin_stale_bin"
old_path="$PATH"
DISPATCH_REVIEW_PIN_TTL_SECS=1 AGENT_INVOKED_FILE="$TMP/pin_stale.invoked" PATH="$TMP/pin_stale_bin:$old_path" bash "$CD" codex "$P_stale" "$TMP/prompt" "true" >"$TMP/out_pin_stale" 2>&1; rc=$?
PATH="$old_path"
[ "$rc" -eq 0 ] || { cat "$TMP/out_pin_stale"; fail "#140 stale pin should not block dispatch, got $rc"; }
[ -e "$TMP/pin_stale.invoked" ] || fail "#140 stale pin should allow agent invocation"
[ ! -e "$stale_marker" ] || fail "#140 stale pin marker should be removed by status"
echo "test #140 stale review pin is removed and dispatch proceeds PASS"

# #140: --worktree mode is also refused against a pinned parent before any worktree is created.
P_pin_wt="$TMP/pin_worktree_parent"; new_parent "$P_pin_wt"
pin_wt_sha="$(git -C "$P_pin_wt" rev-parse HEAD)"
write_review_pin_marker "$P_pin_wt" "worktree review"
make_invocation_codex_stub "$TMP/pin_worktree_bin"
old_path="$PATH"
AGENT_INVOKED_FILE="$TMP/pin_worktree.invoked" PATH="$TMP/pin_worktree_bin:$old_path" CODING_DISPATCH_WORKTREE="pinWt" bash "$CD" --worktree codex "$P_pin_wt" "$TMP/prompt" "true" >"$TMP/out_pin_worktree" 2>&1; rc=$?
PATH="$old_path"
[ "$rc" -eq 9 ] || { cat "$TMP/out_pin_worktree"; fail "#140 --worktree active pin should exit 9, got $rc"; }
grep -q "$pin_wt_sha" "$TMP/out_pin_worktree" || { cat "$TMP/out_pin_worktree"; fail "#140 --worktree refusal should name pinned SHA $pin_wt_sha"; }
[ ! -e "$TMP/pin_worktree.invoked" ] || fail "#140 --worktree active pin should refuse before invoking the agent"
WT_PIN="$(expected_wt "$P_pin_wt" pinWt)"
[ ! -e "$WT_PIN" ] || fail "#140 --worktree active pin should refuse before creating worktree $WT_PIN"
echo "test #140 --worktree active review pin refuses dispatch PASS"

make_env_codex_stub() {
  local d="$1"; mkdir -p "$d"
  cat > "$d/codex" <<'STUB'
#!/usr/bin/env bash
wd=""; while [ $# -gt 0 ]; do [ "$1" = "-C" ] && { wd="$2"; shift 2; continue; }; shift; done
: "${wd:=$PWD}"
env > "$CAPTURE_ENV"
echo "env capture change $(date +%s)$RANDOM" >> "$wd/env_capture.txt"
STUB
  chmod +x "$d/codex"
}

# The variable NAMES the child saw, minus the ones that legitimately differ between two runs
# in two different directories. Used to prove the dispatcher injects nothing of its own.
child_env_names() {
  sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' "$1" \
    | grep -Ev '^(PWD|OLDPWD|SHLVL|_|CAPTURE_ENV|PATH|TMPDIR)$' | sort -u
}

# CODING_DISPATCH_CHILD_ENV: the caller names the variables, the dispatcher only forwards them.
P_ce1="$TMP/childenv_one"; new_parent "$P_ce1"
make_env_codex_stub "$TMP/childenv_one_bin"
env -u REPO_LEDGER -u REPO_MODE CAPTURE_ENV="$TMP/childenv_one.env" PATH="$TMP/childenv_one_bin:$PATH" \
  CODING_DISPATCH_CHILD_ENV="REPO_LEDGER=off REPO_MODE=ci" \
  bash "$CD" codex "$P_ce1" "$TMP/prompt" "true" >"$TMP/out_childenv_one" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out_childenv_one"; fail "child-env: dispatch should exit 0, got $rc"; }
grep -q '^REPO_LEDGER=off$' "$TMP/childenv_one.env" || { cat "$TMP/out_childenv_one"; fail "child-env: REPO_LEDGER=off did not reach the dispatched agent"; }
grep -q '^REPO_MODE=ci$' "$TMP/childenv_one.env" || { cat "$TMP/out_childenv_one"; fail "child-env: the second KEY=VALUE pair did not reach the dispatched agent"; }
echo "test child-env 1 (CODING_DISPATCH_CHILD_ENV reaches the dispatched agent) PASS"

# Unset hook => the child environment is untouched.
P_ce2="$TMP/childenv_two"; new_parent "$P_ce2"
make_env_codex_stub "$TMP/childenv_two_bin"
env -u REPO_LEDGER -u REPO_MODE CAPTURE_ENV="$TMP/childenv_two.env" PATH="$TMP/childenv_two_bin:$PATH" \
  bash "$CD" codex "$P_ce2" "$TMP/prompt" "true" >"$TMP/out_childenv_two" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out_childenv_two"; fail "child-env: control dispatch should exit 0, got $rc"; }
! grep -q '^REPO_LEDGER=' "$TMP/childenv_two.env" || fail "child-env: nothing should be exported when CODING_DISPATCH_CHILD_ENV is unset"
echo "test child-env 2 (no hook set => child environment untouched) PASS"

# No per-repo auto-detection survives: two repos with different names and different contents
# must hand the agent the SAME set of environment variable names. A hard-coded "if this repo
# looks like X, pin variable Y" branch (the retired special case) shows up here as a diff.
P_ce3="$TMP/childenv_shaped_repo"; new_parent "$P_ce3"
mkdir -p "$P_ce3/run"; printf '# a runner\n' > "$P_ce3/run/audit.py"
git -C "$P_ce3" add -A; git -C "$P_ce3" commit -qm "add a runner-shaped file"
make_env_codex_stub "$TMP/childenv_three_bin"
env -u REPO_LEDGER -u REPO_MODE CAPTURE_ENV="$TMP/childenv_three.env" PATH="$TMP/childenv_three_bin:$PATH" \
  bash "$CD" codex "$P_ce3" "$TMP/prompt" "true" >"$TMP/out_childenv_three" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out_childenv_three"; fail "child-env: shaped-repo dispatch should exit 0, got $rc"; }
child_env_names "$TMP/childenv_two.env" > "$TMP/childenv_names_plain"
child_env_names "$TMP/childenv_three.env" > "$TMP/childenv_names_shaped"
diff -u "$TMP/childenv_names_plain" "$TMP/childenv_names_shaped" >"$TMP/childenv_names.diff" 2>&1 \
  || { cat "$TMP/childenv_names.diff"; fail "child-env: the dispatcher injected a repo-specific variable — per-repo auto-detection is back"; }
echo "test child-env 3 (no per-repo auto-detection remains) PASS"

# Malformed entries are reported and skipped; well-formed ones in the same list still land.
P_ce4="$TMP/childenv_four"; new_parent "$P_ce4"
make_env_codex_stub "$TMP/childenv_four_bin"
env -u REPO_LEDGER CAPTURE_ENV="$TMP/childenv_four.env" PATH="$TMP/childenv_four_bin:$PATH" \
  CODING_DISPATCH_CHILD_ENV="NOTAPAIR 9BAD=x REPO_LEDGER=off" \
  bash "$CD" codex "$P_ce4" "$TMP/prompt" "true" >"$TMP/out_childenv_four" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out_childenv_four"; fail "child-env: a malformed entry must not fail the dispatch, got rc=$rc"; }
grep -qF "ignoring 'NOTAPAIR'" "$TMP/out_childenv_four" || { cat "$TMP/out_childenv_four"; fail "child-env: a non-KEY=VALUE entry should be reported"; }
grep -qF "ignoring '9BAD=x'" "$TMP/out_childenv_four" || { cat "$TMP/out_childenv_four"; fail "child-env: an invalid variable name should be reported"; }
grep -q '^REPO_LEDGER=off$' "$TMP/childenv_four.env" || { cat "$TMP/out_childenv_four"; fail "child-env: a well-formed pair alongside malformed ones should still be exported"; }
echo "test child-env 4 (malformed entries reported + skipped) PASS"

# child-env 5: the split must NOT be subject to pathname expansion. `for _kv in $VAR` globs,
# so the repo's own contents rewrite the caller's value: with a file named `MSG=hi` in the
# workdir, `MSG=h?` silently becomes `MSG=hi`, and a bare `*` fans out into one bogus entry
# per file. Assert on what the CHILD saw, and on the absence of the fan-out warnings.
P_ce5="$TMP/childenv_glob"; new_parent "$P_ce5"
: > "$P_ce5/MSG=hi"; : > "$P_ce5/decoy_one"; : > "$P_ce5/decoy_two"
git -C "$P_ce5" add -A; git -C "$P_ce5" commit -qm "files that a glob would match"
make_env_codex_stub "$TMP/childenv_five_bin"
env -u MSG CAPTURE_ENV="$TMP/childenv_five.env" PATH="$TMP/childenv_five_bin:$PATH" \
  CODING_DISPATCH_CHILD_ENV="MSG=h?" \
  bash "$CD" codex "$P_ce5" "$TMP/prompt" "true" >"$TMP/out_childenv_five" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out_childenv_five"; fail "child-env glob: dispatch should exit 0, got $rc"; }
grep -q '^MSG=h?$' "$TMP/childenv_five.env" || { grep '^MSG=' "$TMP/childenv_five.env" || true; fail "child-env glob: the value was rewritten by pathname expansion (a file in the workdir changed what the agent saw)"; }
echo "test child-env 5 (no pathname expansion: value survives a matching filename) PASS"

# A bare glob must stay one malformed entry, not one per file in the workdir.
git -C "$P_ce5" reset --hard -q HEAD; git -C "$P_ce5" clean -fdq
env -u MSG CAPTURE_ENV="$TMP/childenv_six.env" PATH="$TMP/childenv_five_bin:$PATH" \
  CODING_DISPATCH_CHILD_ENV="KEEP=1 *" \
  bash "$CD" codex "$P_ce5" "$TMP/prompt" "true" >"$TMP/out_childenv_six" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out_childenv_six"; fail "child-env glob: bare-glob dispatch should exit 0, got $rc"; }
grep -q '^KEEP=1$' "$TMP/childenv_six.env" || fail "child-env glob: the well-formed pair alongside a bare glob was lost"
grep -qF "ignoring 'decoy_one'" "$TMP/out_childenv_six" && { cat "$TMP/out_childenv_six"; fail "child-env glob: a bare '*' fanned out into the workdir's filenames"; }
[ "$(grep -c "CODING_DISPATCH_CHILD_ENV: ignoring" "$TMP/out_childenv_six")" -eq 1 ] || { cat "$TMP/out_childenv_six"; fail "child-env glob: expected exactly one malformed-entry warning for the bare glob"; }
echo "test child-env 6 (bare glob stays one entry, no fan-out) PASS"

# child-env 7: a value with a space is truncated at the space by the format. The warning must
# say so AND name the key whose value was cut — "ignoring 'world'" alone hides the real damage.
git -C "$P_ce5" reset --hard -q HEAD; git -C "$P_ce5" clean -fdq
env -u MSG CAPTURE_ENV="$TMP/childenv_seven.env" PATH="$TMP/childenv_five_bin:$PATH" \
  CODING_DISPATCH_CHILD_ENV="MSG=hello world" \
  bash "$CD" codex "$P_ce5" "$TMP/prompt" "true" >"$TMP/out_childenv_seven" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out_childenv_seven"; fail "child-env truncation: dispatch should exit 0, got $rc"; }
grep -q '^MSG=hello$' "$TMP/childenv_seven.env" || fail "child-env truncation: MSG should have been set to the text before the space"
grep -qF "values cannot contain whitespace" "$TMP/out_childenv_seven" || { cat "$TMP/out_childenv_seven"; fail "child-env truncation: the warning does not explain that the value was cut at whitespace"; }
grep -qF "MSG was set to" "$TMP/out_childenv_seven" || { cat "$TMP/out_childenv_seven"; fail "child-env truncation: the warning does not name the KEY whose value was truncated"; }
echo "test child-env 7 (truncated value names the key it belonged to) PASS"

# (a) worktree created OUTSIDE the parent checkout; agent's file lands INSIDE it; contract emitted.
P="$TMP/wtA"; new_parent "$P"
CODING_DISPATCH_WORKTREE="slugA" bash "$CD" --worktree codex "$P" "$TMP/prompt" "true" >"$TMP/outA" 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "(a) --worktree success should exit 0, got $rc"
WT="$(expected_wt "$P" slugA)"
[ -d "$WT" ] || fail "(a) worktree should exist at $WT (sibling .worktrees, outside the checkout)"
[ ! -e "$P/.worktrees" ] || fail "(a) .worktrees must NOT be inside the parent checkout"
[ -f "$WT/agent_made_this.txt" ] || fail "(a) agent's file should be inside the worktree"
[ ! -f "$P/agent_made_this.txt" ] || fail "(a) agent's file must NOT be in the parent checkout"
# Output now emits both worktree_ns= (new) and worktree= (deprecation alias); check both
grep -q "DISPATCH=ok worktree_ns=$WT" "$TMP/outA" || { cat "$TMP/outA"; fail "(a) worktree_ns= missing from success contract"; }
grep -q "worktree=$WT" "$TMP/outA" || { cat "$TMP/outA"; fail "(a) worktree= deprecation alias missing from success contract"; }
grep -qE "branch=slugA .*head=[0-9a-f]" "$TMP/outA" || { cat "$TMP/outA"; fail "(a) branch/head missing from success contract"; }
grep -qE "base_sha=[0-9a-f]{7,}" "$TMP/outA" || { cat "$TMP/outA"; fail "(a) base_sha missing from success contract"; }
grep -qE "head=[0-9a-f]{7,}" "$TMP/outA" || fail "(a) contract should carry a real SHA"
grep -q "DISPATCH_BASE base_ref=HEAD base_sha=" "$TMP/outA" || { cat "$TMP/outA"; fail "(a) resolved base line should print on --worktree run"; }
echo "test (a) worktree created outside + dispatch inside PASS"

# (c) success leaves the branch (no auto-merge): branch ref exists, parent HEAD unchanged.
git -C "$P" show-ref --verify --quiet refs/heads/slugA || fail "(c) branch slugA should exist after success"
echo "test (c) success leaves branch, no auto-merge PASS"

# (a2) --base <ref> creates the isolated worktree from that ref, not the parent HEAD.
P_base="$TMP/wt_base_parent"; new_parent "$P_base"
base_sha="$(git -C "$P_base" rev-parse HEAD)"
git -C "$P_base" branch base_for_dispatch "$base_sha"
printf 'newer local head\n' >> "$P_base/tracked.txt"
git -C "$P_base" add -A
git -C "$P_base" commit -qm "advance parent head"
CODING_DISPATCH_WORKTREE="slugBase" bash "$CD" --worktree --base base_for_dispatch codex "$P_base" "$TMP/prompt" "true" >"$TMP/out_base" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out_base"; fail "--base dispatch should succeed, got $rc"; }
WT_BASE="$(expected_wt "$P_base" slugBase)"
[ "$(git -C "$WT_BASE" rev-parse HEAD)" = "$base_sha" ] || fail "--base worktree HEAD should be $base_sha, got $(git -C "$WT_BASE" rev-parse HEAD)"
grep -q "DISPATCH_BASE base_ref=base_for_dispatch" "$TMP/out_base" || { cat "$TMP/out_base"; fail "--base should print resolved base ref"; }
grep -q "base_sha=$(git -C "$P_base" rev-parse --short "$base_sha")" "$TMP/out_base" || { cat "$TMP/out_base"; fail "--base short SHA missing from output/contract"; }
echo "test --base creates worktree at requested ref PASS"

# (a2b) Invalid --base dies with a clear ref-resolution error.
P_bad_base="$TMP/wt_bad_base_parent"; new_parent "$P_bad_base"
CODING_DISPATCH_WORKTREE="slugBadBase" bash "$CD" --worktree --base does-not-exist codex "$P_bad_base" "$TMP/prompt" "true" >"$TMP/out_bad_base" 2>&1; rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out_bad_base"; fail "invalid --base should exit 2, got $rc"; }
grep -q "invalid --base ref: does-not-exist" "$TMP/out_bad_base" || { cat "$TMP/out_bad_base"; fail "invalid --base should name the bad ref"; }
[ ! -e "$(expected_wt "$P_bad_base" slugBadBase)" ] || fail "invalid --base should fail before creating a worktree"
echo "test invalid --base ref fails clearly PASS"

# (a3) A base behind its existing local upstream tracking ref fails closed and names the count.
P_stale_base="$TMP/wt_stale_base_parent"; R_stale_base="$TMP/wt_stale_base_remote.git"
new_parent_with_local_remote "$P_stale_base" "$R_stale_base"
advance_local_remote_main "$R_stale_base" "$TMP/wt_stale_base_remote_clone"
git -C "$P_stale_base" fetch -q origin main
CODING_DISPATCH_WORKTREE="slugStaleBase" bash "$CD" --worktree codex "$P_stale_base" "$TMP/prompt" "true" >"$TMP/out_stale_base" 2>&1; rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out_stale_base"; fail "stale local base should fail closed with rc 2, got $rc"; }
grep -q "behind last fetched origin/main by 1 commit" "$TMP/out_stale_base" || { cat "$TMP/out_stale_base"; fail "stale local base message should name count and last-fetched ref"; }
grep -q "fetch+rebase, pass --base, or pass --allow-stale-base" "$TMP/out_stale_base" || { cat "$TMP/out_stale_base"; fail "stale local base message should name remediations"; }
[ ! -e "$(expected_wt "$P_stale_base" slugStaleBase)" ] || fail "stale base refusal should happen before worktree creation"
echo "test stale worktree base fails closed against local tracking ref PASS"

# (a4) --allow-stale-base permits the same stale base but still reports staleness.
CODING_DISPATCH_WORKTREE="slugStaleAllowed" bash "$CD" --worktree --allow-stale-base codex "$P_stale_base" "$TMP/prompt" "true" >"$TMP/out_stale_allowed" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out_stale_allowed"; fail "--allow-stale-base should proceed on stale base, got $rc"; }
grep -q "DISPATCH_BASE_STALE" "$TMP/out_stale_allowed" || { cat "$TMP/out_stale_allowed"; fail "--allow-stale-base should still print staleness"; }
grep -q "behind=1" "$TMP/out_stale_allowed" || { cat "$TMP/out_stale_allowed"; fail "--allow-stale-base staleness should name commit count"; }
grep -q "DISPATCH=ok" "$TMP/out_stale_allowed" || { cat "$TMP/out_stale_allowed"; fail "--allow-stale-base should complete dispatch"; }
echo "test --allow-stale-base proceeds but reports staleness PASS"

# (a5) No upstream configured is stated plainly and proceeds without claiming freshness.
P_no_upstream="$TMP/wt_no_upstream_parent"; new_parent "$P_no_upstream"
CODING_DISPATCH_WORKTREE="slugNoUpstream" bash "$CD" --worktree codex "$P_no_upstream" "$TMP/prompt" "true" >"$TMP/out_no_upstream" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out_no_upstream"; fail "no-upstream worktree dispatch should proceed, got $rc"; }
grep -q "status=no-upstream" "$TMP/out_no_upstream" || { cat "$TMP/out_no_upstream"; fail "no-upstream dispatch should state no upstream"; }
! grep -qi "fresh" "$TMP/out_no_upstream" || { cat "$TMP/out_no_upstream"; fail "no-upstream dispatch must not claim freshness"; }
echo "test no-upstream worktree base proceeds without freshness claim PASS"

# (b) a tracked-but-uncommitted change in the PARENT survives a FAILED dispatch, byte-identical.
P="$TMP/wtB"; new_parent "$P"
echo "uncommitted edit" >> "$P/tracked.txt"     # dirty parent (a concurrent session's work)
before_status="$(git -C "$P" status --porcelain)"; before_head="$(git -C "$P" rev-parse HEAD)"
before_file="$(cat "$P/tracked.txt")"
CODING_DISPATCH_WORKTREE="slugB" bash "$CD" --worktree codex "$P" "$TMP/prompt" "false" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] || fail "(b) failing gate should exit 1, got $rc"
[ "$(git -C "$P" status --porcelain)" = "$before_status" ] || fail "(b) parent status changed across a failed dispatch"
[ "$(git -C "$P" rev-parse HEAD)" = "$before_head" ] || fail "(b) parent HEAD moved across a failed dispatch"
[ "$(cat "$P/tracked.txt")" = "$before_file" ] || fail "(b) parent's uncommitted edit was clobbered"
echo "test (b) parent uncommitted work survives failed dispatch PASS"

# build failure SALVAGES the worktree diff (does not remove it).
WT="$(expected_wt "$P" slugB)"
[ -d "$WT" ] || fail "(salvage) failed dispatch should leave the worktree for salvage"
[ -f "$WT/agent_made_this.txt" ] || fail "(salvage) salvaged diff should remain in worktree"
echo "test (salvage on failure) PASS"

# (clobber) a pre-existing branch that is NOT our active worktree → fail-loud (exit 2).
P="$TMP/wtC"; new_parent "$P"
git -C "$P" branch slugX
CODING_DISPATCH_WORKTREE="slugX" bash "$CD" --worktree codex "$P" "$TMP/prompt" "true" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "(clobber) pre-existing branch should fail-loud (exit 2), got $rc"
echo "test (clobber guard fails loud) PASS"

# (d) a TERM to the dispatch SCRIPT mid-run fires the trap and removes the fresh empty worktree.
mkdir -p "$TMP/slowbin"
printf '#!/usr/bin/env bash\nsleep 5\n' > "$TMP/slowbin/codex"; chmod +x "$TMP/slowbin/codex"
P="$TMP/wtD"; new_parent "$P"
PATH="$TMP/slowbin:$PATH" CODING_DISPATCH_WORKTREE="slugD" bash "$CD" --worktree codex "$P" "$TMP/prompt" "true" >"$TMP/out_wtD" 2>&1 &
disp_pid=$!
WT="$(expected_wt "$P" slugD)"
for _ in $(seq 1 100); do [ -d "$WT" ] && break; sleep 0.1; done
[ -d "$WT" ] || fail "(d) worktree should be created before signaling"
for _ in $(seq 1 100); do grep -q "dispatching to codex" "$TMP/out_wtD" 2>/dev/null && break; sleep 0.1; done
grep -q "dispatching to codex" "$TMP/out_wtD" || { cat "$TMP/out_wtD"; fail "(d) dispatch should reach agent invocation before signaling"; }
kill -TERM "$disp_pid" 2>/dev/null
wait "$disp_pid"; rc=$?
[ "$rc" -eq 143 ] || fail "(d) dispatch should exit 143 on TERM, got $rc"
[ ! -d "$WT" ] || fail "(d) trap should remove the fresh empty worktree (no test-side prune)"
echo "test (d) TERM fires trap, removes empty worktree PASS"

# (d2) SIGKILL the script (untrappable) → orphan dir remains → next same-slug run REUSES (not die).
mkdir -p "$TMP/slowbin2"
printf '#!/usr/bin/env bash\nsleep 5\n' > "$TMP/slowbin2/codex"; chmod +x "$TMP/slowbin2/codex"
P="$TMP/wtK"; new_parent "$P"
PATH="$TMP/slowbin2:$PATH" CODING_DISPATCH_WORKTREE="slugK" bash "$CD" --worktree codex "$P" "$TMP/prompt" "true" >/dev/null 2>&1 &
k_pid=$!
WT="$(expected_wt "$P" slugK)"
for _ in $(seq 1 100); do [ -d "$WT" ] && break; sleep 0.1; done
[ -d "$WT" ] || fail "(d2) worktree should be created before SIGKILL"
kill -KILL "$k_pid" 2>/dev/null; wait "$k_pid" 2>/dev/null
[ -d "$WT" ] || fail "(d2) SIGKILL should leave the orphan worktree dir (untrappable)"
CODING_DISPATCH_WORKTREE="slugK" bash "$CD" --worktree codex "$P" "$TMP/prompt" "true" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "(d2) next run should REUSE the orphaned worktree, got rc=$rc (die/clobber?)"
echo "test (d2) SIGKILL orphan self-heals via reuse PASS"

# (reuse) two dispatches with the SAME slug accumulate on ONE branch; parent main untouched.
# Distinct-content stub so the second dispatch is not an empty diff.
mkdir -p "$TMP/uniqbin"
cat > "$TMP/uniqbin/codex" <<'STUB'
#!/usr/bin/env bash
wd=""; while [ $# -gt 0 ]; do [ "$1" = "-C" ] && { wd="$2"; shift 2; continue; }; shift; done
: "${wd:=$PWD}"
echo "change $(date +%s)$RANDOM" >> "$wd/agent_made_this.txt"
STUB
chmod +x "$TMP/uniqbin/codex"
P="$TMP/wtR"; new_parent "$P"; parent_head="$(git -C "$P" rev-parse HEAD)"
PATH="$TMP/uniqbin:$PATH" CODING_DISPATCH_WORKTREE="slugR" bash "$CD" --worktree codex "$P" "$TMP/prompt" "true" >/dev/null 2>&1 || fail "(reuse) first dispatch failed"
WT="$(expected_wt "$P" slugR)"
( cd "$WT" && git add -A && git commit -qm task1 )     # caller commits in the worktree
t1="$(git -C "$WT" rev-parse HEAD)"
PATH="$TMP/uniqbin:$PATH" CODING_DISPATCH_WORKTREE="slugR" bash "$CD" --worktree codex "$P" "$TMP/prompt" "true" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "(reuse) second dispatch into existing worktree should exit 0, got $rc"
[ "$(git -C "$WT" rev-parse HEAD)" = "$t1" ] || fail "(reuse) second dispatch should build on task1 (no commit by dispatch)"
[ "$(git -C "$P" rev-parse HEAD)" = "$parent_head" ] || fail "(reuse) parent main must stay untouched"
echo "test (reuse accumulates on one branch) PASS"

# (reuse-noop) a genuine no-op on a REUSED worktree must FAIL (empty diff), not falsely
# succeed — guards the marker-leak regression (a committed marker would make rm -f churn the tree).
mkdir -p "$TMP/noopbin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/noopbin/codex"; chmod +x "$TMP/noopbin/codex"
P="$TMP/wtN"; new_parent "$P"
PATH="$TMP/uniqbin:$PATH" CODING_DISPATCH_WORKTREE="slugN" bash "$CD" --worktree codex "$P" "$TMP/prompt" "true" >/dev/null 2>&1 || fail "(reuse-noop) first dispatch failed"
WTN="$(expected_wt "$P" slugN)"
( cd "$WTN" && git add -A && git commit -qm task1 )
git -C "$WTN" status --porcelain | grep -q "_coding-result.json" && fail "(reuse-noop) marker leaked into the worktree commit"
PATH="$TMP/noopbin:$PATH" CODING_DISPATCH_WORKTREE="slugN" bash "$CD" --worktree codex "$P" "$TMP/prompt" "true" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] || fail "(reuse-noop) no-op on reused worktree should exit 1 (empty diff), got $rc"
[ -z "$(git -C "$WTN" status --porcelain)" ] || fail "(reuse-noop) no-op left churn in the worktree"
echo "test (reuse no-op correctly rejected) PASS"

# (e) regression: the non-worktree path (tests 1-2 above) is unchanged.
echo "test (e) non-worktree path unchanged (tests 1-2) PASS"

# Test: --allow-path gate PASS — agent edits only an allowed file
P_ap="$TMP/ap_parent"
new_parent "$P_ap" 2>/dev/null || { mkdir -p "$P_ap"; git -C "$P_ap" init -q; git -C "$P_ap" config user.email t@t; git -C "$P_ap" config user.name t; echo base > "$P_ap/allowed.txt"; git -C "$P_ap" add -A; git -C "$P_ap" commit -qm base; }
# Stub that only writes agent_made_this.txt (which is in the allowlist)
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
wd=""; while [ $# -gt 0 ]; do [ "$1" = "-C" ] && { wd="$2"; shift 2; continue; }; shift; done
: "${wd:=$PWD}"; echo "allowed" > "$wd/agent_made_this.txt"
STUB
chmod +x "$TMP/bin/codex"
bash "$CD" --allow-path "agent_made_this.txt" codex "$P_ap" "$TMP/prompt" "true" >"$TMP/out_ap" 2>/dev/null; rc=$?
[ "$rc" -eq 0 ] || fail "--allow-path gate PASS test: should exit 0 when only allowed file changed, got $rc"
grep -q "DISPATCH=ok" "$TMP/out_ap" || { cat "$TMP/out_ap"; fail "--allow-path gate PASS: DISPATCH=ok missing from output"; }
echo "test --allow-path gate PASS PASS"

# Test: --allow-path gate FAIL — agent edits a file NOT in allowlist
P_deny="$TMP/deny_parent"
mkdir -p "$P_deny"; git -C "$P_deny" init -q; git -C "$P_deny" config user.email t@t; git -C "$P_deny" config user.name t
echo base > "$P_deny/ok.txt"; git -C "$P_deny" add -A; git -C "$P_deny" commit -qm base
# Stub that writes an out-of-scope file
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
wd=""; while [ $# -gt 0 ]; do [ "$1" = "-C" ] && { wd="$2"; shift 2; continue; }; shift; done
: "${wd:=$PWD}"; echo "out of scope" > "$wd/sneaky.txt"
STUB
chmod +x "$TMP/bin/codex"
bash "$CD" --allow-path "allowed_only.txt" codex "$P_deny" "$TMP/prompt" "true" 2>/dev/null; rc=$?
[ "$rc" -eq 1 ] || fail "--allow-path gate FAIL test: should exit 1 when out-of-scope file changed, got $rc"
# non-worktree scope gate must revert (exit-1 contract: non-worktree → tree reset to HEAD)
[ -z "$(git -C "$P_deny" status --porcelain)" ] || fail "--allow-path gate FAIL: tree not clean after scope gate trip (revert missing)"
echo "test --allow-path gate FAIL (out-of-scope) PASS"

# Test: two repos with same basename at different paths produce distinct worktree paths
P_r1="$TMP/repos/app"; P_r2="$TMP/repos2/app"
mkdir -p "$P_r1" "$P_r2"
for _p in "$P_r1" "$P_r2"; do
  git -C "$_p" init -q; git -C "$_p" config user.email t@t; git -C "$_p" config user.name t
  echo base > "$_p/f.txt"; git -C "$_p" add -A; git -C "$_p" commit -qm base
done
_r1_real="$(cd "$P_r1" && git rev-parse --show-toplevel)"
_r1_bn=$(basename "$_r1_real" | tr -cs 'A-Za-z0-9_-' '_')
_r1_hash=$(printf '%s' "$_r1_real" | md5_hex | cut -c1-8)
_r2_real="$(cd "$P_r2" && git rev-parse --show-toplevel)"
_r2_bn=$(basename "$_r2_real" | tr -cs 'A-Za-z0-9_-' '_')
_r2_hash=$(printf '%s' "$_r2_real" | md5_hex | cut -c1-8)
[ "${_r1_bn}_${_r1_hash}" != "${_r2_bn}_${_r2_hash}" ] || fail "same-basename repos must produce different namespace components; got identical: ${_r1_bn}_${_r1_hash}"
echo "test same-basename repos produce distinct namespace components PASS"

# #48: brief fingerprint is content-derived and changes across different briefs.
P_fp="$TMP/fingerprint_parent"; new_parent "$P_fp"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
wd=""; while [ $# -gt 0 ]; do [ "$1" = "-C" ] && { wd="$2"; shift 2; continue; }; shift; done
: "${wd:=$PWD}"; echo "fingerprint $(date +%s)$RANDOM" >> "$wd/fingerprint.txt"
STUB
chmod +x "$TMP/bin/codex"
printf 'first brief line\nbody\n' > "$TMP/prompt-fp-a"
printf 'different brief line\nbody\n' > "$TMP/prompt-fp-b"
bash "$CD" codex "$P_fp" "$TMP/prompt-fp-a" "true" >"$TMP/out_fp_a" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out_fp_a"; fail "#48 first fingerprint dispatch should pass"; }
git -C "$P_fp" reset --hard -q HEAD; git -C "$P_fp" clean -fdq
bash "$CD" codex "$P_fp" "$TMP/prompt-fp-b" "true" >"$TMP/out_fp_b" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out_fp_b"; fail "#48 second fingerprint dispatch should pass"; }
grep -qE 'brief fingerprint: [0-9a-f]{12} \([0-9]+B\); first line: first brief line' "$TMP/out_fp_a" || { cat "$TMP/out_fp_a"; fail "#48 first fingerprint line missing or malformed"; }
grep -qE 'brief fingerprint: [0-9a-f]{12} \([0-9]+B\); first line: different brief line' "$TMP/out_fp_b" || { cat "$TMP/out_fp_b"; fail "#48 second fingerprint line missing or malformed"; }
fp_a="$(sed -n 's/.*brief fingerprint: \([0-9a-f]\{12\}\).*/\1/p' "$TMP/out_fp_a" | head -1)"
fp_b="$(sed -n 's/.*brief fingerprint: \([0-9a-f]\{12\}\).*/\1/p' "$TMP/out_fp_b" | head -1)"
[ -n "$fp_a" ] && [ -n "$fp_b" ] && [ "$fp_a" != "$fp_b" ] || fail "#48 different briefs should produce different fingerprints"
echo "test #48 brief fingerprint content-derived PASS"

# #20: agy gets 25m default, explicit timeout wins, and timeout hint is agy-only.
mkdir -p "$TMP/timeoutbin"
cat > "$TMP/timeoutbin/timeout" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TIMEOUT_ARGS_FILE"
exit 124
STUB
chmod +x "$TMP/timeoutbin/timeout"
cat > "$TMP/bin/agy" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP/bin/agy"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP/bin/codex"
P_to="$TMP/timeout_parent"; new_parent "$P_to"
export TIMEOUT_ARGS_FILE="$TMP/timeout-args"
: > "$TIMEOUT_ARGS_FILE"
PATH="$TMP/timeoutbin:$TMP/bin:$PATH" bash "$CD" agy "$P_to" "$TMP/prompt" "true" >"$TMP/out_to_agy" 2>&1; rc=$?
[ "$rc" -eq 1 ] || fail "#20 agy timeout/no-op path should fail empty diff with rc 1, got $rc"
grep -q -- '-k 30s 25m agy' "$TIMEOUT_ARGS_FILE" || { cat "$TIMEOUT_ARGS_FILE"; fail "#20 agy default timeout should be 25m"; }
grep -q "agy model: Gemini 3.5 Flash (Medium)" "$TMP/out_to_agy" || { cat "$TMP/out_to_agy"; fail "#20 agy model note missing"; }
grep -q "agy timed out (rc=124)" "$TMP/out_to_agy" || { cat "$TMP/out_to_agy"; fail "#20 agy timeout hint missing"; }
: > "$TIMEOUT_ARGS_FILE"
PATH="$TMP/timeoutbin:$TMP/bin:$PATH" CODING_DISPATCH_TIMEOUT=10m bash "$CD" agy "$P_to" "$TMP/prompt" "true" >"$TMP/out_to_agy_explicit" 2>&1; rc=$?
[ "$rc" -eq 1 ] || fail "#20 explicit timeout agy path should fail empty diff with rc 1, got $rc"
grep -q -- '-k 30s 10m agy' "$TIMEOUT_ARGS_FILE" || { cat "$TIMEOUT_ARGS_FILE"; fail "#20 explicit CODING_DISPATCH_TIMEOUT should override agy default"; }
: > "$TIMEOUT_ARGS_FILE"
PATH="$TMP/timeoutbin:$TMP/bin:$PATH" bash "$CD" codex "$P_to" "$TMP/prompt" "true" >"$TMP/out_to_codex" 2>&1; rc=$?
[ "$rc" -eq 1 ] || fail "#20 codex timeout/no-op path should fail empty diff with rc 1, got $rc"
grep -q -- '-k 30s 15m codex' "$TIMEOUT_ARGS_FILE" || { cat "$TIMEOUT_ARGS_FILE"; fail "#20 codex default timeout should remain 15m"; }
! grep -q "agy timed out" "$TMP/out_to_codex" || { cat "$TMP/out_to_codex"; fail "#20 codex run must not print agy timeout hint"; }
PATH="$TMP/timeoutbin:$TMP/bin:$PATH" AGY_MODEL="Gemini 3.1 Pro (High)" bash "$CD" agy "$P_to" "$TMP/prompt" "true" >"$TMP/out_to_pro" 2>&1; rc=$?
[ "$rc" -eq 1 ] || fail "#20 Pro warning run should fail empty diff with rc 1, got $rc"
grep -q "deep/slow agy model (Pro)" "$TMP/out_to_pro" || { cat "$TMP/out_to_pro"; fail "#20 Pro model warning missing"; }
echo "test #20 agy timeout defaults, hint, and model surfacing PASS"

# #21 (regression): the agy invocation must use BARE STDIN, in BOTH dispatch branches.
# agy 1.1.22 rejects `exec` and a bare `-` as unexpected positionals, and `--print` takes the
# NEXT TOKEN as its prompt -- so `--print --dangerously-skip-permissions` makes agy treat the
# flag as the prompt and IGNORE stdin entirely (rc=2).
#
# The two branches must be asserted through DIFFERENT recorders: the timeout stub exits 124
# without ever exec'ing agy, so branch 1 is only visible in the wrapper's argv; the no-timeout
# fallback never touches the wrapper, so it is only visible in agy's own argv. Asserting just
# one of them would leave the other branch free to regress silently.
#
# Patterns are space-padded on BOTH sides so a forbidden token is caught even when it is the
# FIRST or LAST argument (an unpadded *" --print"* misses `--print` in position 1).
assert_agy_bare_stdin() {
  local branch="$1" argv="$2" padded
  [ -n "$argv" ] || fail "#21 ($branch) no agy invocation recorded"
  padded=" $argv "
  case "$padded" in
    *" --print "*|*" --print="*|*" -p "*)
      fail "#21 ($branch) agy must not use --print/-p (it consumes the next token as the prompt and ignores stdin): $argv" ;;
  esac
  case "$padded" in
    *" exec "*) fail "#21 ($branch) agy must not receive the 'exec' positional: $argv" ;;
  esac
  case "$padded" in
    *" - "*) fail "#21 ($branch) agy must not receive a bare '-' positional: $argv" ;;
  esac
  case "$padded" in
    *" --dangerously-skip-permissions "*) : ;;
    *) fail "#21 ($branch) agy lost --dangerously-skip-permissions: $argv" ;;
  esac
  case "$padded" in
    *" --add-dir "*) : ;;
    *) fail "#21 ($branch) agy lost --add-dir: $argv" ;;
  esac
}

# Branch 1: timeout wrapper present -> assert the command line handed to the wrapper.
: > "$TIMEOUT_ARGS_FILE"
PATH="$TMP/timeoutbin:$TMP/bin:$PATH" bash "$CD" agy "$P_to" "$TMP/prompt" "true" >/dev/null 2>&1 || true
t21_argv="$(grep -m1 -- ' agy ' "$TIMEOUT_ARGS_FILE" || true)"
assert_agy_bare_stdin "with timeout" "$t21_argv"

# Branch 2: no timeout/gtimeout on PATH -> coding-dispatch invokes agy directly, so record
# agy's OWN argv. A stub that merely exits would prove nothing; this one reports what it got.
export AGY_INVOKE_FILE="$TMP/agy-invoke-args"
: > "$AGY_INVOKE_FILE"
cat > "$TMP/bin/agy" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AGY_INVOKE_FILE"
exit 0
STUB
chmod +x "$TMP/bin/agy"
PATH="$TMP/bin:/usr/bin:/bin" bash "$CD" agy "$P_to" "$TMP/prompt" "true" >/dev/null 2>&1 || true
[ -s "$AGY_INVOKE_FILE" ] || fail "#21b no-timeout fallback never invoked agy — that branch is unasserted"
assert_agy_bare_stdin "no-timeout fallback" "$(tail -n1 "$AGY_INVOKE_FILE")"
echo "test #21 agy invocation uses bare stdin in both branches (no --print/exec/bare-dash) PASS"

# #53: mutation markers fail before build for tracked added lines and untracked files.
P_mut="$TMP/mut_parent"; new_parent "$P_mut"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
wd=""; while [ $# -gt 0 ]; do [ "$1" = "-C" ] && { wd="$2"; shift 2; continue; }; shift; done
: "${wd:=$PWD}"; printf '%s\n' 'x := 1 // MUT: collide' >> "$wd/tracked.txt"
STUB
chmod +x "$TMP/bin/codex"
bash "$CD" codex "$P_mut" "$TMP/prompt" "true" >"$TMP/out_mut_tracked" 2>&1; rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out_mut_tracked"; fail "#53 tracked mutation marker should fail rc 1, got $rc"; }
grep -q "mutation marker" "$TMP/out_mut_tracked" || { cat "$TMP/out_mut_tracked"; fail "#53 tracked mutation marker message missing"; }
[ -z "$(git -C "$P_mut" status --porcelain)" ] || fail "#53 tracked mutation marker should revert non-worktree tree"
P_mut_u="$TMP/mut_untracked_parent"; new_parent "$P_mut_u"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
wd=""; while [ $# -gt 0 ]; do [ "$1" = "-C" ] && { wd="$2"; shift 2; continue; }; shift; done
: "${wd:=$PWD}"; printf '%s\n' '# MUT: untracked sentinel' > "$wd/new_mutation.py"
STUB
chmod +x "$TMP/bin/codex"
bash "$CD" codex "$P_mut_u" "$TMP/prompt" "true" >"$TMP/out_mut_untracked" 2>&1; rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out_mut_untracked"; fail "#53 untracked mutation marker should fail rc 1, got $rc"; }
grep -q "mutation marker" "$TMP/out_mut_untracked" || { cat "$TMP/out_mut_untracked"; fail "#53 untracked mutation marker message missing"; }
[ -z "$(git -C "$P_mut_u" status --porcelain)" ] || fail "#53 untracked mutation marker should clean non-worktree tree"
P_mut_w="$TMP/mut_worktree_parent"; new_parent "$P_mut_w"
CODING_DISPATCH_WORKTREE="mutSlug" bash "$CD" --worktree codex "$P_mut_w" "$TMP/prompt" "true" >"$TMP/out_mut_wt" 2>&1; rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out_mut_wt"; fail "#53 worktree mutation marker should fail rc 1, got $rc"; }
grep -q "mutation marker" "$TMP/out_mut_wt" || { cat "$TMP/out_mut_wt"; fail "#53 worktree mutation marker message missing"; }
WTM="$(expected_wt "$P_mut_w" mutSlug)"
[ -d "$WTM" ] || fail "#53 worktree mutation failure should salvage the worktree"
[ -f "$WTM/new_mutation.py" ] || fail "#53 worktree mutation failure should leave sentinel file for salvage"
git -C "$P_mut_w" worktree remove --force "$WTM" 2>/dev/null || true
P_perm="$TMP/permutation_parent"; new_parent "$P_perm"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
wd=""; while [ $# -gt 0 ]; do [ "$1" = "-C" ] && { wd="$2"; shift 2; continue; }; shift; done
: "${wd:=$PWD}"; printf '%s\n' 'normal permutation logic with MUTEX wording' > "$wd/permutation.txt"
STUB
chmod +x "$TMP/bin/codex"
bash "$CD" codex "$P_perm" "$TMP/prompt" "true" >"$TMP/out_perm" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out_perm"; fail "#53 permutation/MUTEX non-regression (untracked) should pass, got $rc"; }
# tracked-diff non-regression: benign permutation/MUTEX text APPENDED to a committed file (exercises the git-diff scan branch, not just the untracked scan)
P_perm_t="$TMP/permutation_tracked_parent"; new_parent "$P_perm_t"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
wd=""; while [ $# -gt 0 ]; do [ "$1" = "-C" ] && { wd="$2"; shift 2; continue; }; shift; done
: "${wd:=$PWD}"; printf '%s\n' 'normal permutation logic with MUTEX wording' >> "$wd/tracked.txt"
STUB
chmod +x "$TMP/bin/codex"
bash "$CD" codex "$P_perm_t" "$TMP/prompt" "true" >"$TMP/out_perm_t" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out_perm_t"; fail "#53 permutation/MUTEX non-regression (tracked-diff) should pass, got $rc"; }
echo "test #53 mutation marker guard PASS"

# ============================ #118: pre-revert patch snapshot + --keep-on-fail ============================

# (A1) failing gate, UNCOMMITTED shape: patch file is non-empty and its path is printed;
# without --keep-on-fail the tree is still reverted.
P_patchA="$TMP/patch_uncommitted_parent"; new_parent "$P_patchA"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
wd=""; while [ $# -gt 0 ]; do [ "$1" = "-C" ] && { wd="$2"; shift 2; continue; }; shift; done
: "${wd:=$PWD}"; echo "uncommitted change" > "$wd/agent_made_this.txt"
STUB
chmod +x "$TMP/bin/codex"
bash "$CD" codex "$P_patchA" "$TMP/prompt" "false" >"$TMP/out_patchA" 2>&1; rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out_patchA"; fail "#118 patch test (uncommitted) failing gate should exit 1, got $rc"; }
# The patch is stashed inside .git/ on EVERY path (invisible to `git status`, never in the
# working tree — see coding-dispatch.sh report_fail comment).
PATCH_A="$(git -C "$P_patchA" rev-parse --absolute-git-dir)/coding-dispatch-last-fail.patch"
[ -s "$PATCH_A" ] || fail "#118 patch file missing or empty (uncommitted shape): $PATCH_A"
grep -q "agent_made_this.txt" "$PATCH_A" || fail "#118 patch file (uncommitted) should contain the agent's change"
grep -qF "$PATCH_A" "$TMP/out_patchA" || { cat "$TMP/out_patchA"; fail "#118 fail message should print the patch path (uncommitted shape)"; }
[ -z "$(git -C "$P_patchA" status --porcelain)" ] || fail "#118 without --keep-on-fail the tree should still be reverted"
echo "test #118 pre-revert patch snapshot (uncommitted shape) PASS"

# (A2) failing gate, COMMITTED/TDD shape: the worker commits per-task AND leaves the marker
# uncommitted (the real per-task TDD contract — see the "stray commit" comment in
# coding-dispatch.sh: without the uncommitted marker this is indistinguishable from a stray
# self-commit and gets soft-reset instead). A bare `git diff` would show nothing for the
# committed part — the patch must be captured via `git diff "$BASE"` to cover it.
P_patchB="$TMP/patch_committed_parent"; new_parent "$P_patchB"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
wd=""; while [ $# -gt 0 ]; do [ "$1" = "-C" ] && { wd="$2"; shift 2; continue; }; shift; done
: "${wd:=$PWD}"
echo "committed change" > "$wd/agent_made_this.txt"
git -C "$wd" add -A
git -C "$wd" commit -qm "tdd task commit"
printf '{"status":"complete","files_written":["agent_made_this.txt"],"timestamp":"2026-01-01T00:00:00Z"}\n' > "$wd/_coding-result.json"
STUB
chmod +x "$TMP/bin/codex"
bash "$CD" codex "$P_patchB" "$TMP/prompt" "false" >"$TMP/out_patchB" 2>&1; rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out_patchB"; fail "#118 patch test (TDD/committed) failing gate should exit 1, got $rc"; }
PATCH_B="$(git -C "$P_patchB" rev-parse --absolute-git-dir)/coding-dispatch-last-fail.patch"
[ ! -e "$P_patchB/.coding-dispatch-last-fail.patch" ] || fail "TDD/committed salvage must not leave the patch in the working tree"
[ ! -e "$P_patchB/coding-dispatch-last-fail.patch" ] || fail "TDD/committed salvage must not leave the patch in the working tree"
[ ! -e "$P_patchB/_coding-result.json" ] || fail "TDD/committed salvage must not leave the scratch marker in the working tree"
[ -s "$PATCH_B" ] || fail "#118 patch file missing or empty (TDD/committed shape): $PATCH_B — a bare 'git diff' would show nothing for committed work"
grep -q "agent_made_this.txt" "$PATCH_B" || fail "#118 patch file (TDD/committed) should contain the committed change"
grep -q "TDD commits SALVAGED" "$TMP/out_patchB" || { cat "$TMP/out_patchB"; fail "#118 TDD-mode fail message should still say SALVAGED (commits must NOT be reverted)"; }
grep -qF "$PATCH_B" "$TMP/out_patchB" || { cat "$TMP/out_patchB"; fail "#118 fail message should print the patch path (TDD/committed shape)"; }
echo "test #118 pre-revert patch snapshot (TDD/committed shape) PASS"

# (A3) --keep-on-fail skips the revert entirely and leaves the tree intact.
P_keep="$TMP/keep_on_fail_parent"; new_parent "$P_keep"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
wd=""; while [ $# -gt 0 ]; do [ "$1" = "-C" ] && { wd="$2"; shift 2; continue; }; shift; done
: "${wd:=$PWD}"; echo "keep me" > "$wd/agent_made_this.txt"
STUB
chmod +x "$TMP/bin/codex"
bash "$CD" --keep-on-fail codex "$P_keep" "$TMP/prompt" "false" >"$TMP/out_keep" 2>&1; rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out_keep"; fail "#118 --keep-on-fail failing gate should still exit 1, got $rc"; }
[ -f "$P_keep/agent_made_this.txt" ] || fail "#118 --keep-on-fail should leave the agent's file (no revert)"
grep -q "keep-on-fail" "$TMP/out_keep" || { cat "$TMP/out_keep"; fail "#118 --keep-on-fail fail message should mention keep-on-fail"; }
# FINDING 2: the patch-capture must not leave a mutated index behind. `report_fail` used to run
# a bare `git add -N -A .` against the REAL index to make the untracked file visible to
# `git diff "$BASE"`, which permanently flips the file's status from `?? file` to ` A file` on
# every salvage path (this one included) — breaking the --keep-on-fail promise to leave the tree
# EXACTLY as the agent left it, and changing the `git status` shape scripts/agents parse.
[ "$(git -C "$P_keep" status --porcelain -- agent_made_this.txt)" = "?? agent_made_this.txt" ] || fail "FINDING2 --keep-on-fail must leave a pristine index: untracked file should stay '?? agent_made_this.txt', got: $(git -C "$P_keep" status --porcelain -- agent_made_this.txt)"
git -C "$P_keep" reset --hard -q HEAD >/dev/null 2>&1; git -C "$P_keep" clean -fdq >/dev/null 2>&1   # test cleanup only
echo "test #118 --keep-on-fail leaves tree intact PASS"

# ============================ #128a: slow-gate timeout warning + rc=124 TIMEOUT wording ============================

# (B1) a slow --build-cmd under the still-default timeout emits a WARNING naming the env var.
P_slow="$TMP/slow_gate_parent"; new_parent "$P_slow"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP/bin/codex"
bash "$CD" codex "$P_slow" "$TMP/prompt" "make test" >"$TMP/out_slow" 2>&1
grep -q "WARNING" "$TMP/out_slow" || { cat "$TMP/out_slow"; fail "#128a slow --build-cmd under default timeout should print a WARNING"; }
grep -q "CODING_DISPATCH_TIMEOUT" "$TMP/out_slow" || { cat "$TMP/out_slow"; fail "#128a warning should name CODING_DISPATCH_TIMEOUT"; }
echo "test #128a slow-gate warning fires under default timeout PASS"

# (B2) the warning does NOT fire once CODING_DISPATCH_TIMEOUT is raised explicitly.
P_slow2="$TMP/slow_gate_explicit_parent"; new_parent "$P_slow2"
CODING_DISPATCH_TIMEOUT=30m bash "$CD" codex "$P_slow2" "$TMP/prompt" "make test" >"$TMP/out_slow2" 2>&1
! grep -q "WARNING" "$TMP/out_slow2" || { cat "$TMP/out_slow2"; fail "#128a warning should NOT fire when CODING_DISPATCH_TIMEOUT is explicitly set"; }
echo "test #128a slow-gate warning suppressed when timeout explicit PASS"

# (B3) rc=124 (the external timeout tripped) must say TIMEOUT explicitly and name the cap,
# never a generic empty-diff fail.
mkdir -p "$TMP/timeoutbin2"
printf '#!/usr/bin/env bash\nexit 124\n' > "$TMP/timeoutbin2/timeout"; chmod +x "$TMP/timeoutbin2/timeout"
P_rc124="$TMP/rc124_parent"; new_parent "$P_rc124"
PATH="$TMP/timeoutbin2:$TMP/bin:$PATH" bash "$CD" codex "$P_rc124" "$TMP/prompt" "true" >"$TMP/out_rc124" 2>&1; rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out_rc124"; fail "#128a rc=124 should still fail (dispatch exit-1 contract), got $rc"; }
grep -q "TIMEOUT" "$TMP/out_rc124" || { cat "$TMP/out_rc124"; fail "#128a rc=124 fail message must say TIMEOUT explicitly"; }
grep -qi "15m\|CODING_DISPATCH_TIMEOUT" "$TMP/out_rc124" || { cat "$TMP/out_rc124"; fail "#128a TIMEOUT message should name the cap that was hit"; }
! grep -q "empty diff (agent changed nothing" "$TMP/out_rc124" || { cat "$TMP/out_rc124"; fail "#128a rc=124 must not surface as a generic empty-diff fail"; }
echo "test #128a rc=124 fail message says TIMEOUT and names the cap PASS"

# ============================ #128b: DISPATCH=ok-noop marker ============================

# Real repos gitignore _coding-result.json (so git status never sees it) — reproduce that here,
# since the whole bug is that the marker is invisible to the empty-diff check.
new_parent_gitignoring_marker() {
  local p="$1"; mkdir -p "$p"; git -C "$p" init -q
  git -C "$p" config user.email t@t; git -C "$p" config user.name t
  echo base > "$p/tracked.txt"
  echo "_coding-result.json" > "$p/.gitignore"
  git -C "$p" add -A; git -C "$p" commit -qm base
}

# (C1) legitimate no-op: rc=0, empty diff, but a present+parseable marker ⇒ DISPATCH=ok-noop, exit 0.
P_noop="$TMP/legit_noop_parent"; new_parent_gitignoring_marker "$P_noop"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
wd=""; while [ $# -gt 0 ]; do [ "$1" = "-C" ] && { wd="$2"; shift 2; continue; }; shift; done
: "${wd:=$PWD}"
printf '{"status":"complete","files_written":[],"timestamp":"2026-01-01T00:00:00Z"}\n' > "$wd/_coding-result.json"
STUB
chmod +x "$TMP/bin/codex"
bash "$CD" codex "$P_noop" "$TMP/prompt" "true" >"$TMP/out_noop" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out_noop"; fail "#128b legit no-op (gitignored marker, rc=0, valid marker) should exit 0, got $rc"; }
grep -q "DISPATCH=ok-noop" "$TMP/out_noop" || { cat "$TMP/out_noop"; fail "#128b legit no-op should emit DISPATCH=ok-noop"; }
echo "test #128b DISPATCH=ok-noop on legitimate no-op PASS"

# (C2) genuine rc=0 failure with NO marker file must still fail (not be mistaken for ok-noop).
P_genuine="$TMP/genuine_fail_parent"; new_parent_gitignoring_marker "$P_genuine"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/codex"; chmod +x "$TMP/bin/codex"
bash "$CD" codex "$P_genuine" "$TMP/prompt" "true" >"$TMP/out_genuine" 2>&1; rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out_genuine"; fail "#128b genuine no-marker failure should still exit 1, got $rc"; }
grep -q "DISPATCH=fail" "$TMP/out_genuine" || { cat "$TMP/out_genuine"; fail "#128b genuine failure should emit DISPATCH=fail"; }
! grep -q "ok-noop" "$TMP/out_genuine" || { cat "$TMP/out_genuine"; fail "#128b genuine failure must NOT be marked ok-noop"; }
echo "test #128b DISPATCH=fail still on genuine rc=0 no-marker failure PASS"

# ============================ FINDING 1: legit TDD commit + gitignored marker must NOT be
# unwound as a "stray commit" ============================
# _coding-result.json is gitignored in every real caller repo (see new_parent_gitignoring_marker
# above / #128b), so a worker that commits per task AND leaves the marker produces a byte-clean
# `git status` with HEAD moved off BASE — the exact shape the "stray self-commit" branch used to
# unwind unconditionally via `git reset --soft`. The completion marker (parsed into
# $marker_status independently of git's view of the tree) must gate that decision: present +
# parseable + complete ⇒ legitimate TDD, do not unwind.
P_tdd="$TMP/tdd_legit_parent"; new_parent_gitignoring_marker "$P_tdd"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
wd=""; while [ $# -gt 0 ]; do [ "$1" = "-C" ] && { wd="$2"; shift 2; continue; }; shift; done
: "${wd:=$PWD}"
echo "tdd committed change" > "$wd/tdd_task.txt"
git -C "$wd" add -A
git -C "$wd" commit -qm "tdd task commit"
printf '{"status":"complete","files_written":["tdd_task.txt"],"timestamp":"2026-01-01T00:00:00Z"}\n' > "$wd/_coding-result.json"
STUB
chmod +x "$TMP/bin/codex"
before_head="$(git -C "$P_tdd" rev-parse HEAD)"
bash "$CD" codex "$P_tdd" "$TMP/prompt" "true" >"$TMP/out_tdd_legit" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out_tdd_legit"; fail "FINDING1 legit TDD commit + gitignored marker should exit 0, got $rc"; }
after_head="$(git -C "$P_tdd" rev-parse HEAD)"
[ "$after_head" != "$before_head" ] || fail "FINDING1 the TDD commit should still be at HEAD (must not be unwound)"
[ "$(git -C "$P_tdd" rev-list --count "$before_head".."$after_head")" -eq 1 ] || fail "FINDING1 exactly one TDD commit should remain on top of BASE (a soft-reset would collapse it away)"
git -C "$P_tdd" log -1 --format=%s "$after_head" | grep -q "tdd task commit" || fail "FINDING1 the original TDD commit message must be preserved"
! grep -q "stray commit" "$TMP/out_tdd_legit" || { cat "$TMP/out_tdd_legit"; fail "FINDING1 legitimate TDD commit must not be reported/treated as a stray commit"; }
echo "test FINDING1 legitimate TDD commit with gitignored marker is not unwound PASS"

# FINDING1 regression guard: a GENUINE stray self-commit (worker committed without being asked,
# no marker at all) must still be unwound exactly as before — the marker gate must not weaken
# the existing stray-commit protection.
P_stray="$TMP/stray_commit_parent"; new_parent "$P_stray"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
wd=""; while [ $# -gt 0 ]; do [ "$1" = "-C" ] && { wd="$2"; shift 2; continue; }; shift; done
: "${wd:=$PWD}"
echo "stray change" > "$wd/stray.txt"
git -C "$wd" add -A
git -C "$wd" commit -qm "oops committed without being asked"
STUB
chmod +x "$TMP/bin/codex"
before_head="$(git -C "$P_stray" rev-parse HEAD)"
bash "$CD" codex "$P_stray" "$TMP/prompt" "true" >"$TMP/out_stray" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out_stray"; fail "FINDING1-regression stray commit (no marker) should still complete via synthesized marker, got rc=$rc"; }
[ "$(git -C "$P_stray" rev-parse HEAD)" = "$before_head" ] || fail "FINDING1-regression a genuine stray self-commit (no marker) must still be unwound (soft-reset) onto BASE"
grep -q "stray commit" "$TMP/out_stray" || { cat "$TMP/out_stray"; fail "FINDING1-regression genuine stray commit should still be reported as such"; }
[ -f "$P_stray/stray.txt" ] || fail "FINDING1-regression the stray content should survive as an uncommitted change after unwinding"
git -C "$P_stray" reset --hard -q HEAD >/dev/null 2>&1; git -C "$P_stray" clean -fdq >/dev/null 2>&1   # test cleanup only
echo "test FINDING1-regression genuine stray commit (no marker) still unwound PASS"

# ============================ FINDING 3 + 4: --worktree report_fail patch survives
# CODING_DISPATCH_RM_ON_FAIL, in both settings ============================
P_wtfail0="$TMP/wt_fail_rm0_parent"; new_parent "$P_wtfail0"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
wd=""; while [ $# -gt 0 ]; do [ "$1" = "-C" ] && { wd="$2"; shift 2; continue; }; shift; done
: "${wd:=$PWD}"; echo "wt fail change" > "$wd/wt_fail.txt"
STUB
chmod +x "$TMP/bin/codex"
CODING_DISPATCH_WORKTREE="slugFailRM0" bash "$CD" --worktree codex "$P_wtfail0" "$TMP/prompt" "false" >"$TMP/out_wtfail_rm0" 2>&1; rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out_wtfail_rm0"; fail "FINDING4 --worktree report_fail RM_ON_FAIL=0 should exit 1, got $rc"; }
WT_FAIL0="$(expected_wt "$P_wtfail0" slugFailRM0)"
[ -d "$WT_FAIL0" ] || fail "FINDING4 --worktree report_fail RM_ON_FAIL=0 should salvage (leave) the worktree"
PATCH_WT0="$(git -C "$WT_FAIL0" rev-parse --absolute-git-dir)/coding-dispatch-last-fail.patch"
[ ! -e "$WT_FAIL0/.coding-dispatch-last-fail.patch" ] || fail "worktree salvage must not leave the patch in the worktree's working tree"
[ ! -e "$WT_FAIL0/coding-dispatch-last-fail.patch" ] || fail "worktree salvage must not leave the patch in the worktree's working tree"
[ -s "$PATCH_WT0" ] || fail "FINDING4 --worktree report_fail RM_ON_FAIL=0 patch missing or empty: $PATCH_WT0"
grep -q "wt_fail.txt" "$PATCH_WT0" || fail "FINDING4 --worktree RM_ON_FAIL=0 patch should contain the agent's change"
# FINDING2 also applies to the worktree salvage path: the untracked file's status must stay `??`.
[ "$(git -C "$WT_FAIL0" status --porcelain -- wt_fail.txt)" = "?? wt_fail.txt" ] || fail "FINDING2 --worktree salvage must leave a pristine index for wt_fail.txt, got: $(git -C "$WT_FAIL0" status --porcelain -- wt_fail.txt)"
git -C "$P_wtfail0" worktree remove --force "$WT_FAIL0" 2>/dev/null || true
echo "test FINDING4 --worktree report_fail RM_ON_FAIL=0 patch retrievable + pristine index PASS"

P_wtfail1="$TMP/wt_fail_rm1_parent"; new_parent "$P_wtfail1"
# codex stub from the RM0 case above is still on PATH and still writes wt_fail.txt — reuse it.
CODING_DISPATCH_WORKTREE="slugFailRM1" CODING_DISPATCH_RM_ON_FAIL=1 bash "$CD" --worktree codex "$P_wtfail1" "$TMP/prompt" "false" >"$TMP/out_wtfail_rm1" 2>&1; rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out_wtfail_rm1"; fail "FINDING3 --worktree report_fail RM_ON_FAIL=1 should exit 1, got $rc"; }
WT_FAIL1="$(expected_wt "$P_wtfail1" slugFailRM1)"
[ ! -d "$WT_FAIL1" ] || fail "FINDING3 RM_ON_FAIL=1 should still remove the worktree"
PATCH_PATH_RM1="$(sed -n 's/.*patch survives at \(.*\)$/\1/p' "$TMP/out_wtfail_rm1" | head -1)"
[ -n "$PATCH_PATH_RM1" ] || { cat "$TMP/out_wtfail_rm1"; fail "FINDING3 RM_ON_FAIL=1 fail message should print a retrievable patch path (previously the patch was NEVER written anywhere)"; }
[ -s "$PATCH_PATH_RM1" ] || fail "FINDING3 RM_ON_FAIL=1 patch missing or empty at $PATCH_PATH_RM1"
grep -q "wt_fail.txt" "$PATCH_PATH_RM1" || fail "FINDING3 RM_ON_FAIL=1 patch should contain the agent's change"
echo "test FINDING3 --worktree report_fail RM_ON_FAIL=1 patch survives worktree removal PASS"

# ============================ FINDING 4: --worktree + ok-noop removes the worktree ============================
P_wtnoop="$TMP/wt_noop_parent"; new_parent_gitignoring_marker "$P_wtnoop"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
wd=""; while [ $# -gt 0 ]; do [ "$1" = "-C" ] && { wd="$2"; shift 2; continue; }; shift; done
: "${wd:=$PWD}"
printf '{"status":"complete","files_written":[],"timestamp":"2026-01-01T00:00:00Z"}\n' > "$wd/_coding-result.json"
STUB
chmod +x "$TMP/bin/codex"
CODING_DISPATCH_WORKTREE="slugNoopWT" bash "$CD" --worktree codex "$P_wtnoop" "$TMP/prompt" "true" >"$TMP/out_wtnoop" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out_wtnoop"; fail "FINDING4 --worktree ok-noop should exit 0, got $rc"; }
grep -q "DISPATCH=ok-noop" "$TMP/out_wtnoop" || { cat "$TMP/out_wtnoop"; fail "FINDING4 --worktree ok-noop should emit DISPATCH=ok-noop"; }
WT_NOOP="$(expected_wt "$P_wtnoop" slugNoopWT)"
[ ! -d "$WT_NOOP" ] || fail "FINDING4 --worktree ok-noop should remove the worktree directory"
git -C "$P_wtnoop" worktree list --porcelain | grep -Fq "worktree $WT_NOOP" && fail "FINDING4 --worktree ok-noop worktree must not appear in 'git worktree list'"
echo "test FINDING4 --worktree + ok-noop removes the worktree PASS"

# ============================ FINDING 5: slow-gate heuristic negative cases must NOT warn ============================
P_slowneg1="$TMP/slow_gate_neg1_parent"; new_parent "$P_slowneg1"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/codex"; chmod +x "$TMP/bin/codex"
bash "$CD" codex "$P_slowneg1" "$TMP/prompt" "go test ./... -run Foo" >"$TMP/out_slowneg1" 2>&1
! grep -q "WARNING" "$TMP/out_slowneg1" || { cat "$TMP/out_slowneg1"; fail "FINDING5 'go test ./... -run Foo' must NOT trigger the slow-gate warning"; }
echo "test FINDING5 'go test ./... -run Foo' does not warn PASS"

P_slowneg2="$TMP/slow_gate_neg2_parent"; new_parent "$P_slowneg2"
bash "$CD" codex "$P_slowneg2" "$TMP/prompt" "pytest tests/x.py::test_y" >"$TMP/out_slowneg2" 2>&1
! grep -q "WARNING" "$TMP/out_slowneg2" || { cat "$TMP/out_slowneg2"; fail "FINDING5 'pytest tests/x.py::test_y' must NOT trigger the slow-gate warning"; }
echo "test FINDING5 'pytest tests/x.py::test_y' does not warn PASS"

# ============================ ISSUE 155: gate advisory ============================
# Stub ruff and pytest to succeed
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/ruff"
chmod +x "$TMP/bin/ruff"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/pytest"
chmod +x "$TMP/bin/pytest"

# Restore codex stub that makes changes
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
wd=""; while [ $# -gt 0 ]; do [ "$1" = "-C" ] && { wd="$2"; shift 2; continue; }; shift; done
: "${wd:=$PWD}"
echo "changed line" > "$wd/agent_made_this.txt"
STUB
chmod +x "$TMP/bin/codex"

# Test 1: Makefile with lint, build-cmd ruff check . -> warns about lint and contains gate-target
P_adv1="$TMP/gate_adv1_parent"; new_parent "$P_adv1"
printf 'lint:\n\techo linting\n' > "$P_adv1/Makefile"
git -C "$P_adv1" add Makefile; git -C "$P_adv1" commit -qm "add Makefile"
bash "$CD" codex "$P_adv1" "$TMP/prompt" "ruff check ." >"$TMP/out_adv1" 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "gate advisory test 1 should exit 0, got $rc"
grep -q "gate-target" "$TMP/out_adv1" || { cat "$TMP/out_adv1"; fail "Test 1: should contain gate-target token"; }
grep -q "lint" "$TMP/out_adv1" || { cat "$TMP/out_adv1"; fail "Test 1: warning should name lint"; }
occurrences=$(grep -c "gate-target" "$TMP/out_adv1")
[ "$occurrences" -eq 1 ] || fail "Test 1: should have exactly one warning, got $occurrences"
echo "test gate advisory 1 (warning printed once for skipped lint target) PASS"

# Test 2: Load-bearing negative: exit status is unchanged
P_adv2_with="$TMP/gate_adv2_with"; new_parent "$P_adv2_with"
printf 'lint:\n\techo linting\n' > "$P_adv2_with/Makefile"
git -C "$P_adv2_with" add Makefile; git -C "$P_adv2_with" commit -qm "add Makefile"
bash "$CD" codex "$P_adv2_with" "$TMP/prompt" "false" >"$TMP/out_adv2_with" 2>&1; rc_with=$?

P_adv2_without="$TMP/gate_adv2_without"; new_parent "$P_adv2_without"
bash "$CD" codex "$P_adv2_without" "$TMP/prompt" "false" >"$TMP/out_adv2_without" 2>&1; rc_without=$?

# The comparison only means anything if the advisory actually fired in the "with"
# arm. Without this assertion the test passes identically whether or not the
# feature exists at all — it would be comparing two runs that both did nothing.
grep -q "gate-target" "$TMP/out_adv2_with" || { cat "$TMP/out_adv2_with"; fail "Test 2: the 'with Makefile' arm must actually emit the advisory, or the exit-status comparison proves nothing"; }
! grep -q "gate-target" "$TMP/out_adv2_without" || { cat "$TMP/out_adv2_without"; fail "Test 2: the 'without Makefile' arm must not emit the advisory"; }
[ "$rc_with" -eq "$rc_without" ] || fail "Test 2: exit status with and without Makefile on failing build must be identical, got $rc_with vs $rc_without"
echo "test gate advisory 2 (exit status unchanged) PASS"

# Test 3: Build-cmd make lint -> silent
P_adv3="$TMP/gate_adv3_parent"; new_parent "$P_adv3"
printf 'lint:\n\techo linting\n' > "$P_adv3/Makefile"
git -C "$P_adv3" add Makefile; git -C "$P_adv3" commit -qm "add Makefile"
bash "$CD" codex "$P_adv3" "$TMP/prompt" "make lint" >"$TMP/out_adv3" 2>&1
! grep -q "gate-target" "$TMP/out_adv3" || { cat "$TMP/out_adv3"; fail "Test 3: build-cmd 'make lint' must be silent"; }
echo "test gate advisory 3 (build-cmd 'make lint' is silent) PASS"

# Test 4: No makefile in the workdir -> silent
P_adv4="$TMP/gate_adv4_parent"; new_parent "$P_adv4"
bash "$CD" codex "$P_adv4" "$TMP/prompt" "ruff check ." >"$TMP/out_adv4" 2>&1
! grep -q "gate-target" "$TMP/out_adv4" || { cat "$TMP/out_adv4"; fail "Test 4: no makefile must be silent"; }
echo "test gate advisory 4 (no makefile is silent) PASS"

# Test 5: Makefile with only non-gate targets (install, fmt) -> silent
P_adv5="$TMP/gate_adv5_parent"; new_parent "$P_adv5"
printf 'install:\n\techo install\nfmt:\n\techo fmt\n' > "$P_adv5/Makefile"
git -C "$P_adv5" add Makefile; git -C "$P_adv5" commit -qm "add Makefile"
bash "$CD" codex "$P_adv5" "$TMP/prompt" "ruff check ." >"$TMP/out_adv5" 2>&1
! grep -q "gate-target" "$TMP/out_adv5" || { cat "$TMP/out_adv5"; fail "Test 5: makefile with non-gate targets must be silent"; }
echo "test gate advisory 5 (non-gate targets is silent) PASS"

# Test 6: The parsing trap: LINT := ruff -> silent
P_adv6="$TMP/gate_adv6_parent"; new_parent "$P_adv6"
printf 'LINT := ruff\n' > "$P_adv6/Makefile"
git -C "$P_adv6" add Makefile; git -C "$P_adv6" commit -qm "add Makefile"
bash "$CD" codex "$P_adv6" "$TMP/prompt" "ruff check ." >"$TMP/out_adv6" 2>&1
! grep -q "gate-target" "$TMP/out_adv6" || { cat "$TMP/out_adv6"; fail "Test 6: variable assignment must not be parsed as a target"; }
echo "test gate advisory 6 (variable assignment trap is silent) PASS"

# Test 7: pr-ready and lint both present -> priority order
P_adv7="$TMP/gate_adv7_parent"; new_parent "$P_adv7"
printf 'lint:\n\techo linting\npr-ready:\n\techo pr-ready\n' > "$P_adv7/Makefile"
git -C "$P_adv7" add Makefile; git -C "$P_adv7" commit -qm "add Makefile"
bash "$CD" codex "$P_adv7" "$TMP/prompt" "ruff check ." >"$TMP/out_adv7" 2>&1
grep -q "pr-ready lint" "$TMP/out_adv7" || { cat "$TMP/out_adv7"; fail "Test 7: targets must be listed in priority order 'pr-ready lint'"; }
echo "test gate advisory 7 (priority order) PASS"

# Test 8: Deduplication on consecutive runs -> second is silent
P_adv8="$TMP/gate_adv8_parent"; new_parent "$P_adv8"
printf 'lint:\n\techo linting\n' > "$P_adv8/Makefile"
git -C "$P_adv8" add Makefile; git -C "$P_adv8" commit -qm "add Makefile"
bash "$CD" codex "$P_adv8" "$TMP/prompt" "ruff check ." >"$TMP/out_adv8_1" 2>&1
grep -q "gate-target" "$TMP/out_adv8_1" || { cat "$TMP/out_adv8_1"; fail "Test 8: first dispatch must warn"; }
git -C "$P_adv8" reset --hard HEAD -q && git -C "$P_adv8" clean -fdq
bash "$CD" codex "$P_adv8" "$TMP/prompt" "ruff check ." >"$TMP/out_adv8_2" 2>&1
! grep -q "gate-target" "$TMP/out_adv8_2" || { cat "$TMP/out_adv8_2"; fail "Test 8: second consecutive dispatch must be silent"; }
echo "test gate advisory 8 (deduplication on consecutive runs) PASS"

# Test 9: Deduplication does not over-suppress different command
P_adv9="$TMP/gate_adv9_parent"; new_parent "$P_adv9"
printf 'lint:\n\techo linting\n' > "$P_adv9/Makefile"
git -C "$P_adv9" add Makefile; git -C "$P_adv9" commit -qm "add Makefile"
bash "$CD" codex "$P_adv9" "$TMP/prompt" "ruff check ." >"$TMP/out_adv9_1" 2>&1
grep -q "gate-target" "$TMP/out_adv9_1" || { cat "$TMP/out_adv9_1"; fail "Test 9: first dispatch must warn"; }
git -C "$P_adv9" reset --hard HEAD -q && git -C "$P_adv9" clean -fdq
bash "$CD" codex "$P_adv9" "$TMP/prompt" "pytest" >"$TMP/out_adv9_2" 2>&1
grep -q "gate-target" "$TMP/out_adv9_2" || { cat "$TMP/out_adv9_2"; fail "Test 9: second dispatch with different command must warn again"; }
echo "test gate advisory 9 (different build-cmd re-warns) PASS"

# Test 10: DISPATCH_GATE_ADVISORY_TTL_SECS=0 warns on every run
P_adv10="$TMP/gate_adv10_parent"; new_parent "$P_adv10"
printf 'lint:\n\techo linting\n' > "$P_adv10/Makefile"
git -C "$P_adv10" add Makefile; git -C "$P_adv10" commit -qm "add Makefile"
DISPATCH_GATE_ADVISORY_TTL_SECS=0 bash "$CD" codex "$P_adv10" "$TMP/prompt" "ruff check ." >"$TMP/out_adv10_1" 2>&1
grep -q "gate-target" "$TMP/out_adv10_1" || { cat "$TMP/out_adv10_1"; fail "Test 10: first dispatch must warn"; }
git -C "$P_adv10" reset --hard HEAD -q && git -C "$P_adv10" clean -fdq
DISPATCH_GATE_ADVISORY_TTL_SECS=0 bash "$CD" codex "$P_adv10" "$TMP/prompt" "ruff check ." >"$TMP/out_adv10_2" 2>&1
grep -q "gate-target" "$TMP/out_adv10_2" || { cat "$TMP/out_adv10_2"; fail "Test 10: second dispatch with TTL=0 must warn again"; }
echo "test gate advisory 10 (TTL=0 disables suppression) PASS"

# Test 11: Warning goes to stderr, not stdout
P_adv11="$TMP/gate_adv11_parent"; new_parent "$P_adv11"
printf 'lint:\n\techo linting\n' > "$P_adv11/Makefile"
git -C "$P_adv11" add Makefile; git -C "$P_adv11" commit -qm "add Makefile"
bash "$CD" codex "$P_adv11" "$TMP/prompt" "ruff check ." >"$TMP/out_adv11_stdout" 2>"$TMP/out_adv11_stderr"
! grep -q "gate-target" "$TMP/out_adv11_stdout" || fail "Test 11: warning must not go to stdout"
grep -q "gate-target" "$TMP/out_adv11_stderr" || fail "Test 11: warning must go to stderr"
echo "test gate advisory 11 (warning goes to stderr) PASS"

# ============================ ISSUE 169: script-shaped gate advisory ============================
# Test 1: Runner detected, build-cmd skips it -> exactly one advisory naming bin/run-tests.sh
P_adv169_1="$TMP/gate_adv169_1_parent"; new_parent "$P_adv169_1"
mkdir -p "$P_adv169_1/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$P_adv169_1/bin/run-tests.sh"
git -C "$P_adv169_1" add bin/run-tests.sh; git -C "$P_adv169_1" commit -qm "add runner"
bash "$CD" codex "$P_adv169_1" "$TMP/prompt" "ruff check ." >"$TMP/out_adv169_1" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out_adv169_1"; fail "Issue 169 Test 1: should exit 0, got $rc"; }
grep -q "gate-target" "$TMP/out_adv169_1" || { cat "$TMP/out_adv169_1"; fail "Issue 169 Test 1: should contain gate-target token"; }
grep -q "bin/run-tests.sh" "$TMP/out_adv169_1" || { cat "$TMP/out_adv169_1"; fail "Issue 169 Test 1: warning should name bin/run-tests.sh"; }
occurrences=$(grep -c "gate-target" "$TMP/out_adv169_1")
[ "$occurrences" -eq 1 ] || fail "Issue 169 Test 1: should have exactly one advisory, got $occurrences"
echo "test issue 169 gate advisory 1 (runner warning printed once) PASS"

# Test 2: Exit status is unchanged with and without the runner present.
P_adv169_2_with="$TMP/gate_adv169_2_with"; new_parent "$P_adv169_2_with"
mkdir -p "$P_adv169_2_with/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$P_adv169_2_with/bin/run-tests.sh"
git -C "$P_adv169_2_with" add bin/run-tests.sh; git -C "$P_adv169_2_with" commit -qm "add runner"
bash "$CD" codex "$P_adv169_2_with" "$TMP/prompt" "false" >"$TMP/out_adv169_2_with" 2>&1; rc_with=$?

P_adv169_2_without="$TMP/gate_adv169_2_without"; new_parent "$P_adv169_2_without"
bash "$CD" codex "$P_adv169_2_without" "$TMP/prompt" "false" >"$TMP/out_adv169_2_without" 2>&1; rc_without=$?

grep -q "gate-target" "$TMP/out_adv169_2_with" || { cat "$TMP/out_adv169_2_with"; fail "Issue 169 Test 2: the 'with runner' arm must actually emit the advisory, or the exit-status comparison proves nothing"; }
! grep -q "gate-target" "$TMP/out_adv169_2_without" || { cat "$TMP/out_adv169_2_without"; fail "Issue 169 Test 2: the 'without runner' arm must not emit the advisory"; }
[ "$rc_with" -eq "$rc_without" ] || fail "Issue 169 Test 2: exit status with and without runner on failing build must be identical, got $rc_with vs $rc_without"
echo "test issue 169 gate advisory 2 (exit status unchanged) PASS"

# Test 3: Build-cmd references run-tests.sh -> silent
P_adv169_3="$TMP/gate_adv169_3_parent"; new_parent "$P_adv169_3"
mkdir -p "$P_adv169_3/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$P_adv169_3/bin/run-tests.sh"
git -C "$P_adv169_3" add bin/run-tests.sh; git -C "$P_adv169_3" commit -qm "add runner"
bash "$CD" codex "$P_adv169_3" "$TMP/prompt" "bash bin/run-tests.sh" >"$TMP/out_adv169_3" 2>&1
! grep -q "gate-target" "$TMP/out_adv169_3" || { cat "$TMP/out_adv169_3"; fail "Issue 169 Test 3: build-cmd referencing run-tests.sh must be silent"; }
echo "test issue 169 gate advisory 3 (build-cmd references runner is silent) PASS"

# Test 4: No makefile and no runner -> silent
P_adv169_4="$TMP/gate_adv169_4_parent"; new_parent "$P_adv169_4"
bash "$CD" codex "$P_adv169_4" "$TMP/prompt" "ruff check ." >"$TMP/out_adv169_4" 2>&1
! grep -q "gate-target" "$TMP/out_adv169_4" || { cat "$TMP/out_adv169_4"; fail "Issue 169 Test 4: no makefile and no runner must be silent"; }
echo "test issue 169 gate advisory 4 (no makefile and no runner is silent) PASS"

# Test 5: Regression pin for the runner-only shape: no Makefile, bin/run-tests.sh present, skipped -> warns
P_adv169_5="$TMP/gate_adv169_5_parent"; new_parent "$P_adv169_5"
mkdir -p "$P_adv169_5/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$P_adv169_5/bin/run-tests.sh"
git -C "$P_adv169_5" add bin/run-tests.sh; git -C "$P_adv169_5" commit -qm "add runner"
[ ! -f "$P_adv169_5/Makefile" ] || fail "Issue 169 Test 5 fixture must not have a Makefile"
bash "$CD" codex "$P_adv169_5" "$TMP/prompt" "ruff check ." >"$TMP/out_adv169_5" 2>&1
grep -q "gate-target" "$TMP/out_adv169_5" || { cat "$TMP/out_adv169_5"; fail "Issue 169 Test 5: runner-only repo must warn"; }
grep -q "bin/run-tests.sh" "$TMP/out_adv169_5" || { cat "$TMP/out_adv169_5"; fail "Issue 169 Test 5: warning should name bin/run-tests.sh"; }
echo "test issue 169 gate advisory 5 (runner-only repo warns) PASS"

# Test 6: Makefile gate target plus runner, build-cmd skips both -> one advisory names both
P_adv169_6="$TMP/gate_adv169_6_parent"; new_parent "$P_adv169_6"
mkdir -p "$P_adv169_6/bin"
printf 'lint:\n\techo linting\n' > "$P_adv169_6/Makefile"
printf '#!/usr/bin/env bash\nexit 0\n' > "$P_adv169_6/bin/run-tests.sh"
git -C "$P_adv169_6" add Makefile bin/run-tests.sh; git -C "$P_adv169_6" commit -qm "add gates"
bash "$CD" codex "$P_adv169_6" "$TMP/prompt" "ruff check ." >"$TMP/out_adv169_6" 2>&1
grep -q "gate-target" "$TMP/out_adv169_6" || { cat "$TMP/out_adv169_6"; fail "Issue 169 Test 6: combined skipped gates must warn"; }
grep -q "lint bin/run-tests.sh" "$TMP/out_adv169_6" || { cat "$TMP/out_adv169_6"; fail "Issue 169 Test 6: warning should name lint and bin/run-tests.sh in one advisory"; }
occurrences=$(grep -c "gate-target" "$TMP/out_adv169_6")
[ "$occurrences" -eq 1 ] || fail "Issue 169 Test 6: should have exactly one advisory, got $occurrences"
echo "test issue 169 gate advisory 6 (combined makefile and runner warning) PASS"

# Test 7: TTL/dedupe still holds for runner-only case
P_adv169_7="$TMP/gate_adv169_7_parent"; new_parent "$P_adv169_7"
mkdir -p "$P_adv169_7/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$P_adv169_7/bin/run-tests.sh"
git -C "$P_adv169_7" add bin/run-tests.sh; git -C "$P_adv169_7" commit -qm "add runner"
bash "$CD" codex "$P_adv169_7" "$TMP/prompt" "ruff check ." >"$TMP/out_adv169_7_1" 2>&1
grep -q "gate-target" "$TMP/out_adv169_7_1" || { cat "$TMP/out_adv169_7_1"; fail "Issue 169 Test 7: first runner-only dispatch must warn"; }
git -C "$P_adv169_7" reset --hard HEAD -q && git -C "$P_adv169_7" clean -fdq
bash "$CD" codex "$P_adv169_7" "$TMP/prompt" "ruff check ." >"$TMP/out_adv169_7_2" 2>&1
! grep -q "gate-target" "$TMP/out_adv169_7_2" || { cat "$TMP/out_adv169_7_2"; fail "Issue 169 Test 7: second identical runner-only dispatch within TTL must be silent"; }
echo "test issue 169 gate advisory 7 (runner-only deduplication) PASS"

# ============================ #180: venv-pinned gate + disclosure ============================
# A fake <workdir>/.venv/bin/ruff shim, distinct from anything else on PATH (including the
# stub codex this suite installs), so a resolve against it proves the gate ran pinned to the
# workdir's own venv rather than whatever ruff the launching shell had.
P_venv180="$TMP/venv180_parent"; new_parent "$P_venv180"
mkdir -p "$P_venv180/.venv/bin"
cat > "$P_venv180/.venv/bin/ruff" <<'RUFF'
#!/usr/bin/env bash
echo "ruff 0.15.16-fixture"
RUFF
chmod +x "$P_venv180/.venv/bin/ruff"
git -C "$P_venv180" add -A; git -C "$P_venv180" commit -qm "add venv ruff shim"

bash "$CD" codex "$P_venv180" "$TMP/prompt" "ruff --version" >"$TMP/out_venv180" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out_venv180"; fail "180: build-cmd 'ruff --version' against the workdir venv shim should exit 0, got $rc"; }
grep -qF "gate-env: " "$TMP/out_venv180" || { cat "$TMP/out_venv180"; fail "180: gate-env disclosure line is missing"; }
grep -qF "ruff=$P_venv180/.venv/bin/ruff ruff 0.15.16-fixture" "$TMP/out_venv180" || { cat "$TMP/out_venv180"; fail "180: gate-env line did not name the workdir venv ruff shim with its version"; }
echo "test 180 (venv-pinned gate resolves + discloses the workdir ruff) PASS"

# --no-venv opts back out: the gate must NOT resolve to the workdir venv shim.
git -C "$P_venv180" reset --hard -q HEAD; git -C "$P_venv180" clean -fdq
bash "$CD" --no-venv codex "$P_venv180" "$TMP/prompt" 'p="$(command -v ruff || true)"; printf "ruff_path=%s" "$p"' >"$TMP/out_venv180_noflag" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out_venv180_noflag"; fail "180: --no-venv build-cmd should exit 0, got $rc"; }
grep -qF "ruff_path=$P_venv180/.venv/bin/ruff" "$TMP/out_venv180_noflag" && { cat "$TMP/out_venv180_noflag"; fail "180: --no-venv should not resolve ruff via the workdir venv"; }
echo "test 180 (--no-venv restores the inherited PATH) PASS"

# ============ gate ORDER: the scope gate runs before the build gate ============
# The scope gate is pure `git status`/`git diff`; the build gate EXECUTES what the agent wrote.
# An out-of-scope change must be refused without first running the agent's code. The build-cmd
# below records that it ran, so the assertion is on execution, not just on the message.
P_order="$TMP/gate_order_parent"; new_parent "$P_order"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
wd=""; while [ $# -gt 0 ]; do [ "$1" = "-C" ] && { wd="$2"; shift 2; continue; }; shift; done
: "${wd:=$PWD}"; echo "out of scope" > "$wd/not_allowed.txt"
STUB
chmod +x "$TMP/bin/codex"
BUILD_RAN="$TMP/gate_order.build_ran"; rm -f "$BUILD_RAN"
bash "$CD" --allow-path "allowed_only.txt" codex "$P_order" "$TMP/prompt" "touch $BUILD_RAN" >"$TMP/out_order" 2>&1; rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out_order"; fail "gate order: out-of-scope change should exit 1, got $rc"; }
grep -q "scope gate: out-of-scope file changed: not_allowed.txt" "$TMP/out_order" || { cat "$TMP/out_order"; fail "gate order: scope-gate message missing/changed"; }
[ ! -e "$BUILD_RAN" ] || { cat "$TMP/out_order"; fail "gate order: the build gate EXECUTED before the scope gate refused the change"; }
echo "test gate order (scope gate refuses before the build gate executes) PASS"

# A passing scope gate still reaches the build gate, and a failing build still fails.
P_order2="$TMP/gate_order2_parent"; new_parent "$P_order2"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
wd=""; while [ $# -gt 0 ]; do [ "$1" = "-C" ] && { wd="$2"; shift 2; continue; }; shift; done
: "${wd:=$PWD}"; echo "in scope" > "$wd/allowed_only.txt"
STUB
chmod +x "$TMP/bin/codex"
BUILD_RAN2="$TMP/gate_order2.build_ran"; rm -f "$BUILD_RAN2"
bash "$CD" --allow-path "allowed_only.txt" codex "$P_order2" "$TMP/prompt" "touch $BUILD_RAN2; false" >"$TMP/out_order2" 2>&1; rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out_order2"; fail "gate order: in-scope change with a failing build should exit 1, got $rc"; }
[ -e "$BUILD_RAN2" ] || { cat "$TMP/out_order2"; fail "gate order: an in-scope change must still reach the build gate"; }
grep -q "build/vet failed" "$TMP/out_order2" || { cat "$TMP/out_order2"; fail "gate order: build-failure message missing/changed"; }
echo "test gate order (in-scope change still reaches the build gate) PASS"

# ============ fail artifacts never land in the consumer's working tree ============
# --keep-on-fail promises the tree is left exactly as the agent left it. That promise is only
# true if the dispatcher's own artifacts (the fail patch, the scratch marker) are not in it.
P_art="$TMP/fail_artifacts_parent"; new_parent "$P_art"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
wd=""; while [ $# -gt 0 ]; do [ "$1" = "-C" ] && { wd="$2"; shift 2; continue; }; shift; done
: "${wd:=$PWD}"
echo "keep me" > "$wd/agent_made_this.txt"
printf '{"status":"complete","files_written":["agent_made_this.txt"],"timestamp":"2026-01-01T00:00:00Z"}\n' > "$wd/_coding-result.json"
STUB
chmod +x "$TMP/bin/codex"
bash "$CD" --keep-on-fail codex "$P_art" "$TMP/prompt" "false" >"$TMP/out_art" 2>&1; rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out_art"; fail "fail artifacts: --keep-on-fail failing gate should exit 1, got $rc"; }
[ -f "$P_art/agent_made_this.txt" ] || fail "fail artifacts: --keep-on-fail must still leave the agent's file"
[ ! -e "$P_art/.coding-dispatch-last-fail.patch" ] || fail "fail artifacts: the patch must not be written into the working tree"
[ ! -e "$P_art/coding-dispatch-last-fail.patch" ] || fail "fail artifacts: the patch must not be written into the working tree"
[ ! -e "$P_art/_coding-result.json" ] || fail "fail artifacts: the scratch marker must be removed from the working tree on failure"
PATCH_ART="$(git -C "$P_art" rev-parse --absolute-git-dir)/coding-dispatch-last-fail.patch"
[ -s "$PATCH_ART" ] || fail "fail artifacts: the patch must still exist under the git dir: $PATCH_ART"
grep -qF "$PATCH_ART" "$TMP/out_art" || { cat "$TMP/out_art"; fail "fail artifacts: the fail message must print the patch path"; }
grep -q "_coding-result.json" "$PATCH_ART" && fail "fail artifacts: the scratch marker must not appear in the captured patch"
# The only untracked path left is the agent's own file — nothing of the dispatcher's.
[ "$(git -C "$P_art" status --porcelain)" = "?? agent_made_this.txt" ] || fail "fail artifacts: --keep-on-fail tree is not exactly as the agent left it: $(git -C "$P_art" status --porcelain)"
echo "test fail artifacts (patch + marker stay out of the consumer's tree) PASS"

# The same holds after a plain revert: the tree is byte-clean and the patch is under .git/.
P_art2="$TMP/fail_artifacts_revert_parent"; new_parent "$P_art2"
bash "$CD" codex "$P_art2" "$TMP/prompt" "false" >"$TMP/out_art2" 2>&1; rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out_art2"; fail "fail artifacts (revert): should exit 1, got $rc"; }
[ -z "$(git -C "$P_art2" status --porcelain)" ] || fail "fail artifacts (revert): tree should be byte-clean, got: $(git -C "$P_art2" status --porcelain)"
[ -s "$(git -C "$P_art2" rev-parse --absolute-git-dir)/coding-dispatch-last-fail.patch" ] || fail "fail artifacts (revert): patch missing under the git dir"
echo "test fail artifacts (revert path leaves a byte-clean tree) PASS"

# ============ md5_hex is portable and agrees across the two path-deriving callers ============
h="$(printf '%s' "abc" | md5_hex)"
[ "$h" = "900150983cd24fb0d6963f7d28e17f72" ] || fail "md5_hex: wrong digest for 'abc': $h"
case "$h" in [0-9a-f][0-9a-f]*) ;; *) fail "md5_hex: digest is not lowercase hex: $h";; esac
[ "${#h}" -eq 32 ] || fail "md5_hex: digest is not 32 chars: $h (${#h})"
echo "test md5_hex (portable bare hex digest) PASS"

echo "ALL PASS"
