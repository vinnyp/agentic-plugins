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
if [ "${1:-}" = --remove ]; then
  [ "$#" = 3 ] || exit 64
  review_clone_guarded_rm "$2" "$3"
else
  if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then exit 64; fi
  review_clone_build "$@"
fi
