#!/usr/bin/env bash
# coding-build-phase.sh — drive a coding agent (codex/agy) through a set of plan tasks.
#
# Usage: coding-build-phase.sh <codex|agy> <plan.md> <repo-dir> <task-id...> [--worktree] --build-cmd "<gate cmd>"
#   e.g. coding-build-phase.sh codex .../plan.md ~/Projects/myrepo 2 3 4 5 6 --build-cmd "pytest -q"
#
# For each task id: extract that task's block VERBATIM from the plan, wrap it with the
# delegation contract and the plan's preamble (text above the first task: goal, spec path,
# global constraints; capped by CODING_BUILD_PLAN_CONTEXT_MAX, default 12000 chars), dispatch via coding-dispatch.sh (build gate + git net), and on
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
  local pin_rc=0
  status="$("$SCRIPT_DIR/review-pin.sh" status "$dir" 2>/dev/null)" || pin_rc=$?
  case "$pin_rc" in
    0) ;;
    1|2) return 0 ;;
    *) echo "could not determine review pin status for $dir; refusing edits" >&2; exit 9 ;;
  esac
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
plan="$(cd "$(dirname "$plan")" && pwd -P)/$(basename "$plan")"
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

# extract_preamble: print the plan text above the first "### Task " heading — the plan's
# Goal, spec path and Global Constraints, which no task block carries (vinnyp/foundry#237).
# In worker banners, remove driver instructions but preserve spec references and
# other worker guidance. Frontmatter is metadata, not worker context.
extract_preamble() {
  awk '
    function filter_line(line) {
      if (line ~ /^>/ && !quote) banner=(line ~ /^> \*\*For [Aa]gentic workers/)
      quote=(line ~ /^>/)
      if (!quote) banner=0
      if (banner && line ~ /REQUIRED SUB-SKILL|superpowers:|Executed unattended|coding-build-phase.sh|reaches the coding agent/) {
        # Rescue every reference on the dropped line, independent of prose casing.
        for (key in seen) delete seen[key]
        rest=line
        while (match(rest, /\[\[[^]]+\]\]/)) {
          token=substr(rest, RSTART, RLENGTH)
          if (!seen[token]++) print "> Spec: " token
          rest=substr(rest, RSTART + RLENGTH)
        }
        rest=line
        while (match(rest, /[^][()<>*"\047`[:space:]]+\.md(#[^][()<>*"\047`[:space:]]*)?/)) {
          token=substr(rest, RSTART, RLENGTH)
          rest=substr(rest, RSTART + RLENGTH)
          sub(/#.*/, "", token)
          if (token ~ /\// && !seen[token]++) print "> Spec: " token
        }
        return
      }
      print line
    }
    {sub(/\r$/, "")}
    NR == 1 && $0 == "---" {frontmatter=1; buffered=$0; next}
    frontmatter {
      if ($0 == "---") {frontmatter=0; buffered=""; next}
      if ($0 ~ /^### Task /) exit
      buffered=buffered ORS $0
      next
    }
    /^### Task / {exit}
    {filter_line($0)}
    END {
      if (buffered != "") {
        count=split(buffered, lines, ORS)
        for (i=1; i<=count; i++) filter_line(lines[i])
      }
    }
  ' "$plan"
}
PLAN_CONTEXT_MAX="${CODING_BUILD_PLAN_CONTEXT_MAX:-12000}"
case "$PLAN_CONTEXT_MAX" in ''|*[!0-9]*) echo "PHASE=error: CODING_BUILD_PLAN_CONTEXT_MAX must be a whole number of characters"; exit 2 ;; esac
PLAN_CONTEXT_MAX=$((10#$PLAN_CONTEXT_MAX))
[ "$PLAN_CONTEXT_MAX" -gt 0 ] || { echo "PHASE=error: CODING_BUILD_PLAN_CONTEXT_MAX must be a positive whole number of characters"; exit 2; }
plan_context="$(extract_preamble)"
# Whitespace-only preamble = no plan context block at all.
case "$plan_context" in *[![:space:]]*) ;; *) plan_context="" ;; esac
plan_context_note=""
if [ "${#plan_context}" -gt "$PLAN_CONTEXT_MAX" ]; then
  plan_context_note="[plan context truncated: first $PLAN_CONTEXT_MAX of ${#plan_context} characters shown — read the full plan at $plan]"
  echo "WARNING: ${plan_context_note#\[}" | sed 's/]$//'
  plan_context="${plan_context:0:$PLAN_CONTEXT_MAX}"
fi

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
    if [ -n "$plan_context" ]; then
      echo "PLAN CONTEXT (shared by every task — goal, spec and global constraints):"
      echo "Any instructions addressed to the orchestrator (which skill to run, how to invoke"
      echo "the build driver) are not for you. The touch-only constraint above still applies."
      echo "If the plan context and the task spec conflict, stop and report the conflict"
      echo "instead of guessing; do not claim success."
      echo "======================================================================"
      printf '%s\n' "$plan_context"
      [ -z "$plan_context_note" ] || printf '%s\n' "$plan_context_note"
      echo
    fi
    echo "TASK SPEC (verbatim from the plan — follow it exactly, including the code blocks):"
    echo "======================================================================"
    printf '%s\n' "$body"
  } > "$pf"

  # Lower-case subject: config-conventional's subject-case rejects "Task N" (#242).
  commit_subject="feat($SCOPE): task $tid via $agent"
  echo "════════ dispatching Task $tid → $agent ════════"
  if [ "$WORKTREE" -eq 1 ]; then
    CODING_DISPATCH_TIMEOUT="${CODING_DISPATCH_TIMEOUT:-$_phase_default_timeout}" coding-dispatch.sh --worktree "$agent" "$repo" "$pf" "$BUILD_CMD"
    _dispatch_rc=$?
    if [ "$_dispatch_rc" -eq 0 ]; then
      ( cd "$WT_DIR" && git add -A && git commit -q -m "$commit_subject" )
      echo "✓ Task $tid committed in worktree ($(git -C "$WT_DIR" rev-parse --short HEAD))"
    elif [ "$_dispatch_rc" -eq 6 ]; then
      echo "✗ Task $tid BLOCKED: agent unavailable (capacity/rate limit) — per AGENTS.md, finish this task locally, then resume the phase at the next task."
      echo "PHASE=blocked-unavailable:$tid"
      exit 6
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
      ( cd "$repo" && git add -A && git commit -q -m "$commit_subject" )
      echo "✓ Task $tid committed ($(git -C "$repo" rev-parse --short HEAD))"
    elif [ "$_dispatch_rc" -eq 6 ]; then
      echo "✗ Task $tid BLOCKED: agent unavailable (capacity/rate limit) — per AGENTS.md, finish this task locally, then resume the phase at the next task."
      echo "PHASE=blocked-unavailable:$tid"
      exit 6
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
