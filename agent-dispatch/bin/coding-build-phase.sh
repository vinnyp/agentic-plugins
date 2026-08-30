#!/usr/bin/env bash
# coding-build-phase.sh — drive a coding agent (codex/agy) through a set of plan tasks.
#
# Usage: coding-build-phase.sh <codex|agy> <plan.md> <repo-dir> <task-id...> [--worktree] --build-cmd "<gate cmd>"
#   e.g. coding-build-phase.sh codex .../plan.md ~/Projects/myrepo 2 3 4 5 6 --build-cmd "pytest -q"
#
# For each task id: extract that task's block VERBATIM from the plan, wrap it with the
# delegation contract, dispatch via coding-dispatch.sh (build gate + git net), and on
# success commit. Stops on the first failure (dispatch already reverted/salvaged the tree).
# Honors phase-boundary checkpoints: the caller passes one phase's task ids per run.
#
#   --worktree: run the whole phase in ONE isolated worktree outside the checkout
#     (<repo>/../.worktrees/<slug>), so a hard-revert can't touch a concurrent session's
#     uncommitted work. Each task's commit lands IN the worktree (the branch accumulates);
#     parent main is untouched until the orchestrator lands the printed branch.
set -uo pipefail

_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  case "$_src" in /*) ;; *) _src="$_dir/$_src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
# shellcheck disable=SC1091  # dynamic source path ($SCRIPT_DIR); resolved at runtime
. "$SCRIPT_DIR/lib/hash.sh"

refuse_if_review_pinned() {
  local dir="$1" status sha="" pinned_at="" label="" line key value now age
  status="$("$SCRIPT_DIR/review-pin.sh" status "$dir" 2>/dev/null)" || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      sha) sha="$value" ;;
      pinned_at) pinned_at="$value" ;;
      label) label="$value" ;;
    esac
  done <<< "$status"
  now="$(date +%s)"
  case "$pinned_at" in
    ''|*[!0-9]*) age="unknown" ;;
    *) age="$((now - pinned_at))s" ;;
  esac
  printf 'PHASE=refused: review pin active on %s (sha=%s label=%s age=%s)\n' "$dir" "${sha:-unknown}" "${label:-}" "$age" >&2
  printf 'Clear it with: %s/review-pin.sh release %q\n' "$SCRIPT_DIR" "$dir" >&2
  exit 9
}

agent="${1:?usage: <codex|agy> <plan.md> <repo-dir> <task-id...> [--worktree] --build-cmd \"<gate cmd>\"}"
# Trap: --worktree (or any flag) placed before the positionals causes $agent to get the flag
# value and $plan to get "codex", producing a misleading "plan not found: codex" error.
# Flags (--worktree, --build-cmd, --no-recall, --recall-project) MUST appear AFTER the
# positionals: coding-build-phase.sh <codex|agy> <plan.md> <repo-dir> <task-id...> --worktree --build-cmd "..."
case "$agent" in --*) echo "coding-build-phase: ERROR — flag '$agent' must come AFTER the positionals: <codex|agy> <plan.md> <repo-dir> <task-id...> [--worktree] [--build-cmd ...]"; exit 2 ;; esac
plan="${2:?plan.md}"; repo="${3:?repo-dir}"; shift 3
[ -f "$plan" ] || { echo "PHASE=error: plan not found: $plan"; exit 2; }
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "PHASE=error: not a git repo: $repo"; exit 2; }
refuse_if_review_pinned "$repo"
# Commit scope: derive from the repo dir basename (override with CODING_COMMIT_SCOPE).
SCOPE="${CODING_COMMIT_SCOPE:-$(basename "$repo")}"

BUILD_CMD="${CODING_BUILD_CMD:-}"
WORKTREE=0
NO_RECALL=0
task_ids=()
while [ $# -gt 0 ]; do
  case "$1" in
    --build-cmd) [ $# -ge 2 ] || { echo "coding-build-phase: --build-cmd needs a value"; exit 2; }; BUILD_CMD="$2"; shift 2 ;;
    --worktree) WORKTREE=1; shift ;;
    --no-recall) NO_RECALL=1; shift ;;
    --recall-project) RECALL_PROJECT="$2"; printf 'coding-build-phase: recall is retired; the flag is accepted and ignored.\n' >&2; shift 2 ;;
    *) task_ids+=("$1"); shift ;;
  esac
done
: "$SCRIPT_DIR" "$NO_RECALL" "${RECALL_PROJECT:-}"
[ -n "$BUILD_CMD" ] || { echo "coding-build-phase: --build-cmd \"<cmd>\" required (or set CODING_BUILD_CMD); no stack auto-detect"; exit 2; }
[ "${#task_ids[@]}" -gt 0 ] || { echo "PHASE=error: no task-ids given"; exit 2; }
_phase_default_timeout="$([ "$agent" = agy ] && echo 25m || echo 20m)"

if [ "$WORKTREE" -eq 1 ]; then
  # One stable worktree for the whole phase; coding-dispatch.sh reuses it per task.
  # MUST resolve WT_DIR EXACTLY as coding-dispatch.sh does (show-toplevel + pwd -P) or a
  # symlinked repo path diverges and the per-task commit strands the work (B2).
  CODING_DISPATCH_WORKTREE="phase-$(basename "$repo")-$(date +%Y%m%d%H%M%S)-$$"
  export CODING_DISPATCH_WORKTREE
  _repo_root="$(git -C "$repo" rev-parse --show-toplevel)"
  _repo_basename=$(basename "$_repo_root" | tr -cs 'A-Za-z0-9_-' '_')
  _repo_hash=$(printf '%s' "$_repo_root" | md5_hex | cut -c1-8)
  WT_DIR="$(cd "$_repo_root/.." && pwd -P)/.worktrees/${_repo_basename}_${_repo_hash}/$CODING_DISPATCH_WORKTREE"
fi

tmp="$(mktemp -d)"

# extract_task <id>: print the plan block from "### Task <id>:" up to (not incl.) the next
# "### Task ", "## Phase", or "## Self-Review". Anchored colon distinguishes 13 from 13b.
extract_task() {
  awk -v t="^### Task ${1}:" '
    $0 ~ t {f=1; print; next}
    f && (/^### Task /||/^## Phase/||/^## Self-Review/) {exit}
    f {print}
  ' "$plan"
}

strip_fences() {
  awk '
    /^```/ { in_fence = !in_fence; next }
    !in_fence { print }
  '
}

json_string() {
  jq -Rs .
}

for tid in ${task_ids[@]+"${task_ids[@]}"}; do
  body="$(extract_task "$tid")"
  if [ -z "$body" ]; then echo "PHASE=error: Task $tid not found in plan"; exit 2; fi
  pf="$tmp/task-$tid.prompt"
  {
    echo "You are implementing ONE task from an implementation plan, EXACTLY as written."
    echo "Create/modify ONLY the files named in the task, write the test(s) first, then the"
    echo "implementation, then ensure the build gate ('$BUILD_CMD') passes."
    echo "Match the given code; fix only genuine compile errors."
    echo
    echo "CONSTRAINTS:"
    echo "- Do NOT run git commit / git push / git add."
    echo "- Touch ONLY the files named in the task."
    echo "- SKIP any step explicitly marked (optional) or 'NOT wired by default' (e.g. an optional"
    echo "  provider in a separate sub-package that would add a new dependency). Implement only the"
    echo "  REQUIRED steps + their tests; do not add deps the required steps don't need."
    echo "- On success ONLY (build gate green), write _coding-result.json in the"
    echo "  repo root: {\"status\":\"complete\",\"files_written\":[...],\"timestamp\":\"<ISO8601 UTC>\"}"
    echo "  If anything fails, do NOT write that file."
    echo
    echo "TASK SPEC (verbatim from the plan — follow it exactly, including the code blocks):"
    echo "======================================================================"
    printf '%s\n' "$body"
  } > "$pf"

  echo "════════ dispatching Task $tid → $agent ════════"
  if [ "$WORKTREE" -eq 1 ]; then
    CODING_DISPATCH_TIMEOUT="${CODING_DISPATCH_TIMEOUT:-$_phase_default_timeout}" coding-dispatch.sh --worktree "$agent" "$repo" "$pf" "$BUILD_CMD"
    _dispatch_rc=$?
    if [ "$_dispatch_rc" -eq 0 ]; then
      ( cd "$WT_DIR" && git add -A && git commit -q -m "feat($SCOPE): Task $tid via $agent" )
      echo "✓ Task $tid committed in worktree ($(git -C "$WT_DIR" rev-parse --short HEAD))"
    elif [ "$_dispatch_rc" -eq 9 ]; then
      echo "PHASE=refused: review pin active on $repo" >&2
      exit 9
    else
      echo "✗ Task $tid FAILED (dispatch salvaged the worktree; see path above). Stopping phase — Opus takes this task."
      echo "PHASE=stopped-at:$tid"
      exit 1
    fi
  else
    CODING_DISPATCH_TIMEOUT="${CODING_DISPATCH_TIMEOUT:-$_phase_default_timeout}" coding-dispatch.sh "$agent" "$repo" "$pf" "$BUILD_CMD"
    _dispatch_rc=$?
    if [ "$_dispatch_rc" -eq 0 ]; then
      ( cd "$repo" && git add -A && git commit -q -m "feat($SCOPE): Task $tid via $agent" )
      echo "✓ Task $tid committed ($(git -C "$repo" rev-parse --short HEAD))"
    elif [ "$_dispatch_rc" -eq 9 ]; then
      echo "PHASE=refused: review pin active on $repo" >&2
      exit 9
    else
      echo "✗ Task $tid FAILED (dispatch reverted the tree). Stopping phase — Opus takes this task."
      echo "PHASE=stopped-at:$tid"
      exit 1
    fi
  fi
done

if [ "$WORKTREE" -eq 1 ]; then
  echo "PHASE=ok worktree=$WT_DIR branch=$CODING_DISPATCH_WORKTREE tasks=[${task_ids[*]}] — land with: git -C '$repo' merge --ff-only '$CODING_DISPATCH_WORKTREE' && git -C '$repo' worktree remove '$WT_DIR'"
else
  echo "PHASE=ok: tasks [${task_ids[*]}] complete"
fi
