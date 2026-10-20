#!/usr/bin/env bash
set -euo pipefail
_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  case "$_src" in /*) ;; *) _src="$_dir/$_src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
# shellcheck source=agent-dispatch/bin/lib/review-clone.sh
. "$SCRIPT_DIR/lib/review-clone.sh"
usage() {
  printf '%s\n' 'usage: review-clone.sh <source-worktree> <dest> [<sha>] | --remove <parent> <path>'
}
if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi
if [ "${1:-}" = --remove ]; then
  [ "$#" = 3 ] || { usage >&2; exit 64; }
  review_clone_guarded_rm "$2" "$3"
else
  if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then usage >&2; exit 64; fi
  review_clone_build "$@"
  printf '%s %s\n' "$2" "$REVIEW_CLONE_SHA"
fi
