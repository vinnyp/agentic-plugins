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

marker_for_workdir() {
  local workdir="$1" git_dir
  git_dir="$(git -C "$workdir" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  printf '%s/review-pinned\n' "$git_dir"
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

cmd="${1:-}"
workdir="${2:-}"

[ -n "$cmd" ] || { usage; exit 2; }
[ -n "$workdir" ] || { usage; exit 2; }

DISPATCH_REVIEW_PIN_TTL_SECS="${DISPATCH_REVIEW_PIN_TTL_SECS:-14400}"
case "$DISPATCH_REVIEW_PIN_TTL_SECS" in
  ''|*[!0-9]*) die2 "DISPATCH_REVIEW_PIN_TTL_SECS must be a non-negative integer" ;;
esac

marker="$(marker_for_workdir "$workdir")" || die2 "not a git repo: $workdir"
now="$(date +%s)"

case "$cmd" in
  pin)
    label=""
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --label)
          [ "$#" -ge 2 ] || die2 "--label requires a value"
          label="$2"
          shift 2
          ;;
        *)
          usage
          exit 2
          ;;
      esac
    done

    if load_marker "$marker"; then
      if pin_is_stale "$now"; then
        rm -f "$marker"
      else
        die2 "active review pin exists at $marker"
      fi
    fi

    sha="$(git -C "$workdir" rev-parse HEAD 2>/dev/null)" || die2 "could not resolve HEAD in $workdir"
    (
      set -C
      {
        printf 'sha=%s\n' "$sha"
        printf 'pinned_at=%s\n' "$now"
        printf 'pid=%s\n' "$$"
        printf 'label=%s\n' "$label"
      } > "$marker"
    ) 2>/dev/null || die2 "active review pin exists at $marker"
    ;;
  release)
    [ "$#" -eq 2 ] || { usage; exit 2; }
    rm -f "$marker"
    ;;
  status)
    [ "$#" -eq 2 ] || { usage; exit 2; }
    if ! load_marker "$marker"; then
      exit 1
    fi
    age="$(pin_age "$now")"
    if pin_is_stale "$now"; then
      printf 'stale age=%s\n' "$age"
      rm -f "$marker"
      exit 1
    fi
    print_status
    ;;
  *)
    usage
    exit 2
    ;;
esac
