#!/usr/bin/env bash
# coding-dispatch.sh — deterministic snapshot → delegate → validate → revert cycle
# for ONE coding task. The PROMPT (real code + constraints + marker instruction) is
# authored by the caller (Opus); this script owns only the mechanics + safety net.
#
# Usage: coding-dispatch.sh [--worktree] [--base <ref>] [--allow-stale-base] [--keep-on-fail] [--no-venv] <codex|agy> <workdir> <prompt-file> [build-cmd]
#   --worktree: run the whole cycle inside an isolated git worktree placed OUTSIDE the
#     parent checkout (<repo>/../.worktrees/<slug>), so the hard-revert can NEVER touch a
#     concurrent session's uncommitted work in the shared checkout. The parent need NOT be
#     clean. On success the worktree + branch are LEFT for the caller to land (no auto-merge).
#     Slug = $CODING_DISPATCH_WORKTREE (default cd-<ts>-$$); a worktree with that slug is
#     REUSED across calls so a multi-task phase accumulates commits on one branch.
#   --base <ref>: in --worktree mode, create the isolated branch from <ref> instead of HEAD.
#     The ref is checked against its existing local upstream tracking ref when one is present.
#   --allow-stale-base: in --worktree mode, permit a base behind its local tracking ref while
#     still printing the staleness.
#   --keep-on-fail: skip the hard-revert on a gate failure entirely (non-worktree mode only —
#     worktree/TDD failures are already left in place for salvage). Leaves the tree exactly as
#     the agent left it for inspection; the caller is responsible for cleaning it up afterward.
#   --no-venv: don't prepend <workdir>/.venv/bin to the gate's PATH — run the build-cmd gate
#     with the inherited PATH exactly as the launching shell had it (see #180). Same effect as
#     env DISPATCH_NO_VENV=1.
#   build-cmd: the gate; if given it ALWAYS runs. With none, falls back to "go build ./... && go vet ./..." only when go.mod is present.
#     When <workdir>/.venv/bin exists, the gate runs with it prepended to PATH (unless
#     --no-venv/DISPATCH_NO_VENV) and prints a "gate-env: python=... ruff=..." disclosure line
#     to stderr naming the resolved tools before the gate runs (#180) — the interpreter/tool
#     mismatch that caused a false-red hard-revert of a clean build is now visible up front.
#   env CODING_DISPATCH_TIMEOUT    (default 15m) — internal per-dispatch agent timeout.
#   env CODING_DISPATCH_WORKTREE   (worktree mode) — stable per-phase branch/worktree slug.
#   env CODING_DISPATCH_RM_ON_FAIL (worktree mode) — 1 = remove the worktree on build failure
#     instead of salvaging the diff IN the worktree; the patch itself still survives (written
#     under the PARENT repo's git dir, keyed by slug) — see #118 (FINDING 3 fix).
#   env CODING_DISPATCH_CHILD_ENV  whitespace-separated KEY=VALUE pairs exported into the
#     dispatched agent's environment (e.g. CODING_DISPATCH_CHILD_ENV="MYREPO_LEDGER=off").
#     Values cannot contain whitespace (the format is whitespace-separated); malformed
#     entries are reported on stderr and skipped.
#   env AGY_MODEL                  overrides agy model for agy dispatches (default "Gemini 3.5 Flash (Medium)")
#   env DISPATCH_NO_VENV           1 = same as --no-venv (see above; #180)
#
# The prompt MUST instruct the agent to:
#   - NOT run git commit / git push / git add
#   - on success ONLY, write _coding-result.json in the workdir:
#       {"status":"complete","files_written":[...],"timestamp":"<ISO8601Z>"}
#
# Exit 0   = success: changes left in the tree (or worktree) for the caller to review + commit.
#            (also covers a legitimate no-op — DISPATCH=ok-noop — see below.)
# Exit 1   = failure: non-worktree → tree hard-reset to pre-dispatch HEAD (unless
#            --keep-on-fail, which leaves the tree exactly as the agent left it); worktree →
#            diff SALVAGED in the worktree, OR — with CODING_DISPATCH_RM_ON_FAIL=1 — the worktree
#            is removed but the patch still survives under the PARENT repo's git dir. EVERY gate
#            failure first snapshots a pre-revert `<git-dir>/coding-dispatch-last-fail.patch` (via
#            `git diff "$BASE"` against a throwaway index copy — never the real one, see #118
#            FINDING 2 — which covers committed TDD work too) so a reverted/discarded/removed
#            build stays inspectable — see #118.
# Exit 2   = usage / environment error: no changes made.
#
# DISPATCH=ok-noop (exit 0): a RESUME dispatch found the prior work already complete — rc=0,
# empty diff, but a present + parseable _coding-result.json marker. Distinct from
# DISPATCH=fail: empty diff, which still fires for a genuine no-marker no-op/failure (#128b).
# Exit 143 = killed by INT/TERM mid-dispatch; worktree mode's trap removed a fresh empty
#            worktree (a partial diff is left for salvage instead). NOTE: the internal agent
#            timeout kills the AGENT (not this script), after which we fall through to the
#            normal empty/salvage exits — the trap covers the SCRIPT-killed path (Ctrl-C /
#            a killed phase), not the agent-hang path.
#
# The 3-strike circuit breaker is the CALLER's responsibility (count exit-1s; after 3
# consecutive, stop delegating and finish the task yourself). See the README.
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

die() { printf 'DISPATCH=error: %s\n' "$1" >&2; exit 2; }
note() { printf '%s\n' "$*" >&2; }

resolve_worktree_base() {
  WORKTREE_BASE_REF="${BASE_REF:-HEAD}"
  WORKTREE_BASE_SHA="$(git rev-parse --verify "${WORKTREE_BASE_REF}^{commit}" 2>/dev/null)" \
    || die "invalid --base ref: $WORKTREE_BASE_REF"
  WORKTREE_BASE_SHORT="$(git rev-parse --short "$WORKTREE_BASE_SHA")" \
    || die "cannot shorten resolved base: $WORKTREE_BASE_REF"
  note "DISPATCH_BASE base_ref=$WORKTREE_BASE_REF base_sha=$WORKTREE_BASE_SHORT"
}

worktree_base_branch() {
  case "$WORKTREE_BASE_REF" in
    HEAD)
      git symbolic-ref --quiet --short HEAD 2>/dev/null || true
      ;;
    refs/heads/*)
      if git show-ref --verify --quiet "$WORKTREE_BASE_REF"; then
        printf '%s\n' "${WORKTREE_BASE_REF#refs/heads/}"
      fi
      ;;
    *)
      if git show-ref --verify --quiet "refs/heads/$WORKTREE_BASE_REF"; then
        printf '%s\n' "$WORKTREE_BASE_REF"
      fi
      ;;
  esac
}

check_worktree_base_freshness() {
  local branch upstream_short upstream_full remote merge_ref tracking_sha behind_count
  local comparison="last-fetched" timeout_bin="" fetch_rc
  branch="$(worktree_base_branch)"
  if [ -z "$branch" ]; then
    note "DISPATCH_BASE_TRACKING base_ref=$WORKTREE_BASE_REF status=no-upstream"
    return 0
  fi
  upstream_short="$(git for-each-ref --format='%(upstream:short)' "refs/heads/$branch")"
  if [ -z "$upstream_short" ]; then
    upstream_full="refs/remotes/origin/$branch"
    if git show-ref --verify --quiet "$upstream_full"; then
      upstream_short="origin/$branch"
      remote="origin"
      merge_ref="refs/heads/$branch"
    else
      note "DISPATCH_BASE_TRACKING base_ref=$WORKTREE_BASE_REF branch=$branch status=no-upstream"
      return 0
    fi
  else
    upstream_full="$(git rev-parse --symbolic-full-name "$upstream_short" 2>/dev/null)"
    remote="$(git config --get "branch.$branch.remote" || true)"
    merge_ref="$(git config --get "branch.$branch.merge" || true)"
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout_bin="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin="gtimeout"
  fi
  if [ -n "$timeout_bin" ] && [ -n "$remote" ] && [ "$remote" != "." ] \
     && [ -n "$merge_ref" ] && [ -n "$upstream_full" ]; then
    "$timeout_bin" 5s git fetch --quiet "$remote" "$merge_ref:$upstream_full" </dev/null
    fetch_rc=$?
    if [ "$fetch_rc" -eq 0 ]; then
      comparison="fetched"
    else
      note "DISPATCH""_BASE_FETCH base_ref=$WORKTREE_BASE_REF tracking_ref=$upstream_short status=failed rc=$fetch_rc; continuing with last-fetched tracking ref"
    fi
  else
    note "DISPATCH""_BASE_FETCH base_ref=$WORKTREE_BASE_REF tracking_ref=$upstream_short status=failed reason=bounded-fetch-unavailable; continuing with last-fetched tracking ref"
  fi
  tracking_sha="$(git rev-parse --verify "${upstream_short}^{commit}" 2>/dev/null)" || {
    note "DISPATCH_BASE_TRACKING base_ref=$WORKTREE_BASE_REF branch=$branch tracking_ref=$upstream_short status=tracking-ref-absent"
    return 0
  }
  behind_count="$(git rev-list --count "$WORKTREE_BASE_SHA..$tracking_sha" 2>/dev/null || printf '0')"
  if [ "$behind_count" -gt 0 ]; then
    note "DISPATCH_BASE_STALE base_ref=$WORKTREE_BASE_REF base_sha=$WORKTREE_BASE_SHORT tracking_ref=$upstream_short tracking_sha=$(git rev-parse --short "$tracking_sha") behind=$behind_count comparison=$comparison"
    if [ "$ALLOW_STALE_BASE" -ne 1 ]; then
      die "worktree base $WORKTREE_BASE_REF ($WORKTREE_BASE_SHORT) is behind last fetched $upstream_short by $behind_count commit(s) (comparison=$comparison); fetch+rebase, pass --base, or pass --allow-stale-base"
    fi
    return 0
  fi
  note "DISPATCH_BASE_TRACKING base_ref=$WORKTREE_BASE_REF tracking_ref=$upstream_short status=not-behind comparison=$comparison"
}

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
  printf 'DISPATCH=refused: review pin active on %s (sha=%s label=%s age=%s)\n' "$dir" "${sha:-unknown}" "${label:-}" "$age" >&2
  printf 'Clear it with: %s/review-pin.sh release %q\n' "$SCRIPT_DIR" "$dir" >&2
  exit 9
}

matches_allowlist() {
  local f="$1"; shift
  for _pat in "$@"; do
    # SC2254: unquoted intentional — we want glob semantics (e.g. "bin/**" matches "bin/foo.sh")
    # shellcheck disable=SC2254
    case "$f" in $_pat) return 0 ;; esac
  done
  return 1
}

WORKTREE=0
KEEP_ON_FAIL=0
BASE_REF=""
ALLOW_STALE_BASE=0
NO_VENV=0
allow_paths=()
require_files=()
_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) WORKTREE=1; shift ;;
    --base) [ $# -ge 2 ] || die "--base requires a ref argument"; BASE_REF="$2"; shift 2 ;;
    --allow-stale-base) ALLOW_STALE_BASE=1; shift ;;
    --keep-on-fail) KEEP_ON_FAIL=1; shift ;;
    --no-venv) NO_VENV=1; shift ;;
    --allow-path) [ $# -ge 2 ] || die "--allow-path requires a pattern argument"; allow_paths+=("$2"); shift 2 ;;
    --require-file) [ $# -ge 2 ] || die "--require-file requires a path argument"; require_files+=("$2"); shift 2 ;;
    *) _args+=("$1"); shift ;;
  esac
done
set -- ${_args[@]+"${_args[@]}"}

agent="${1:-}"; workdir="${2:-}"; prompt_file="${3:-}"
build_cmd="${4:-}"
TIMEOUT="${CODING_DISPATCH_TIMEOUT:-15m}"

command -v jq >/dev/null 2>&1 || die "jq is required"
[ -n "$agent" ] && [ -n "$workdir" ] && [ -n "$prompt_file" ] || die "usage: coding-dispatch.sh [--worktree] [--base <ref>] [--allow-stale-base] <codex|agy> <workdir> <prompt-file> [build-cmd]"
case "$agent" in codex|agy) ;; *) die "unknown agent '$agent' (use: codex|agy)";; esac
[ "$WORKTREE" -eq 1 ] || [ -z "$BASE_REF" ] || die "--base requires --worktree"
[ "$WORKTREE" -eq 1 ] || [ "$ALLOW_STALE_BASE" -eq 0 ] || die "--allow-stale-base requires --worktree"
if [ -z "${CODING_DISPATCH_TIMEOUT:-}" ]; then
  if [ "$agent" = "agy" ]; then TIMEOUT="25m"; else TIMEOUT="15m"; fi
fi

# #128a: a --build-cmd matching a known slow-gate shape commonly outruns the default internal
# timeout (observed: `make test` ~14m alone blew the 15m default and surfaced as two rc=124
# rounds, reported only as a generic empty-diff fail). Warn loudly whenever the timeout is
# STILL the default — an explicit CODING_DISPATCH_TIMEOUT means the caller already accounted
# for it, so stay quiet.
_is_slow_gate_cmd() {
  case "$1" in
    *"make test"*|*"make check"*) return 0 ;;
  esac
  case "$1" in
    *"go test ./..."*) case "$1" in *-run*) return 1 ;; esac; return 0 ;;
  esac
  case "$1" in
    *pytest*) case "$1" in *::*) return 1 ;; esac; return 0 ;;
  esac
  return 1
}
if [ -n "$build_cmd" ] && [ -z "${CODING_DISPATCH_TIMEOUT:-}" ] && _is_slow_gate_cmd "$build_cmd"; then
  note "⚠ WARNING: --build-cmd '$build_cmd' matches a slow-gate heuristic and CODING_DISPATCH_TIMEOUT is still the default ($TIMEOUT) — this shape commonly exceeds the default cap (#128a); raise CODING_DISPATCH_TIMEOUT if the dispatch times out."
fi

[ -d "$workdir" ] || die "workdir not found: $workdir"
[ -f "$prompt_file" ] || die "prompt file not found: $prompt_file"

cd "$workdir" || die "cd failed: $workdir"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$workdir is not a git repo (the snapshot/revert net requires git)"
refuse_if_review_pinned "$workdir"

# Check if build command is weaker than the repository's own canonical gate (issues 155, 169)
if [ -n "$build_cmd" ]; then
  _found_targets=""
  _makefile=""
  for _m in Makefile makefile GNUmakefile; do
    if [ -f "$workdir/$_m" ]; then
      _makefile="$workdir/$_m"
      break
    fi
  done
  if [ -n "$_makefile" ]; then
    # Target-line shapes handled: `lint:`, `lint : deps` (space before the colon),
    # `pr-ready lint check:` (several targets on one line), `lint: $(DEPS)`,
    # `lint: # comment`, `test::` (double-colon rule). Deliberately NOT matched:
    # `LINT := ruff` and `LINT:= ruff` (the `[^=]` after the colon is what rejects
    # them — a naive target regex reads a variable assignment as a target), and
    # `.PHONY:` / `%.o:` (the first character class excludes `.` and `%`).
    _targets=$(sed -n -E 's/^([A-Za-z0-9_-][A-Za-z0-9_.-]*([[:space:]]+[A-Za-z0-9_.-]+)*)[[:space:]]*:([^=].*)?$/\1/p' "$_makefile" 2>/dev/null | tr -s '[:space:]' '\n')
    _makefile_targets=""
    for _t in pr-ready check ci gate lint test; do
      if echo "$_targets" | grep -q -x "$_t"; then
        _makefile_targets="${_makefile_targets:+$_makefile_targets }$_t"
      fi
    done
    if [ -n "$_makefile_targets" ]; then
      _invoked=0
      for _t in $_makefile_targets; do
        if echo "$build_cmd" | grep -q -E "(^|[^A-Za-z0-9_.-])make([^A-Za-z0-9_.-]+|[^A-Za-z0-9_.-].*[^A-Za-z0-9_.-])$_t([^A-Za-z0-9_.-]|$)"; then
          _invoked=1
          break
        fi
      done
      if [ "$_invoked" -eq 0 ]; then
        _found_targets="${_found_targets:+$_found_targets }$_makefile_targets"
      fi
    fi
  fi

  _runner=""
  for _r in bin/run-tests.sh run-tests.sh scripts/test.sh; do
    if [ -f "$workdir/$_r" ]; then
      _runner="$_r"
      break
    fi
  done
  if [ -n "$_runner" ]; then
    _runner_base="$(basename "$_runner")"
    case "$build_cmd" in
      *"$_runner_base"*) ;;
      *) _found_targets="${_found_targets:+$_found_targets }$_runner" ;;
    esac
  fi

  if [ -n "$_found_targets" ]; then
    # Marker dedupes to one advisory per (workdir, build-cmd) per TTL. If the
    # workdir has no resolvable git dir we cannot dedupe — warn anyway. The
    # advisory's whole purpose is visibility, so every failure path here
    # errs toward emitting, never toward silence.
    _git_dir="$(git -C "$workdir" rev-parse --absolute-git-dir 2>/dev/null)"
    if [ -z "$_git_dir" ]; then
      note "Advisory: --build-cmd '$build_cmd' skips gate-target(s): $_found_targets"
    else
      _advisory_marker="$_git_dir/gate-advisory"
      _should_warn=1
      _now="$(date +%s)"
      _cmd_hash=$(printf '%s' "$build_cmd" | md5_hex)
      if [ -f "$_advisory_marker" ]; then
        _stored_hash=""
        _stored_ts=""
        while IFS= read -r _line || [ -n "$_line" ]; do
          _key="${_line%%=*}"
          _value="${_line#*=}"
          case "$_key" in
            cmd_hash) _stored_hash="$_value" ;;
            timestamp) _stored_ts="$_value" ;;
          esac
        done < "$_advisory_marker"
        # A non-numeric TTL or a corrupt/truncated marker (cmd_hash present,
        # timestamp missing) must not crash the dispatch or silently
        # suppress — both fall through with _should_warn still 1.
        if [ -n "$_cmd_hash" ] && [ "$_stored_hash" = "$_cmd_hash" ]; then
          DISPATCH_GATE_ADVISORY_TTL_SECS="${DISPATCH_GATE_ADVISORY_TTL_SECS:-3600}"
          case "$DISPATCH_GATE_ADVISORY_TTL_SECS:$_stored_ts" in
            *[!0-9:]*|:*|*:) ;;
            *)
              _age=$((_now - _stored_ts))
              if [ "$_age" -ge 0 ] && [ "$_age" -lt "$DISPATCH_GATE_ADVISORY_TTL_SECS" ]; then
                _should_warn=0
              fi
              ;;
          esac
        fi
      fi
      if [ "$_should_warn" -eq 1 ]; then
        printf 'cmd_hash=%s\ntimestamp=%s\n' "$_cmd_hash" "$_now" > "$_advisory_marker" 2>/dev/null || true
        note "Advisory: --build-cmd '$build_cmd' skips gate-target(s): $_found_targets"
      fi
    fi
  fi
fi

if [ "$WORKTREE" -eq 1 ]; then
  # Isolated-worktree mode: the parent may be DIRTY (a concurrent session's uncommitted
  # work) and must survive untouched. Resolve the worktree path the SAME way the caller
  # (coding-build-phase.sh) does — physical (pwd -P) off the repo toplevel — or a symlinked
  # repo path diverges and strands the work (B2).
  PARENT_ROOT="$(git rev-parse --show-toplevel)" || die "cannot resolve parent repo root"
  SLUG="${CODING_DISPATCH_WORKTREE:-cd-$(date +%Y%m%d%H%M%S)-$$}"
  _repo_basename=$(basename "$PARENT_ROOT" | tr -cs 'A-Za-z0-9_-' '_')
  _repo_hash=$(printf '%s' "$PARENT_ROOT" | md5_hex | cut -c1-8)
  WT_DIR="$(cd "$PARENT_ROOT/.." && pwd -P)/.worktrees/${_repo_basename}_${_repo_hash}/$SLUG"
  git worktree prune
  CREATED_HERE=0
  if git worktree list --porcelain | grep -Fxq -- "worktree $WT_DIR"; then
    # Reuse (a prior task this phase). Fixed-string match (B1).
    cd "$WT_DIR" || die "cannot enter reused worktree $WT_DIR"
    [ -z "$(git status --porcelain)" ] || die "reused worktree $WT_DIR is dirty (salvaged failure?) — inspect/clean before reuse"  # (B3)
    # A reused worktree's base was fixed when it was CREATED; honoring --base here would be a
    # lie. Refuse rather than silently ignore the caller's explicit base.
    [ -z "$BASE_REF" ] || die "--base cannot apply to the reused worktree '$SLUG' (its base was set at creation); use a new CODING_DISPATCH_WORKTREE slug"
    WORKTREE_BASE_REF="reused-worktree"
    WORKTREE_BASE_SHA="$(git rev-parse HEAD)" || die "cannot resolve reused worktree HEAD"
    WORKTREE_BASE_SHORT="$(git rev-parse --short "$WORKTREE_BASE_SHA")" || die "cannot shorten reused worktree HEAD"
    note "DISPATCH_BASE base_ref=$WORKTREE_BASE_REF base_sha=$WORKTREE_BASE_SHORT"
  elif [ -e "$WT_DIR" ] || git show-ref --verify --quiet "refs/heads/$SLUG"; then
    die "worktree path or branch '$SLUG' exists but is not our active worktree — refusing to clobber"
  else
    mkdir -p "$(dirname "$WT_DIR")"
    resolve_worktree_base
    check_worktree_base_freshness
    git worktree add -b "$SLUG" "$WT_DIR" "$WORKTREE_BASE_SHA" >&2 || die "git worktree add failed"
    CREATED_HERE=1
    cd "$WT_DIR" || die "cannot enter new worktree $WT_DIR"
  fi
  BASE="$(git rev-parse HEAD)"
  # shellcheck disable=SC2329 # invoked indirectly by the signal trap below
  cleanup_signal() {
    trap - INT TERM EXIT
    cd "$PARENT_ROOT" 2>/dev/null || true   # never operate from a dir we may remove
    if [ "$CREATED_HERE" -eq 1 ] && [ -z "$(git -C "$WT_DIR" status --porcelain 2>/dev/null)" ] \
       && [ "$(git -C "$WT_DIR" rev-parse HEAD 2>/dev/null)" = "$BASE" ]; then
      git -C "$PARENT_ROOT" worktree remove --force "$WT_DIR" 2>/dev/null
      note "↩ signal: removed empty worktree $WT_DIR"
    else
      note "↩ signal: salvageable work left in $WT_DIR (branch $SLUG) — remove with: git -C $PARENT_ROOT worktree remove --force $WT_DIR"
    fi
    exit 143
  }
  trap cleanup_signal INT TERM
else
  # In-place mode: require a clean tree — the revert net hard-resets to HEAD, which would
  # also nuke pre-existing uncommitted work. Plan execution commits per task, so this holds.
  if [ -n "$(git status --porcelain)" ]; then
    die "working tree not clean — commit or stash before dispatch (the revert net hard-resets to HEAD), or use --worktree"
  fi
  BASE="$(git rev-parse HEAD)"
fi
rm -f _coding-result.json

# Builder disclosure injection: every coding-dispatch brief carries the
# author-wrote-both declaration. The scope block remains conditional.
_injected_prompt="$(mktemp -t coding-dispatch-brief.XXXXXX)"
{
  echo "## Builder self-declaration (REQUIRED)"
  echo "If you authored both the fix and the tests that verify it, say so explicitly and name the mutation that should catch a regression in the changed code."
  echo "If you shipped no new tests, say so explicitly."
  echo ""
  if [ ${#allow_paths[@]} -gt 0 ]; then
    echo "## Scope constraint (REQUIRED)"
    echo "ONLY touch files matching these patterns (relative to repo root):"
    for _p in "${allow_paths[@]}"; do echo "  - $_p"; done
    echo "Do NOT create, edit, or delete any file outside these patterns, even if it seems helpful."
    echo ""
  fi
  cat "$prompt_file"
} > "$_injected_prompt"
_effective_prompt="$_injected_prompt"
trap 'rm -f "$_injected_prompt"' EXIT

if command -v shasum >/dev/null 2>&1; then
  _brief_hash="$(shasum -a 256 "$prompt_file" 2>/dev/null | cut -c1-12)"
else
  _brief_hash="$(cksum "$prompt_file" 2>/dev/null | awk '{print $1}' | cut -c1-12)"
fi
note "▶ brief fingerprint: $_brief_hash ($(wc -c < "$prompt_file" | tr -d ' ')B); first line: $(head -1 "$prompt_file")"

TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
target="$PWD"   # the worktree in --worktree mode, else == $workdir (we cd'd there above)
# Child-environment hook: CODING_DISPATCH_CHILD_ENV is a whitespace-separated list of
# KEY=VALUE pairs exported into the dispatched agent's environment. Use it when the target
# repo's own tooling needs a variable pinned for the duration of a dispatch — the motivating
# case was a repo whose test runner appends to a shared results ledger, which an ad-hoc
# dispatch must not write to (an earlier incident polluted that ledger twice, and the rows
# had to be removed by hand). Repo-specific knowledge belongs to the caller, so the caller
# names the variables; the dispatcher only forwards them.
if [ -n "${CODING_DISPATCH_CHILD_ENV:-}" ]; then
  # Split with `read -ra`, NOT `for _kv in $VAR`. An unquoted expansion in a for-list is
  # subject to PATHNAME EXPANSION, so the caller's value is rewritten by whatever happens to
  # be in the workdir: with a file named `MSG=hi` present, `MSG=h?` silently becomes `MSG=hi`,
  # and a stray `*` fans out into one bogus entry per file. `read -ra` splits on IFS only.
  # `-d ''` (read to NUL, which a here-string has none of, hence `|| true`) means a value
  # spanning newlines is still split in full rather than truncated at the first line.
  _child_env_pairs=()
  read -ra _child_env_pairs -d '' <<< "$CODING_DISPATCH_CHILD_ENV" || true
  _child_env_last_key=""
  for _kv in ${_child_env_pairs[@]+"${_child_env_pairs[@]}"}; do
    _k="${_kv%%=*}"
    case "$_kv" in
      *=*) ;;
      *)
        # A bare word right after a well-formed pair is almost always a value with a space in
        # it (`MSG=hello world`), which the whitespace-separated format cannot carry. Say that,
        # and name the KEY whose value was cut — "ignoring 'world'" alone hides the real damage.
        if [ -n "$_child_env_last_key" ]; then
          note "⚠ CODING_DISPATCH_CHILD_ENV: ignoring '$_kv' (expected KEY=VALUE) — values cannot contain whitespace, so $_child_env_last_key was set to the text before the space and the rest was dropped"
        else
          note "⚠ CODING_DISPATCH_CHILD_ENV: ignoring '$_kv' (expected KEY=VALUE)"
        fi
        continue ;;
    esac
    case "$_k" in
      ''|*[!A-Za-z0-9_]*|[0-9]*)
        note "⚠ CODING_DISPATCH_CHILD_ENV: ignoring '$_kv' (invalid variable name)"; _child_env_last_key=""; continue ;;
    esac
    export "${_k}=${_kv#*=}"
    _child_env_last_key="$_k"
    note "▶ child env: $_k set from CODING_DISPATCH_CHILD_ENV"
  done
fi
if [ "$agent" = "agy" ]; then
  note "agy model: ${AGY_MODEL:-Gemini 3.5 Flash (Medium)}"
  case "${AGY_MODEL:-Gemini 3.5 Flash (Medium)}" in
    *Pro*) note "⚠ a deep/slow agy model (Pro) often exceeds the default watchdog — raise CODING_DISPATCH_TIMEOUT if it times out" ;;
  esac
fi
note "▶ dispatching to $agent in $target (timeout $TIMEOUT, base ${BASE:0:12})…"

case "$agent" in
  codex)
    if [ -n "$TIMEOUT_BIN" ]; then
      "$TIMEOUT_BIN" -k 30s "$TIMEOUT" codex exec --dangerously-bypass-approvals-and-sandbox -C "$target" - < "$_effective_prompt"
    else
      note "⚠ no timeout/gtimeout binary — codex hang cannot be externally bounded (brew install coreutils)"
      codex exec --dangerously-bypass-approvals-and-sandbox -C "$target" - < "$_effective_prompt"
    fi
    ;;
  agy)
    # BARE STDIN is the only form agy 1.1.22 accepts. Do NOT reintroduce --print: it now
    # takes the NEXT TOKEN as its prompt, so `--print --dangerously-skip-permissions` makes
    # agy treat the flag as the prompt and IGNORE stdin entirely (rc=2). `exec` and a bare
    # `-` are rejected as unexpected positionals. Verified against agy 1.1.22, 2026-08-27.
    # The _coding-result.json marker (not stdout) is the success signal — this sidesteps
    # agy's empty-stdout caveat in restricted environments. agy's OWN --print-timeout has
    # proven UNRELIABLE (observed hanging 6.5h past a 15m setting) and is tied to --print,
    # so the EXTERNAL timeout (separate process, own clock) is the real bound, as for codex.
    if [ -n "$TIMEOUT_BIN" ]; then
      "$TIMEOUT_BIN" -k 30s "$TIMEOUT" agy --model "${AGY_MODEL:-Gemini 3.5 Flash (Medium)}" --dangerously-skip-permissions --add-dir "$target" < "$_effective_prompt"
    else
      note "⚠ no timeout/gtimeout binary — agy hang cannot be externally bounded (brew install coreutils)"
      agy --model "${AGY_MODEL:-Gemini 3.5 Flash (Medium)}" --dangerously-skip-permissions --add-dir "$target" < "$_effective_prompt"
    fi
    ;;
esac
agent_rc=$?
if [ "$agent" = "agy" ] && { [ "$agent_rc" -eq 124 ] || [ "$agent_rc" -eq 137 ]; }; then
  note "agy timed out (rc=$agent_rc) — switch to a faster agy model (AGY_MODEL='Gemini 3.5 Flash (Medium)') or raise CODING_DISPATCH_TIMEOUT (current $TIMEOUT); a wedged agy may need: pkill -9 -f agy"
fi

# revert() is only safe when the worker left changes uncommitted (HEAD == BASE). In TDD mode
# the worker committed per-task; a hard-reset would discard those commits. Guard callers.
_tdd_mode() { [ "$(git rev-parse HEAD 2>/dev/null)" != "$BASE" ]; }
revert() { git reset --hard "$BASE" >/dev/null 2>&1; git clean -fd >/dev/null 2>&1; }
marker_status="$(jq -r '.status // empty' _coding-result.json 2>/dev/null || true)"

# #118: every gate failure below snapshots the diff BEFORE any revert/clean, so a discarded or
# salvaged build stays inspectable. MUST be `git diff "$BASE"` (diffs the current working tree
# against the pre-dispatch commit), not a bare `git diff` (diffs the working tree against HEAD
# only) — in TDD mode the worker COMMITS per task, so HEAD has already moved and a bare `git
# diff` would show NOTHING for exactly the case that matters (the case a prior incident missed). We
# capture the content into a variable (not a file) first because `git clean -fd` inside
# revert() would delete an untracked patch file sitting in the tree.
#
# The patch NEVER lands in the consumer's working tree. Every path writes it under the git
# directory — outside the working tree, invisible to `git status`, still inspectable — and the
# fail message prints the absolute path. Writing it into the tree (which the salvage,
# --keep-on-fail and TDD paths used to do) breaks the --keep-on-fail promise to leave the tree
# exactly as the agent left it, and risks a caller's later `git add -A` committing the patch.
# The one special case is CODING_DISPATCH_RM_ON_FAIL: the worktree (and its git directory) is
# about to be deleted, so that patch is keyed by slug under the PARENT repo's git directory.
FAIL_PATCH_NAME="coding-dispatch-last-fail.patch"
report_fail() {
  local label="$1" stream="${2:-out}" patch_content write_dir patch_path
  # `git diff <commit>` only shows paths git already KNOWS about (tracked, or staged) — a
  # brand-new untracked file (the common shape: the agent adds a file, never `git add`s it)
  # is invisible to it. `git add -N` (intent-to-add) marks new paths as known without staging
  # their content, which makes `git diff` show them as full additions. On the revert path that
  # mutation is harmless (the hard reset discards the index right after). But on every SALVAGE
  # path — --keep-on-fail, worktree without RM_ON_FAIL, TDD — no revert happens, so mutating the
  # REAL index would leave it behind permanently: an untracked file's status flips from
  # `?? file` to ` A file` and stays that way, breaking the --keep-on-fail promise to leave the
  # tree exactly as the agent left it, and changing the `git status` shape scripts/agents parse.
  # So do the intent-to-add + diff against a throwaway COPY of the index (via GIT_INDEX_FILE) —
  # the real index (including anything the agent deliberately staged) is never touched.
  local _fail_git_dir _tmp_index
  # The scratch completion marker is a dispatch artifact, not the agent's deliverable: remove it
  # before the snapshot so it never reaches the patch, and never survives into a salvaged tree
  # for a caller's `git add -A` to commit.
  rm -f _coding-result.json
  _fail_git_dir="$(git rev-parse --absolute-git-dir 2>/dev/null)"
  [ -n "$_fail_git_dir" ] || _fail_git_dir="$PWD/.git"
  _tmp_index="$(mktemp -t coding-dispatch-index.XXXXXX)"
  if [ -f "$_fail_git_dir/index" ]; then
    cp "$_fail_git_dir/index" "$_tmp_index" 2>/dev/null
  fi
  GIT_INDEX_FILE="$_tmp_index" git add -N -A . >/dev/null 2>&1
  patch_content="$(GIT_INDEX_FILE="$_tmp_index" git diff "$BASE" 2>/dev/null)"
  rm -f "$_tmp_index"
  write_dir="$_fail_git_dir"
  mkdir -p "$write_dir" 2>/dev/null
  _emit() { if [ "$stream" = err ]; then printf '%s\n' "$1" >&2; else printf '%s\n' "$1"; fi; }
  if [ "$WORKTREE" -eq 1 ]; then
    trap - INT TERM
    if [ "${CODING_DISPATCH_RM_ON_FAIL:-0}" = "1" ] && [ "$CREATED_HERE" -eq 1 ]; then
      # #118's whole point is that a gate failure stays inspectable — RM_ON_FAIL removes the
      # worktree immediately, so the patch must be written somewhere that SURVIVES the removal.
      # Land it under the PARENT repo's git dir (not the worktree being deleted), keyed by slug
      # so concurrent/sequential failures don't clobber each other.
      local _parent_git_dir
      _parent_git_dir="$(git -C "$PARENT_ROOT" rev-parse --absolute-git-dir 2>/dev/null)"
      [ -n "$_parent_git_dir" ] || _parent_git_dir="$PARENT_ROOT/.git"
      patch_path="$_parent_git_dir/coding-dispatch-fail-patches/${SLUG}.patch"
      mkdir -p "$(dirname "$patch_path")" 2>/dev/null
      printf '%s\n' "$patch_content" > "$patch_path" 2>/dev/null
      cd "$PARENT_ROOT" && git worktree remove --force "$WT_DIR" 2>/dev/null
      _emit "DISPATCH=fail: $label — worktree removed (RM_ON_FAIL); patch survives at $patch_path"
    else
      patch_path="$write_dir/$FAIL_PATCH_NAME"
      printf '%s\n' "$patch_content" > "$patch_path" 2>/dev/null
      _emit "DISPATCH=fail: $label — diff SALVAGED in $WT_DIR (branch $SLUG); remove with: git -C $PARENT_ROOT worktree remove --force $WT_DIR; patch: $patch_path"
    fi
    return
  fi
  if [ "$KEEP_ON_FAIL" -eq 1 ]; then
    patch_path="$write_dir/$FAIL_PATCH_NAME"
    printf '%s\n' "$patch_content" > "$patch_path" 2>/dev/null
    _emit "DISPATCH=fail: $label — --keep-on-fail: tree left intact (not reverted); patch: $patch_path"
  elif _tdd_mode; then
    patch_path="$write_dir/$FAIL_PATCH_NAME"
    printf '%s\n' "$patch_content" > "$patch_path" 2>/dev/null
    _emit "DISPATCH=fail: $label — TDD commits SALVAGED at HEAD $(git rev-parse HEAD | cut -c1-12) (revert manually if needed); patch: $patch_path"
  else
    revert
    patch_path="$write_dir/$FAIL_PATCH_NAME"
    printf '%s\n' "$patch_content" > "$patch_path" 2>/dev/null
    _emit "DISPATCH=fail: $label — tree reverted to ${BASE:0:12}; patch: $patch_path"
  fi
}

# Validation order (authoritative gates first; marker is belt-and-suspenders, NOT required):
#   1. non-empty change: either uncommitted diff OR HEAD advanced past BASE (TDD commits)
#   2. scope: every changed path matches --allow-path (pure git inspection, no execution)
#   3. build/vet pass (a broken build is a failure regardless of marker)
#   4. marker: if present+complete, great; if 1-3 passed, SYNTHESIZE it ourselves.
# (Regression guard: the marker-first order once hard-reverted a build that actually passed.)
# (Regression guard: a clean tree + HEAD != BASE is a TDD-commit success, not a no-op.)

# 1. A no-op is a failure (whether or not a marker was written).
# A clean working tree is NOT a failure when the worker committed its own work (TDD
# per-task commits advance HEAD past BASE). Distinguish two cases:
#   • clean tree + HEAD == BASE  → true no-op → fail
#   • clean tree + HEAD != BASE  → worker committed per-task (TDD) → continue to build gate
if [ -z "$(git status --porcelain)" ]; then
  current_head="$(git rev-parse HEAD)"
  if [ "$current_head" = "$BASE" ]; then
    # #128b: rc=0 + empty diff + a present, PARSEABLE completion marker is a legitimate no-op —
    # a RESUME dispatch found the prior work already done — not a failure. _coding-result.json
    # is gitignored in every real caller repo, so `git status --porcelain` above never saw it;
    # marker_status was already parsed (above, before this block) directly off the file, so this
    # check is independent of git's view of the tree. Keep it narrow: only rc=0 qualifies, so a
    # timed-out/crashed agent that happens to leave a stale marker never masquerades as ok-noop.
    if [ "$agent_rc" -eq 0 ] && [ -f _coding-result.json ] && [ "$marker_status" = "complete" ]; then
      rm -f _coding-result.json
      if [ "$WORKTREE" -eq 1 ]; then
        trap - INT TERM
        if [ "$CREATED_HERE" -eq 1 ]; then
          cd "$PARENT_ROOT" && git worktree remove --force "$WT_DIR" 2>/dev/null
        fi
        printf 'DISPATCH=ok-noop base_sha=%s: %s found prior work already complete (no changes needed) — worktree cleaned\n' "${WORKTREE_BASE_SHORT:-unknown}" "$agent"
        exit 0
      fi
      printf 'DISPATCH=ok-noop: %s found prior work already complete (no changes needed)\n' "$agent"
      exit 0
    fi
    # True no-op: no uncommitted changes, HEAD has not moved, and no valid completion marker.
    rm -f _coding-result.json
    _empty_reason="empty diff (agent changed nothing, rc=$agent_rc)"
    if [ "$agent_rc" -eq 124 ]; then
      _empty_reason="TIMEOUT — agent exceeded the $TIMEOUT cap (CODING_DISPATCH_TIMEOUT), rc=124, no changes produced"
    fi
    if [ "$WORKTREE" -eq 1 ]; then
      trap - INT TERM
      if [ "$CREATED_HERE" -eq 1 ]; then
        cd "$PARENT_ROOT" && git worktree remove --force "$WT_DIR" 2>/dev/null
      fi
      printf 'DISPATCH=fail: %s — worktree cleaned\n' "$_empty_reason"
      exit 1
    fi
    printf 'DISPATCH=fail: %s — nothing to revert\n' "$_empty_reason"
    exit 1
  else
    # Clean tree AND HEAD moved off BASE: either a genuine stray self-commit, OR legitimate
    # TDD work. These are NOT distinguishable by git status alone: _coding-result.json is
    # gitignored in every real caller repo (#128b), so a worker that commits per task AND
    # leaves the marker ALSO produces a byte-clean `git status` here — the marker file's
    # presence is invisible to git, not absent. (An earlier version of this comment claimed
    # TDD mode always leaves the tree dirty; that was false and contradicted #128b in this
    # same file.) So consult the completion marker (already parsed into $marker_status above,
    # independently of git's view of the tree): present + parseable + complete ⇒ legitimate
    # TDD, leave the commit(s) intact. Only unwind when no valid marker backs the commit(s) —
    # that is the real stray-commit case.
    marker_committed_since_base="$(git diff --name-only "$BASE".."$current_head" -- _coding-result.json)"
    if [ -f _coding-result.json ] && [ "$marker_status" = "complete" ] && [ -z "$marker_committed_since_base" ]; then
      note "ℹ clean tree + HEAD moved off BASE, backed by a valid completion marker — legitimate TDD commit(s), not unwinding (#118/#128b)"
    else
      commit_count="$(git rev-list "$BASE".."$current_head" --count)"
      note "⚠ worker self-committed $commit_count commit(s) without leaving working-tree changes and an independently valid marker — stray commit — unwinding via git reset --soft ${BASE:0:12}"
      git reset --soft "$BASE"
      git reset HEAD -- . 2>/dev/null || true
      note "↩ stray commit(s) unwound; $commit_count commit(s) collapsed to uncommitted changes for caller review"
    fi
  fi
fi

# Refuse to ship mutation-test sentinels before the build gate can bless a poisoned tree.
_mut_re='(//|#)[[:space:]]*MUT([[:space:]:]|$)'
_mut_hit=""
git diff "$BASE" -- 2>/dev/null | grep -qE "^\+.*$_mut_re" && _mut_hit=1
while IFS= read -r _uf; do
  [ -f "$_uf" ] && grep -qE "$_mut_re" "$_uf" && { _mut_hit=1; break; }
done < <(git ls-files --others --exclude-standard)
if [ -n "$_mut_hit" ]; then
  note "DISPATCH=fail: mutation marker (// MUT / # MUT) present in the dispatched change — a mutation-test sentinel was not restored before the build/commit. Restore the tree to its pre-mutation state and re-dispatch."
  report_fail "mutation marker"
  exit 1
fi

# 2. Scope gate: verify all changed files match the --allow-path allowlist.
# This runs BEFORE the build gate on purpose: it is pure `git status`/`git diff` with no
# execution, while the build gate runs the agent's code. An out-of-scope change must be
# refused without first executing what the agent wrote.
if [ ${#allow_paths[@]} -gt 0 ]; then
  _gate_committed=$(git diff --name-only "$BASE"..HEAD 2>/dev/null || true)
  _gate_added_intermediate=$(git log --diff-filter=A --format= --name-only "$BASE"..HEAD 2>/dev/null || true)
  # Use --porcelain=v2 + awk: catch modified (1), renamed (2), and untracked (?) files
  # split on tab first to handle rename records (type 2): "newPath\toldPath" → emit only newPath
  _gate_status=$(git status --porcelain=v2 2>/dev/null | awk '/^[12?] / {split($NF,a,"\t"); print a[1]}' || true)
  _gate_out=$(printf '%s\n%s\n%s\n' "$_gate_committed" "$_gate_added_intermediate" "$_gate_status" | sed '/^$/d' | sort -u)
  while IFS= read -r _f; do
    [ -z "$_f" ] && continue
    if ! matches_allowlist "$_f" "${allow_paths[@]}"; then
      printf 'DISPATCH=fail: scope gate: out-of-scope file changed: %s\n' "$_f" >&2
      report_fail "scope gate violation" err
      exit 1
    fi
  done <<< "$_gate_out"
fi

# A gate that materializes files from HEAD cannot see the normal uncommitted
# coding-dispatch result. Warn only for the known HEAD-derived command shapes;
# the tree is expected to be dirty here, so dirtiness alone is not actionable.
if [ -n "$build_cmd" ] && [ -n "$(git status --porcelain)" ]; then
  case "$build_cmd" in
    *"git archive"*HEAD*|*"worktree add"*HEAD*)
      note "⚠ WARNING: HEAD-derived build command will not include the worker's uncommitted changes: $build_cmd"
      ;;
  esac
fi

# 3. Build/vet gate. An explicit build_cmd is AUTHORITATIVE and always runs.
if [ -z "$build_cmd" ] && [ -f go.mod ]; then
  build_cmd="go build ./... && go vet ./..."
fi
_gate_run_args=(--expect-root "$target")
[ "$NO_VENV" -eq 1 ] && _gate_run_args+=(--no-venv)
if [ -n "$build_cmd" ] && ! "$SCRIPT_DIR/gate-run.sh" "${_gate_run_args[@]}" -- "$build_cmd"; then
  report_fail "build/vet failed ($build_cmd)"
  exit 1
fi

# FM4: partial-delivery check — verify all required files were delivered
if [ ${#require_files[@]} -gt 0 ]; then
  _fm4_committed=$(git diff --name-only "$BASE"..HEAD 2>/dev/null || true)
  _fm4_added_intermediate=$(git log --diff-filter=A --format= --name-only "$BASE"..HEAD 2>/dev/null || true)
  # split on tab first to handle rename records (type 2): "newPath\toldPath" → emit only newPath
  _fm4_status=$(git status --porcelain=v2 2>/dev/null | awk '/^[12?] / {split($NF,a,"\t"); print a[1]}' || true)
  _fm4_changed=$(printf '%s\n%s\n%s\n' "$_fm4_committed" "$_fm4_added_intermediate" "$_fm4_status" | sed '/^$/d' | sort -u)
  for _req in "${require_files[@]}"; do
    if ! printf '%s\n' "$_fm4_changed" | grep -qxF "$_req"; then
      printf 'DISPATCH=fail: FM4: required file %q not delivered (not in diff since %s)\n' "$_req" "${BASE:0:12}" >&2
      report_fail "FM4" err
      exit 1
    fi
  done
fi

# 4. Marker: synthesize it ourselves if the passing build lacks one.
if [ ! -f _coding-result.json ] || [ "$marker_status" != "complete" ]; then
  # For a clean tree with per-task commits, git status is empty — read committed files instead.
  if [ -z "$(git status --porcelain)" ] && [ "$(git rev-parse HEAD)" != "$BASE" ]; then
    diff_files="$(git diff --name-only "$BASE"..HEAD | jq -R . | jq -s -c .)"
    note "ℹ no/incomplete marker, build passed (TDD commits) — marker synthesized from committed diff"
  else
    diff_files="$(git status --porcelain | sed 's/^...//' | jq -R . | jq -s -c .)"
    note "ℹ no/incomplete marker, but diff + build passed — marker synthesized from the diff"
  fi
  jq -n --argjson files "$diff_files" \
     '{status:"complete", files_written:$files, timestamp:(now|todateiso8601), synthesized_by:"coding-dispatch.sh"}' \
     > _coding-result.json
fi

files="$(jq -r '.files_written // [] | join(", ")' _coding-result.json 2>/dev/null || true)"
# Remove the scratch marker now that files= is read: the exit code (0) is the success
# signal. Leaving it would let the caller's `git add -A` commit it into the landed branch,
# and on a REUSED worktree the next dispatch's `rm -f` of a now-tracked marker would make a
# genuine no-op look like a change (defeating the empty-diff guard + the 3-strike breaker).
rm -f _coding-result.json
if [ "$WORKTREE" -eq 1 ]; then
  trap - INT TERM
  printf 'DISPATCH=ok worktree_ns=%s worktree=%s branch=%s base_sha=%s head=%s files=%s\n' "$WT_DIR" "$WT_DIR" "$SLUG" "${WORKTREE_BASE_SHORT:-unknown}" "$(git rev-parse HEAD)" "${files:-unknown}"
  exit 0
fi
printf 'DISPATCH=ok: %s completed; files: %s; changes left for caller to review + commit\n' "$agent" "${files:-unknown}"
exit 0
