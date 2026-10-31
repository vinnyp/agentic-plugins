#!/usr/bin/env bash
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"; TMP="$(set -eu; p="$(mktemp -d "${TMPDIR:-/tmp}/build-phase.XXXXXX")"; [ -n "$p" ]; cd "$p"; pwd -P)" || exit 1; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
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
: > "$CD_TIMEOUT_FILE"

new_phase_repo() {
  local p="$1"; mkdir -p "$p"; git -C "$p" init -q
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

# A packaged phase without review-pin.sh still dispatches its task.
missing_pin_bin="$TMP/missing-pin-bin"; mkdir -p "$missing_pin_bin/lib"
cp "$SELF_DIR/coding-build-phase.sh" "$missing_pin_bin/"
cp "$SELF_DIR/lib/hash.sh" "$missing_pin_bin/lib/"
[ ! -e "$missing_pin_bin/review-pin.sh" ] || { echo "FAIL: missing-pin fixture unexpectedly has helper"; exit 1; }
: > "$CD_ARGS_FILE"
out="$(bash "$missing_pin_bin/coding-build-phase.sh" codex "$TMP/plan.md" "$TMP" 1 --build-cmd true 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || { echo "$out"; echo "FAIL: missing review-pin.sh phase should proceed, got $rc"; exit 1; }
grep -qF "$TMP" "$CD_ARGS_FILE" || { echo "FAIL: missing review-pin.sh phase should dispatch"; exit 1; }
echo "test missing review-pin.sh build phase proceeds PASS"

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
echo base > "$MAIN/f.txt"; git -C "$MAIN" add -A; git -C "$MAIN" commit -qm base
WT_REPO="$TMP/linkedWT"
git -C "$MAIN" worktree add -q -b linkedWT "$WT_REPO" HEAD
out="$("$SELF_DIR/coding-build-phase.sh" codex "$TMP/plan.md" "$WT_REPO" 1 --build-cmd "pytest -q" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || { echo "$out"; echo "FAIL: git worktree repo should proceed past repo check, got rc $rc"; exit 1; }
printf '%s\n' "$out" | grep -q "PHASE=error: not a git repo" && { echo "$out"; echo "FAIL: git worktree was rejected as non-git"; exit 1; }
NONGIT="$(set -eu; p="$(mktemp -d "${TMPDIR:-/tmp}/build-phase-nongit.XXXXXX")"; [ -n "$p" ]; printf '%s' "$p")" || exit 1
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
# #242: config-conventional's subject-case rejects a sentence-case "Task N" subject.
subjects="$(git -C "$PARENT" log --format=%s --reverse "$parent_head".."$SLUG")"
want="$(printf 'feat(parentWT): task 1 via codex\nfeat(parentWT): task 2 via codex')"
[ "$subjects" = "$want" ] || { printf '%s\n' "$subjects"; echo "FAIL: #242 worktree commit subjects should be lower-case conventional"; exit 1; }
# B2 cross-script path identity: the path build-phase printed IS the registered worktree path.
WT_PRINTED="$(printf '%s\n' "$out" | sed -n 's/.*PHASE=ok worktree=\([^ ]*\) branch=.*/\1/p')"
git -C "$PARENT" worktree list --porcelain | grep -Fxq -- "worktree $WT_PRINTED" || { echo "FAIL: printed worktree path not registered (cross-script divergence)"; exit 1; }
git -C "$PARENT" worktree remove --force "$WT_PRINTED" 2>/dev/null || true
echo "test (phase --worktree: 2 commits off-main + path identity) PASS"

# #242: the in-place commit site uses the same lower-case conventional subject.
mkdir -p "$TMP/inplacebin"
cat > "$TMP/inplacebin/coding-dispatch.sh" <<'STUB'
#!/usr/bin/env bash
echo "change" >> "$2/agent_made_this.txt"
STUB
chmod +x "$TMP/inplacebin/coding-dispatch.sh"
INPLACE="$TMP/inplace242"; new_phase_repo "$INPLACE"
out="$(PATH="$TMP/inplacebin:$PATH" "$SELF_DIR/coding-build-phase.sh" codex "$TMP/plan.md" "$INPLACE" 1 --build-cmd true 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || { echo "$out"; echo "FAIL: #242 in-place phase should exit 0, got $rc"; exit 1; }
[ "$(git -C "$INPLACE" log -1 --format=%s)" = "feat(inplace242): task 1 via codex" ] || { git -C "$INPLACE" log -1 --format=%s; echo "FAIL: #242 in-place commit subject should be lower-case conventional"; exit 1; }
echo "test #242 commit subjects PASS"


# foundry#237: every task prompt carries the plan preamble (goal, spec path, global
# constraints) ahead of its task spec; orchestrator boilerplate is removed; no preamble
# means no block; an over-cap preamble is cut with a visible note.
mkdir -p "$TMP/ctxbin"
cat > "$TMP/ctxbin/coding-dispatch.sh" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in *.prompt) n=$(( $(find "$CTX_DIR" -type f | wc -l) + 1 )); cp "$a" "$CTX_DIR/$n";; esac; done
STUB
chmod +x "$TMP/ctxbin/coding-dispatch.sh"
cat > "$TMP/plan-ctx.md" <<'PLAN'
---
type: plan
---
# Widget Implementation Plan

> **For agentic workers:** executed via `coding-build-phase.sh codex <this plan> ...`. Spec (READ FIRST, absolute path): `/abs/path/specs/x.md`

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.
>
> **Executed unattended** via `coding-build-phase.sh codex <this plan> ...`.
> Only each ### Task N: block reaches the coding agent ...
> Keep this worker guidance.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. **Read the spec alongside this plan** — source: `projects/agent-tooling/specs/2026-06-15-x-spec.md`.

> **For agentic workers:** executed via `coding-build-phase.sh codex <this plan> ...`. Specs (READ BOTH FIRST, absolute paths): `/abs/specs/a.md` and `/abs/specs/b.md`. Also '/abs/specs/a.md', "/abs/specs/c.md";

> **For agentic workers:** REQUIRED SUB-SKILL: ... Spec: [[2026-06-12-x-design]] and [[2026-06-12-x-design]]

> **For agentic workers:** REQUIRED SUB-SKILL: **docs/b.md**, <docs/c.md>, docs/d.md#goals, [spec](docs/e.md)
Prose mentioning superpowers: and coding-build-phase.sh stays.

> Ordinary blockquote stays.

**Goal:** GOAL-237 ship the widget
**Spec:** docs/specs/widget-design.md

## Global Constraints
- RULE-237 never use innerHTML

### Task 1: first
BODY-ONE
### Task 2: second
BODY-TWO
PLAN
repo237="$TMP/phase237"; new_phase_repo "$repo237"
export CTX_DIR="$TMP/ctx237"; mkdir -p "$CTX_DIR"
out="$(PATH="$TMP/ctxbin:$PATH" "$SELF_DIR/coding-build-phase.sh" codex "$TMP/plan-ctx.md" "$repo237" 1 2 --build-cmd true 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || { echo "$out"; echo "FAIL: #237 phase should exit 0, got $rc"; exit 1; }
[ -f "$CTX_DIR/1" ] && [ -f "$CTX_DIR/2" ] || { ls "$CTX_DIR"; echo "FAIL: #237 expected two captured prompts"; exit 1; }
for n237 in 1 2; do
  f237="$CTX_DIR/$n237"
  for want237 in "PLAN CONTEXT" "GOAL-237" "docs/specs/widget-design.md" "RULE-237" "/abs/path/specs/x.md" "Prose mentioning superpowers: and coding-build-phase.sh stays." "Ordinary blockquote stays." "Keep this worker guidance." "stop and report the conflict" "instructions addressed to the orchestrator"; do
    grep -qF "$want237" "$f237" || { cat "$f237"; echo "FAIL: #237 task $n237 prompt missing '$want237'"; exit 1; }
  done
  for token237 in /abs/path/specs/x.md projects/agent-tooling/specs/2026-06-15-x-spec.md /abs/specs/a.md /abs/specs/b.md /abs/specs/c.md '[[2026-06-12-x-design]]' docs/b.md docs/c.md docs/d.md docs/e.md; do
    [ "$(grep -cxF "> Spec: $token237" "$f237")" -eq 1 ] || { cat "$f237"; echo "FAIL: missing or duplicate spec $token237"; exit 1; }
  done
  for unwanted237 in 'Executed unattended' 'REQUIRED SUB-SKILL' 'coding-build-phase.sh' 'superpowers:' '> **For agentic workers:**' 'reaches the coding agent' 'type: plan'; do
    ! grep -vFx "Prose mentioning superpowers: and coding-build-phase.sh stays." "$f237" | grep -qF "$unwanted237" || { cat "$f237"; echo "FAIL: leaked $unwanted237"; exit 1; }
  done
  rule_line="$(grep -nF "RULE-237" "$f237" | head -1 | cut -d: -f1)"
  spec_line="$(grep -nF "TASK SPEC" "$f237" | head -1 | cut -d: -f1)"
  [ "$rule_line" -lt "$spec_line" ] || { cat "$f237"; echo "FAIL: #237 plan context must precede the task spec"; exit 1; }
done
grep -qF "BODY-ONE" "$CTX_DIR/1" && ! grep -qF "BODY-TWO" "$CTX_DIR/1" || { echo "FAIL: #237 task 1 prompt should carry only its own body"; exit 1; }
grep -qF "BODY-TWO" "$CTX_DIR/2" && ! grep -qF "BODY-ONE" "$CTX_DIR/2" || { echo "FAIL: #237 task 2 prompt should carry only its own body"; exit 1; }
rm -f "$CTX_DIR"/*
out="$(PATH="$TMP/ctxbin:$PATH" "$SELF_DIR/coding-build-phase.sh" codex "$TMP/plan.md" "$repo237" 1 --build-cmd true 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ -f "$CTX_DIR/1" ] || { echo "$out"; echo "FAIL: #237 no-preamble phase should dispatch"; exit 1; }
! grep -qF "PLAN CONTEXT" "$CTX_DIR/1" || { cat "$CTX_DIR/1"; echo "FAIL: #237 a plan with no preamble must not get a PLAN CONTEXT block"; exit 1; }
rm -f "$CTX_DIR"/*
out="$(PATH="$TMP/ctxbin:$PATH" CODING_BUILD_PLAN_CONTEXT_MAX=40 "$SELF_DIR/coding-build-phase.sh" codex "$TMP/plan-ctx.md" "$repo237" 1 --build-cmd true 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ -f "$CTX_DIR/1" ] || { echo "$out"; echo "FAIL: #237 capped phase should dispatch"; exit 1; }
grep -qF "[plan context truncated: first 40 of" "$CTX_DIR/1" || { cat "$CTX_DIR/1"; echo "FAIL: #237 over-cap preamble needs a truncation note"; exit 1; }
! grep -qF "RULE-237" "$CTX_DIR/1" || { cat "$CTX_DIR/1"; echo "FAIL: #237 cap was not applied"; exit 1; }
out="$(PATH="$TMP/ctxbin:$PATH" CODING_BUILD_PLAN_CONTEXT_MAX=lots "$SELF_DIR/coding-build-phase.sh" codex "$TMP/plan-ctx.md" "$repo237" 1 --build-cmd true 2>&1)"; rc=$?
[ "$rc" -eq 2 ] || { echo "$out"; echo "FAIL: #237 a non-numeric cap should exit 2, got $rc"; exit 1; }
# Boundary and decimal parsing use a preamble with an exact, known length.
printf 'abcdefghij\n### Task 1: x\nbody\n### Task 2: y\nbody two\n' > "$TMP/boundary.md"
for cap237 in 10 9 08; do
  rm -f "$CTX_DIR"/*
  out="$(cd "$TMP" && PATH="$TMP/ctxbin:$PATH" CODING_BUILD_PLAN_CONTEXT_MAX="$cap237" "$SELF_DIR/coding-build-phase.sh" codex boundary.md "$repo237" 1 2 --build-cmd true)"; rc=$?
  [ "$rc" -eq 0 ] && [ -f "$CTX_DIR/1" ] && [ -f "$CTX_DIR/2" ] || { echo "FAIL: cap $cap237 did not dispatch task 1: $out"; exit 1; }
  if [ "$cap237" = 10 ]; then
    ! grep -qF 'plan context truncated' "$CTX_DIR/1" || { echo 'FAIL: exact cap truncated'; exit 1; }
    ! printf '%s' "$out" | grep -qF 'WARNING:' || { echo 'FAIL: exact cap warned'; exit 1; }
  else
    expected237="$cap237"; [ "$cap237" != 08 ] || expected237=8
    grep -qF "first $expected237 of 10" "$CTX_DIR/1" || { echo 'FAIL: decimal cap/note'; exit 1; }
    grep -qF "full plan at $TMP/boundary.md" "$CTX_DIR/1" || { echo 'FAIL: relative plan not absolutized'; exit 1; }
    ! printf '%s\n' "$out" | grep -qF 'truncated: [plan context truncated:' || { echo "$out"; echo 'FAIL: duplicate warning text'; exit 1; }
    [ "$(printf '%s\n' "$out" | grep -cF 'WARNING: plan context truncated')" -eq 1 ] || { echo 'FAIL: expected one stdout warning'; exit 1; }
  fi
done
out="$(CODING_BUILD_PLAN_CONTEXT_MAX=0 "$SELF_DIR/coding-build-phase.sh" codex "$TMP/plan.md" "$repo237" 1 --build-cmd true)"; rc=$?
[ "$rc" -eq 2 ] || { echo 'FAIL: zero cap accepted'; exit 1; }
printf '%s\n' "$out" | grep -qF 'PHASE=error: CODING_BUILD_PLAN_CONTEXT_MAX must be a positive whole number of characters' || { echo "$out"; echo 'FAIL: zero cap diagnostic missing'; exit 1; }
printf '  \n\t\n### Task 1: x\nbody\n' > "$TMP/whitespace.md"
rm -f "$CTX_DIR"/*
PATH="$TMP/ctxbin:$PATH" "$SELF_DIR/coding-build-phase.sh" codex "$TMP/whitespace.md" "$repo237" 1 --build-cmd true >/dev/null
[ -f "$CTX_DIR/1" ] || { echo 'FAIL: whitespace prompt not captured'; exit 1; }
! grep -qF 'PLAN CONTEXT' "$CTX_DIR/1" || { echo 'FAIL: whitespace context emitted'; exit 1; }
for front237 in unclosed crlf; do
  rm -f "$CTX_DIR"/*
  if [ "$front237" = unclosed ]; then
    printf '%s\n' '---' 'KEEP-UNCLOSED' 'title: x' '> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:x ... `/abs/specs/s.md`' '### Task 1: x' body > "$TMP/front.md"
  else
    printf '%s\r\n' '---' 'HIDE-CRLF' '---' 'KEEP-CRLF' '### Task 1: x' body > "$TMP/front.md"
  fi
  PATH="$TMP/ctxbin:$PATH" "$SELF_DIR/coding-build-phase.sh" codex "$TMP/front.md" "$repo237" 1 --build-cmd true >/dev/null
  [ -f "$CTX_DIR/1" ] || { echo 'FAIL: frontmatter prompt not captured'; exit 1; }
  if [ "$front237" = unclosed ]; then
    grep -qxF KEEP-UNCLOSED "$CTX_DIR/1" || { cat "$CTX_DIR/1"; echo 'FAIL: unclosed frontmatter swallowed preamble'; exit 1; }
    ! grep -qF 'REQUIRED SUB-SKILL' "$CTX_DIR/1" || { cat "$CTX_DIR/1"; echo 'FAIL: unclosed frontmatter leaked banner'; exit 1; }
    grep -qxF '> Spec: /abs/specs/s.md' "$CTX_DIR/1" || { cat "$CTX_DIR/1"; echo 'FAIL: unclosed frontmatter lost spec'; exit 1; }
  else
    ! grep -qF HIDE-CRLF "$CTX_DIR/1" && grep -qxF KEEP-CRLF "$CTX_DIR/1" || { cat "$CTX_DIR/1"; echo 'FAIL: CRLF frontmatter'; exit 1; }
  fi
done
unset CTX_DIR
echo "test #237 plan context reaches every task prompt PASS"

# foundry#261: a task block ends at any level-2 heading, so a plan's closing sections stay out
# of the prompt. A "## " line inside a code fence is task content, and an unclosed fence must
# not swallow the next task.
cat > "$TMP/plan-261.md" <<'PLAN'
### Task 1: quotes a document
BEFORE-FENCE
```markdown
## Quoted heading
QUOTED-BODY
```
AFTER-FENCE
#### Subheading
SUB-BODY
## Stage 2 heading
STAGE-TEXT
### Task 2: nested fences
````markdown
```
## Nested heading
```
NESTED-BODY
````
~~~
## Tilde heading
```
## Backtick inside tilde
~~~
TILDE-AFTER
```inline``` is not a fence
## Orchestrator steps
ORCH-TEXT open a PR and merge it
## Self-review
SELF-TEXT
PLAN
cat > "$TMP/plan-261-unclosed.md" <<'PLAN'
### Task 1: unclosed
```
OPEN-FENCE-BODY
## Inside unclosed
INSIDE-UNCLOSED
### Task 2: next
NEXT-BODY
## Closing notes
CLOSING-TEXT
PLAN
printf '%s\r\n' '### Task 1: crlf' '```' '## Quoted crlf' '```' 'CRLF-AFTER' '## Trailing' 'CRLF-TRAILING' > "$TMP/plan-261-crlf.md"
repo261="$TMP/phase261"; new_phase_repo "$repo261"
export CTX_DIR="$TMP/ctx261"; mkdir -p "$CTX_DIR"
expect_261() { # <prompt file> <want|deny> <literal>...
  local f261="$1" mode261="$2"; shift 2
  local w261
  for w261 in "$@"; do
    if [ "$mode261" = want ]; then
      grep -qF -- "$w261" "$f261" || { cat "$f261"; echo "FAIL: #261 $f261 should carry '$w261'"; exit 1; }
    else
      ! grep -qF -- "$w261" "$f261" || { cat "$f261"; echo "FAIL: #261 $f261 should not carry '$w261'"; exit 1; }
    fi
  done
}
out="$(PATH="$TMP/ctxbin:$PATH" "$SELF_DIR/coding-build-phase.sh" codex "$TMP/plan-261.md" "$repo261" 1 2 --build-cmd true 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || { echo "$out"; echo "FAIL: #261 phase should exit 0, got $rc"; exit 1; }
expect_261 "$CTX_DIR/1" want BEFORE-FENCE '## Quoted heading' QUOTED-BODY AFTER-FENCE '#### Subheading' SUB-BODY
expect_261 "$CTX_DIR/1" deny STAGE-TEXT NESTED-BODY
expect_261 "$CTX_DIR/2" want '## Nested heading' NESTED-BODY '## Tilde heading' '## Backtick inside tilde' TILDE-AFTER '```inline``` is not a fence'
expect_261 "$CTX_DIR/2" deny '## Orchestrator steps' ORCH-TEXT SELF-TEXT
rm -f "$CTX_DIR"/*
out="$(PATH="$TMP/ctxbin:$PATH" "$SELF_DIR/coding-build-phase.sh" codex "$TMP/plan-261-unclosed.md" "$repo261" 1 2 --build-cmd true 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || { echo "$out"; echo "FAIL: #261 unclosed-fence phase should exit 0, got $rc"; exit 1; }
expect_261 "$CTX_DIR/1" want OPEN-FENCE-BODY INSIDE-UNCLOSED
expect_261 "$CTX_DIR/1" deny NEXT-BODY
expect_261 "$CTX_DIR/2" want NEXT-BODY
expect_261 "$CTX_DIR/2" deny CLOSING-TEXT
rm -f "$CTX_DIR"/*
out="$(PATH="$TMP/ctxbin:$PATH" "$SELF_DIR/coding-build-phase.sh" codex "$TMP/plan-261-crlf.md" "$repo261" 1 --build-cmd true 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || { echo "$out"; echo "FAIL: #261 CRLF phase should exit 0, got $rc"; exit 1; }
expect_261 "$CTX_DIR/1" want '## Quoted crlf' CRLF-AFTER
expect_261 "$CTX_DIR/1" deny CRLF-TRAILING
# A closed fence protects every "## " line, including quoted Phase and Self-Review headings, and
# only a real closer ends it. Unfenced, those headings still end the block.
printf '%s\n' '### Task 1: closers' '```' '## Phase 1 quoted' '## Self-Review quoted' '```bash' '## Info not a closer' '```' \
  'AFTER-INFO' '```' '## Longer closer' '````' 'AFTER-LONG' '   ```' '## Indented fence' '    ```' '## Four spaces not a closer' '   ```' \
  'AFTER-INDENT' '    ```' '## Four spaces not an opener' 'INDENT-TRAILING' > "$TMP/plan-261-closers.md"
printf '%s\n' '### Task 1: real phase' 'PHASE-BODY' '## Phase 2' 'PHASE-TEXT' > "$TMP/plan-261-phase.md"
printf '%s\n' '### Task 1: real self-review' 'SELF-BODY' '## Self-Review' 'SELF-REVIEW-TEXT' > "$TMP/plan-261-self.md"
printf '### Task 1: tab closer\n```\n## Tab quoted\n```\t\nTAB-AFTER\n## Trailing\nTAB-TRAILING\n' > "$TMP/plan-261-tab.md"
printf '%s\n' '### Task 1: stray fence' 'STRAY-BODY' '```' '## Orchestrator steps' 'STRAY-TEXT' > "$TMP/plan-261-stray.md"
# A heredoc in a fence hides its document: the inner closer would otherwise close the outer fence
# and the document's next "## " would cut the task mid-file. Shifts and here-strings open nothing.
printf '%s\n' '### Task 1: heredoc' '```bash' "cat > f <<'EOF'" '```sh' 'inner' '```' '## Quoted section' 'TAIL' 'EOF' '```' 'STEP-2' \
  '### Notes' 'NOTES-BODY' '~~~ `x`' '## Tilde info quoted' '~~~' 'AFTER-TILDE' '```' 'echo $((1<<n)) ; a << b ; cat <<<word' '```' 'AFTER-SHIFT' \
  '## Orchestrator steps' 'HEREDOC-TRAILING' > "$TMP/plan-261-heredoc.md"
printf '%s\n' '### Task 1: heredoc variants' '```' 'cat <<-"END"' '```' '## Dash quoted' '	END' 'python3 - <<PY' '## Python quoted' 'PY' '```' 'VARIANTS-AFTER' '## Trailing' 'VARIANTS-TRAILING' > "$TMP/plan-261-heredoc2.md"
run_261() { # <plan> <task id>
  rm -f "$CTX_DIR"/*
  out="$(PATH="$TMP/ctxbin:$PATH" "$SELF_DIR/coding-build-phase.sh" codex "$1" "$repo261" "$2" --build-cmd true 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] || { echo "$out"; echo "FAIL: #261 $1 phase should exit 0, got $rc"; exit 1; }
}
run_261 "$TMP/plan-261-closers.md" 1
expect_261 "$CTX_DIR/1" want '## Phase 1 quoted' '## Self-Review quoted' '## Info not a closer' AFTER-INFO '## Longer closer' AFTER-LONG '## Indented fence' '## Four spaces not a closer' AFTER-INDENT
expect_261 "$CTX_DIR/1" deny '## Four spaces not an opener' INDENT-TRAILING
printf '%s\n' "$out" | grep -qF 'task 1 stops at heading: ## Four spaces not an opener' || { echo "$out"; echo "FAIL: #261 the stopping heading should be named"; exit 1; }
run_261 "$TMP/plan-261-heredoc.md" 1
expect_261 "$CTX_DIR/1" want '## Quoted section' TAIL EOF STEP-2 '### Notes' NOTES-BODY '## Tilde info quoted' AFTER-TILDE AFTER-SHIFT
expect_261 "$CTX_DIR/1" deny '## Orchestrator steps' HEREDOC-TRAILING
run_261 "$TMP/plan-261-heredoc2.md" 1
expect_261 "$CTX_DIR/1" want '## Dash quoted' '## Python quoted' VARIANTS-AFTER
expect_261 "$CTX_DIR/1" deny VARIANTS-TRAILING
run_261 "$TMP/plan-261-phase.md" 1
expect_261 "$CTX_DIR/1" want PHASE-BODY
expect_261 "$CTX_DIR/1" deny PHASE-TEXT
run_261 "$TMP/plan-261-self.md" 1
expect_261 "$CTX_DIR/1" want SELF-BODY
expect_261 "$CTX_DIR/1" deny SELF-REVIEW-TEXT
run_261 "$TMP/plan-261-tab.md" 1
expect_261 "$CTX_DIR/1" want '## Tab quoted' TAB-AFTER
expect_261 "$CTX_DIR/1" deny TAB-TRAILING
run_261 "$TMP/plan-261-stray.md" 1
expect_261 "$CTX_DIR/1" want STRAY-TEXT
printf '%s\n' "$out" | grep -qF 'task 1 ends inside an open code fence' || { echo "$out"; echo "FAIL: #261 an open fence at the end of a block should warn"; exit 1; }
run_261 "$TMP/plan-261.md" 1
! printf '%s\n' "$out" | grep -qF 'open code fence' || { echo "$out"; echo "FAIL: #261 a balanced block must not warn"; exit 1; }
unset CTX_DIR
echo "test #261 task block ends at a level-2 heading outside a fence PASS"

# #234: unavailable agents block either phase mode without committing.
printf '#!/usr/bin/env bash\nexit 6\n' > "$TMP/bin/coding-dispatch.sh"
for mode234 in in-place worktree; do
  repo234="$TMP/phase234-$mode234"; new_phase_repo "$repo234"
  head234="$(git -C "$repo234" rev-parse HEAD)"
  args234=(); [ "$mode234" != worktree ] || args234=(--worktree)
  out="$(PATH="$TMP/bin:$PATH" "$SELF_DIR/coding-build-phase.sh" codex "$TMP/plan.md" "$repo234" 1 ${args234[@]+"${args234[@]}"} --build-cmd true 2>&1)"; rc=$?
  [ "$rc" -eq 6 ] && printf '%s\n' "$out" | grep -qF 'PHASE=blocked-unavailable:1' || { echo "FAIL: #234 $mode234 rc=$rc $out"; exit 1; }
  [ "$(git -C "$repo234" rev-parse HEAD)" = "$head234" ] && [ "$(git -C "$repo234" rev-list --all --count)" -eq 1 ] || { echo 'FAIL: #234 phase committed'; exit 1; }
  echo "test #234 $mode234 PASS"
done

echo "ALL PASS"
