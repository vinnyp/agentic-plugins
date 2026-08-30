#!/usr/bin/env bash
set -uo pipefail

_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  case "$_src" in /*) ;; *) _src="$_dir/$_src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/gate-env.sh"

die() {
  printf 'gate-run: %s\n' "$1" >&2
  exit 2
}

expect_root=""
no_venv=0
while [ $# -gt 0 ]; do
  case "$1" in
    --expect-root)
      [ $# -ge 2 ] || die "--expect-root requires a path"
      expect_root="$2"
      expect_root="$(git -C "$expect_root" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$expect_root")"
      shift 2
      ;;
    --no-venv)
      no_venv=1
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      die "usage: gate-run.sh [--expect-root <path>] [--no-venv] -- <command...>"
      ;;
  esac
done

[ $# -gt 0 ] || die "usage: gate-run.sh [--expect-root <path>] [--no-venv] -- <command...>"

# #180: pin the gate command to the workdir's own venv (if it has one) instead of running
# with whatever python3/ruff the launching shell happened to have on PATH, and disclose the
# resolved tools before the gate runs so a false red is diagnosable, not just recoverable
# from the reflog. gate-run always executes in the caller's cwd (it never `cd`s), so that IS
# the workdir the gate command sees.
gate_env_apply "$PWD" "$no_venv"
gate_env_disclose

command_text="$*"
runner='
stamp_top() {
  git rev-parse --show-toplevel 2>/dev/null || printf "<none>"
}
stamp_head() {
  git rev-parse HEAD 2>/dev/null || printf "<none>"
}

pre_pwd="$PWD"
pre_top="$(stamp_top)"
pre_head="$(stamp_head)"
printf "GATE_TREE_PRE pwd=%s top=%s head=%s\n" "$pre_pwd" "$pre_top" "$pre_head" >&2

gate_epilogue() {
  gate_rc="$1"
  trap - EXIT
  post_pwd="$PWD"
  post_top="$(stamp_top)"
  post_head="$(stamp_head)"
  printf "GATE_TREE_POST pwd=%s top=%s head=%s code=%s\n" "$post_pwd" "$post_top" "$post_head" "$gate_rc" >&2
  if [ "$post_top" != "$pre_top" ]; then
    printf "GATE_TREE_MOVED pre_top=%s post_top=%s\n" "$pre_top" "$post_top" >&2
  fi
  if [ -n "$expect_root" ] && [ "$post_top" != "$expect_root" ]; then
    printf "GATE_TREE_UNTRUSTWORTHY expected_top=%s post_top=%s code=%s\n" "$expect_root" "$post_top" "$gate_rc" >&2
    exit 2
  fi
  exit "$gate_rc"
}

expect_root="$1"
trap '\''gate_epilogue "$?"'\'' EXIT
'
runner="$runner
$command_text
"
runner="$runner"'
gate_rc=$?
gate_epilogue "$gate_rc"
'

bash -o pipefail -c "$runner" gate-run "$expect_root"
