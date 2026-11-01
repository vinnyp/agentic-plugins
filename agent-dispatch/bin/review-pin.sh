#!/usr/bin/env bash
# review-pin.sh — mark a worktree read-only while review is pinned to HEAD.
set -uo pipefail

usage() {
  echo "usage: review-pin.sh pin <workdir> [--label <text>] | release <workdir> | status <workdir>" >&2
}

die2() {
  echo "review-pin: $1" >&2
  exit 2
}

load_marker() {
  local marker="$1" key value
  sha=""
  pinned_at=""
  pid=""
  label=""

  [ -f "$marker" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      sha) sha="$value" ;;
      pinned_at) pinned_at="$value" ;;
      pid) pid="$value" ;;
      label) label="$value" ;;
    esac
  done < "$marker"
}

pin_age() {
  local now="$1"
  case "$pinned_at" in
    ''|*[!0-9]*) printf '%s\n' "$((DISPATCH_REVIEW_PIN_TTL_SECS + 1))" ;;
    *) printf '%s\n' "$((now - pinned_at))" ;;
  esac
}

pin_is_stale() {
  local now="$1" age
  age="$(pin_age "$now")"
  [ "$age" -gt "$DISPATCH_REVIEW_PIN_TTL_SECS" ]
}

print_status() {
  printf 'sha=%s\n' "$sha"
  printf 'pinned_at=%s\n' "$pinned_at"
  printf 'pid=%s\n' "$pid"
  printf 'label=%s\n' "$label"
}

# Resolve and operate in one bounded child; git failures are tagged payloads.
review_pin_operation() {
  local cmd=$1 workdir=$2 marker=$3 sha=$4 requested_label=$5 script_pid=$6 now
  local pinned_at pid label age git_dir git_rc=0
  if [ -z "$marker" ]; then
    git_dir=$(_repo_state_git -C "$workdir" rev-parse --absolute-git-dir 2>/dev/null) || git_rc=$?
    if [ "$git_rc" != 0 ]; then
      REPO_STATE_BOUND_OUT="gitdir-rc $git_rc"
      return 2
    fi
    marker=$git_dir/review-pinned
    if [ "$cmd" = pin ]; then
      sha=$(_repo_state_git -C "$workdir" rev-parse --verify HEAD 2>/dev/null) || git_rc=$?
      if [ "$git_rc" != 0 ]; then
        REPO_STATE_BOUND_OUT="head-rc $git_rc"
        return 2
      fi
    fi
  fi
  now=$(date +%s)
  case "$cmd" in
    pin)
      local requested_sha=$sha
      if load_marker "$marker"; then
        if pin_is_stale "$now"; then rm -f "$marker"
        else REPO_STATE_BOUND_OUT="active review pin exists at $marker"; return 2; fi
      fi
      sha=$requested_sha
      (
        set -C
        printf 'sha=%s\npinned_at=%s\npid=%s\nlabel=%s\n' "$sha" "$now" "$script_pid" "$requested_label" > "$marker"
      ) 2>/dev/null || { REPO_STATE_BOUND_OUT="active review pin exists at $marker"; return 2; }
      ;;
    release) rm -f "$marker" ;;
    status)
      load_marker "$marker" || return 1
      age=$(pin_age "$now")
      if pin_is_stale "$now"; then
        REPO_STATE_BOUND_OUT="stale age=$age"
        rm -f "$marker"
        return 1
      fi
      REPO_STATE_BOUND_OUT=$(print_status)
      ;;
  esac
}

_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  case "$_src" in /*) ;; *) _src="$_dir/$_src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
# shellcheck source=lib/repo-state.sh
. "$SCRIPT_DIR/lib/repo-state.sh"
trap repo_state_cancel_bound EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
cmd=${1:-}
[ "$#" -gt 0 ] && shift
case "$cmd" in pin|release|status) ;; *) usage; exit 2 ;; esac
workdir='' marker='' sha='' label=''
if [ "$#" -gt 0 ] && [ "$1" != --marker ]; then workdir=$1; shift; fi
while [ "$#" -gt 0 ]; do
  [ "$cmd" = pin ] || { usage; exit 2; }
  [ "$#" -ge 2 ] || die2 "$1 requires a value"
  case "$1" in
    --marker|--sha)
      case "$2" in ''|--*) die2 "$1 requires a value" ;; esac ;;
  esac
  case "$1" in
    --marker) marker=$2 ;;
    --sha) sha=$2 ;;
    --label) label=$2 ;;
    *) usage; exit 2 ;;
  esac
  shift 2
done
if [ -n "$marker" ] || [ -n "$sha" ]; then
  [ "$cmd" = pin ] && [ -n "$marker" ] && [ -n "$sha" ] || { usage; exit 2; }
else
  [ -n "$workdir" ] || { usage; exit 2; }
fi
DISPATCH_REVIEW_PIN_TTL_SECS=${DISPATCH_REVIEW_PIN_TTL_SECS:-14400}
case "$DISPATCH_REVIEW_PIN_TTL_SECS" in ''|*[!0-9]*) die2 'DISPATCH_REVIEW_PIN_TTL_SECS must be a non-negative integer' ;; esac
# shellcheck disable=SC2034
REPO_STATE_BOUND_VARS=DISPATCH_REVIEW_PIN_TTL_SECS
# shellcheck disable=SC2034
REPO_STATE_BOUND_FUNCS='load_marker pin_age pin_is_stale print_status'
rc=0
repo_state_run_bounded "$(repo_state_snapshot_limit review-pin 120)" review_pin_operation "$cmd" "$workdir" "$marker" "$sha" "$label" "$$" || rc=$?
case "$rc" in
  124) echo 'review-pin: git setup timed out (DISPATCH_SNAPSHOT_TIMEOUT_SECS)' >&2; exit 3 ;;
  125) echo 'review-pin: git setup could not complete (DISPATCH_SNAPSHOT_TIMEOUT_SECS)' >&2; exit 3 ;;
esac
if [ -n "$REPO_STATE_BOUND_OUT" ]; then
  case "$REPO_STATE_BOUND_OUT" in
    gitdir-rc*) echo "review-pin: not a git repo: $workdir" >&2 ;;
    head-rc*) echo "review-pin: could not resolve HEAD in $workdir" >&2 ;;
    *) if [ "$cmd" = status ]; then printf '%s\n' "$REPO_STATE_BOUND_OUT"; else echo "review-pin: $REPO_STATE_BOUND_OUT" >&2; fi ;;
  esac
fi
exit "$rc"
