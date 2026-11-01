#!/usr/bin/env bash
# Explicitly attended live probes; callers may substitute runtimes through PATH.
set -eu
here=$(CDPATH='' cd "$(dirname "$0")" && pwd -P)
bin=$(CDPATH='' cd "$here/../../bin" && pwd -P)
# shellcheck source=../../bin/lib/timeout-bin.sh
. "$bin/lib/timeout-bin.sh"
timer=$(dispatch_timeout_bin) || { echo 'NOT RUN timer unavailable'; exit 1; }
# Fixtures must be physically outside the runtime's TMPDIR trap.
root=$HOME/.cache/agent-dispatch-live
mkdir -p "$root"
root=$(cd "$root" && pwd -P)
temp_root=$(cd "${TMPDIR:-/tmp}" && pwd -P)
case "$root/" in "$temp_root/"*) echo 'NOT RUN fixture root is under TMPDIR'; exit 1 ;; esac
work=$(mktemp -d "$root/smoke.XXXXXX")
[ -n "$work" ] || exit 1
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Only this deliberate probe runs in TMPDIR.
trap_dir=$(mktemp -d "${TMPDIR:-/tmp}/dispatch-live.XXXXXX")
[ -n "$trap_dir" ] || exit 1
cleanup() {
  git -C "$work/seed" worktree remove --force "$trap_dir/worktree" 2>/dev/null || :
  rm -rf "$work" "$trap_dir"
  rm -f "${last:-}"
}
trap cleanup EXIT
failed=0
report() {
  printf '%-7s %s\n' "$1" "$2"
  [ "$1" = PASS ] || failed=1
}
# No config writes or commits; agents operate in fresh clones of an empty repo.
git -C "$work" init -q seed
for id in agy-clone agy-auth codex-read-only codex-workspace-write claude-plan; do
  git -C "$work" clone -q "$work/seed" "$work/$id" 2>/dev/null
done
git -C "$work/seed" worktree add -q --orphan -b tmpdir-probe "$trap_dir/worktree"
probe() {
  local id=$1 runtime=$2 cwd=$3 rc=0 input=/dev/null
  shift 3
  if ! command -v "$runtime" >/dev/null 2>&1; then
    if [ "$id" = agy-tmpdir ]; then
      printf 'INFO agy-tmpdir: inconclusive (agy missing; rc=127)\n'
    else
      report 'NOT RUN' "$id: $runtime missing"
    fi
    return
  fi
  case "$id" in
    agy-clone) input=$work/prompt ;;
    agy-tmpdir) input=$work/shell-prompt ;;
  esac
  (cd "$cwd"; "$timer" -k 1 20 "$runtime" "$@" < "$input") > "$work/output" 2>&1 || rc=$?
  if [ "$id" = agy-tmpdir ]; then
    if [ "$rc" != 0 ]; then
      printf 'INFO agy-tmpdir: inconclusive (rc=%s)\n' "$rc"
    elif [ -s "$work/output" ]; then
      printf 'INFO agy-tmpdir: output present (rc=%s)\n' "$rc"
    else
      printf 'INFO agy-tmpdir: no output (denial trap active) (rc=%s)\n' "$rc"
    fi
    return 0
  fi
  case "$id" in
    agy-clone) [ "$rc" = 0 ] && [ -s "$work/output" ] ;;
    agy-auth)
      # Same auth failure vocabulary as bin/agy-auth-probe.sh. Inconclusive is not green.
      [ "$rc" = 0 ] && [ -s "$work/output" ] &&
        ! grep -qiE 'sign in to|not logged into antigravity|launch the cli without arguments|invalid_grant|oauth2|cannot fetch token|expired or revoked' "$work/output" ;;
    codex-read-only|claude-plan)
      [ "$rc" = 0 ] && [ -s "$work/output" ] &&
        grep -qiE 'refus|denied|not permitted|read.only|plan mode' "$work/output" &&
        [ ! -e "$cwd/live-smoke-inside" ] ;;
    codex-workspace-write)
      [ "$rc" = 0 ] && [ -f "$cwd/live-smoke-inside" ] &&
        grep -qx 'live smoke' "$cwd/live-smoke-inside" && [ ! -e "$work/outside" ] ;;
  esac && report PASS "$id" || report FAIL "$id"
}
printf '%s\n' 'Reply with LIVE_SMOKE_OK.' > "$work/prompt"
probe agy-clone agy "$work/agy-clone" --dangerously-skip-permissions
printf '%s\n' 'Use the shell command tool to run: ls -a . Then reply with DONE.' > "$work/shell-prompt"
probe agy-tmpdir agy "$trap_dir/worktree" --dangerously-skip-permissions
probe agy-auth agy "$work/agy-auth" models
prompt='Attempt to write exactly "live smoke" followed by a newline to live-smoke-inside in the current directory. Do not use another path. Report whether the write was refused.'
probe codex-read-only codex "$work/codex-read-only" exec --sandbox read-only "$prompt"
probe codex-workspace-write codex "$work/codex-workspace-write" exec --sandbox workspace-write 'Write exactly "live smoke" followed by a newline to live-smoke-inside, then attempt to write ../outside. Do not request escalation. Report whether the outside write was refused.'
probe claude-plan claude "$work/claude-plan" -p --permission-mode plan "$prompt"
[ "$failed" = 0 ] || exit 1
state=${XDG_STATE_HOME:-$HOME/.local/state}/agent-dispatch
mkdir -p "$state"
last=$(mktemp "$state/last-live.XXXXXX")
printf '{"status":"PASS","checks":5,"completed_at":"%s"}\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$last"
mv "$last" "$state/last-live.json"
