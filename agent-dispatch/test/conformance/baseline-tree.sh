#!/usr/bin/env bash
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
if [ "$#" = 2 ] && [ "$1" = --remove ]; then
  repo=$(git -C "$here" rev-parse --show-toplevel)
  git -C "$repo" worktree remove -- "$2"
elif [ "$#" = 1 ]; then
  case "$1" in -*) echo 'usage: baseline-tree.sh <dir> | --remove <dir>' >&2; exit 2 ;; esac
  [ -f "$here/BASELINE" ] || { echo 'missing BASELINE file' >&2; exit 2; }
  sha=$(sed -n 's/^sha=//p' "$here/BASELINE")
  case "$sha" in ''|*[!0-9a-fA-F]*) echo 'BASELINE must contain a full SHA' >&2; exit 2 ;; esac
  [ "${#sha}" = 40 ] || exit 2
  repo=$(git -C "$here" rev-parse --show-toplevel)
  git -C "$repo" worktree add --detach -- "$1" "$sha"
else
  echo 'usage: baseline-tree.sh <dir> | --remove <dir>' >&2
  exit 2
fi
