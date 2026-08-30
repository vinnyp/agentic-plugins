#!/usr/bin/env bash
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"; TMP="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT
# shellcheck disable=SC1091
. "$SELF_DIR/lib/test-env-reset.sh"
reset_dispatch_env  # neutralize any operator-exported dispatch vars before the suite runs
mkdir -p "$TMP/bin"
cat > "$TMP/bin/coding-dispatch.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CD_ARGS_FILE"
printf '%s %s\n' "${1:-}" "${CODING_DISPATCH_TIMEOUT:-}" >> "$CD_TIMEOUT_FILE"
STUB
chmod +x "$TMP/bin/coding-dispatch.sh"; export PATH="$TMP/bin:$PATH"; export CD_ARGS_FILE="$TMP/cd-args"; export CD_TIMEOUT_FILE="$TMP/cd-timeouts"
printf '### Task 1: x\nimplement x\n' > "$TMP/plan.md"
git -C "$TMP" init -q
git -C "$TMP" config user.email t@t
git -C "$TMP" config user.name t
: > "$CD_TIMEOUT_FILE"

new_phase_repo() {
  local p="$1"; mkdir -p "$p"; git -C "$p" init -q
  git -C "$p" config user.email t@t; git -C "$p" config user.name t
  printf 'base\n' > "$p/tracked.txt"
  git -C "$p" add -A; git -C "$p" commit -qm base
}

write_review_pin_marker() {
  local workdir="$1" label="$2" marker sha
  marker="$(git -C "$workdir" rev-parse --absolute-git-dir)/review-pinned"
  sha="$(git -C "$workdir" rev-parse HEAD)"
  {
    printf 'sha=%s\n' "$sha"
    printf 'pinned_at=%s\n' "$(date +%s)"
    printf 'pid=%s\n' "$$"
    printf 'label=%s\n' "$label"
  } > "$marker"
}

"$SELF_DIR/coding-build-phase.sh" codex "$TMP/plan.md" "$TMP" 1 --build-cmd "pytest -q" >/dev/null 2>&1
grep -qF "pytest -q" "$CD_ARGS_FILE" || { echo "FAIL: --build-cmd not passed through"; exit 1; }
grep -q "go build" "$CD_ARGS_FILE" && { echo "FAIL: hardcoded go gate leaked"; exit 1; }
grep -q '^codex 20m$' "$CD_TIMEOUT_FILE" || { cat "$CD_TIMEOUT_FILE"; echo "FAIL: codex phase default timeout should be 20m"; exit 1; }
echo "test (passthrough, non-worktree) PASS"

# #140: an active review pin refuses the phase before any task dispatch, with rc 9
# and without the false "dispatch reverted the tree" diagnostic.
PINNED_PHASE="$TMP/pinned-phase"; new_phase_repo "$PINNED_PHASE"
pinned_phase_sha="$(git -C "$PINNED_PHASE" rev-parse HEAD)"
write_review_pin_marker "$PINNED_PHASE" "phase review"
: > "$CD_ARGS_FILE"
out="$("$SELF_DIR/coding-build-phase.sh" codex "$TMP/plan.md" "$PINNED_PHASE" 1 --build-cmd "pytest -q" 2>&1)"; rc=$?
[ "$rc" -eq 9 ] || { echo "$out"; echo "FAIL: pinned phase should exit 9, got $rc"; exit 1; }
printf '%s\n' "$out" | grep -q "$pinned_phase_sha" || { echo "$out"; echo "FAIL: pinned phase refusal should name pinned SHA $pinned_phase_sha"; exit 1; }
printf '%s\n' "$out" | grep -q "label=phase review" || { echo "$out"; echo "FAIL: pinned phase refusal should name label"; exit 1; }
printf '%s\n' "$out" | grep -q "age=" || { echo "$out"; echo "FAIL: pinned phase refusal should name age"; exit 1; }
printf '%s\n' "$out" | grep -q "review-pin.sh release" || { echo "$out"; echo "FAIL: pinned phase refusal should print release command"; exit 1; }
! grep -q . "$CD_ARGS_FILE" || { cat "$CD_ARGS_FILE"; echo "FAIL: pinned phase should refuse before any task dispatch"; exit 1; }
! printf '%s\n' "$out" | grep -q "reverted" || { echo "$out"; echo "FAIL: pinned phase refusal must not claim the tree was reverted"; exit 1; }
echo "test #140 build phase refuses active review pin before dispatch PASS"

# #20: phase-driven dispatch must pass the agent-aware default timeout through to coding-dispatch.
: > "$CD_TIMEOUT_FILE"
"$SELF_DIR/coding-build-phase.sh" agy "$TMP/plan.md" "$TMP" 1 --build-cmd "pytest -q" >/dev/null 2>&1
grep -q '^agy 25m$' "$CD_TIMEOUT_FILE" || { cat "$CD_TIMEOUT_FILE"; echo "FAIL: agy phase default timeout should be 25m"; exit 1; }
: > "$CD_TIMEOUT_FILE"
CODING_DISPATCH_TIMEOUT=10m "$SELF_DIR/coding-build-phase.sh" agy "$TMP/plan.md" "$TMP" 1 --build-cmd "pytest -q" >/dev/null 2>&1
grep -q '^agy 10m$' "$CD_TIMEOUT_FILE" || { cat "$CD_TIMEOUT_FILE"; echo "FAIL: explicit CODING_DISPATCH_TIMEOUT should override agy phase default"; exit 1; }
echo "test #20 phase timeout propagation PASS"

# #60: repo guard accepts a real git worktree (.git is a file) and rejects a plain non-git dir.
MAIN="$TMP/mainRepo"; mkdir -p "$MAIN"; git -C "$MAIN" init -q
git -C "$MAIN" config user.email t@t; git -C "$MAIN" config user.name t
echo base > "$MAIN/f.txt"; git -C "$MAIN" add -A; git -C "$MAIN" commit -qm base
WT_REPO="$TMP/linkedWT"
git -C "$MAIN" worktree add -q -b linkedWT "$WT_REPO" HEAD
out="$("$SELF_DIR/coding-build-phase.sh" codex "$TMP/plan.md" "$WT_REPO" 1 --build-cmd "pytest -q" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || { echo "$out"; echo "FAIL: git worktree repo should proceed past repo check, got rc $rc"; exit 1; }
printf '%s\n' "$out" | grep -q "PHASE=error: not a git repo" && { echo "$out"; echo "FAIL: git worktree was rejected as non-git"; exit 1; }
NONGIT="$(mktemp -d)"
out="$("$SELF_DIR/coding-build-phase.sh" codex "$TMP/plan.md" "$NONGIT" 1 --build-cmd "pytest -q" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] || { echo "$out"; echo "FAIL: non-git dir should exit 2, got $rc"; exit 1; }
printf '%s\n' "$out" | grep -q "PHASE=error: not a git repo: $NONGIT" || { echo "$out"; echo "FAIL: non-git error message missing"; exit 1; }
git -C "$MAIN" worktree remove --force "$WT_REPO" 2>/dev/null || true
rm -rf "$NONGIT"
echo "test #60 repo guard worktree accepted + non-git rejected PASS"

# ---- --worktree multi-task: REAL coding-dispatch.sh + a real (distinct-content) codex stub ----
# The case above stubs the DISPATCHER; here we need the real one to actually create a worktree.
mkdir -p "$TMP/uniqbin"
cat > "$TMP/uniqbin/codex" <<'STUB'
#!/usr/bin/env bash
wd=""; while [ $# -gt 0 ]; do [ "$1" = "-C" ] && { wd="$2"; shift 2; continue; }; shift; done
: "${wd:=$PWD}"
echo "change $(date +%s)$RANDOM" >> "$wd/agent_made_this.txt"
STUB
chmod +x "$TMP/uniqbin/codex"
PARENT="$TMP/parentWT"; mkdir -p "$PARENT"; git -C "$PARENT" init -q
git -C "$PARENT" config user.email t@t; git -C "$PARENT" config user.name t
echo base > "$PARENT/tracked.txt"; git -C "$PARENT" add -A; git -C "$PARENT" commit -qm base
parent_head="$(git -C "$PARENT" rev-parse HEAD)"
printf '### Task 1: a\nimplement a\n### Task 2: b\nimplement b\n' > "$TMP/plan2.md"
out="$(PATH="$SELF_DIR:$TMP/uniqbin:$PATH" "$SELF_DIR/coding-build-phase.sh" codex "$TMP/plan2.md" "$PARENT" 1 2 --worktree --build-cmd "true" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || { echo "$out"; echo "FAIL: phase --worktree should exit 0, got $rc"; exit 1; }
[ "$(git -C "$PARENT" rev-parse HEAD)" = "$parent_head" ] || { echo "FAIL: parent main moved (commits should be on the worktree branch)"; exit 1; }
SLUG="$(printf '%s\n' "$out" | sed -n 's/.*PHASE=ok worktree=[^ ]* branch=\([^ ]*\) .*/\1/p')"
[ -n "$SLUG" ] || { echo "$out"; echo "FAIL: phase should print PHASE=ok worktree=... branch=..."; exit 1; }
n="$(git -C "$PARENT" rev-list --count "$parent_head".."$SLUG")"
[ "$n" -eq 2 ] || { echo "FAIL: worktree branch should have 2 task commits, got $n"; exit 1; }
# B2 cross-script path identity: the path build-phase printed IS the registered worktree path.
WT_PRINTED="$(printf '%s\n' "$out" | sed -n 's/.*PHASE=ok worktree=\([^ ]*\) branch=.*/\1/p')"
git -C "$PARENT" worktree list --porcelain | grep -Fxq -- "worktree $WT_PRINTED" || { echo "FAIL: printed worktree path not registered (cross-script divergence)"; exit 1; }
git -C "$PARENT" worktree remove --force "$WT_PRINTED" 2>/dev/null || true
echo "test (phase --worktree: 2 commits off-main + path identity) PASS"

echo "ALL PASS"
