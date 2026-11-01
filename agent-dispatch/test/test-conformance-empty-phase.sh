#!/usr/bin/env bash
set -eu
here=$(CDPATH='' cd "$(dirname "$0")" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/conformance-empty-phase.XXXXXX")
[ -n "$work" ] || exit 1
trap 'rm -rf "$work"' EXIT
mkdir "$work/repo"
git -C "$work/repo" init -q
printf '### Task 1: Fixture\n' > "$work/plan"
# case: empty-task-list
for interpreter in "$BASH" /bin/bash; do
  [ -x "$interpreter" ] || continue
  rc=0
  "$interpreter" "$here/../bin/coding-build-phase.sh" codex "$work/plan" "$work/repo" --build-cmd true > "$work/output" 2>&1 || rc=$?
  [ "$rc" = 2 ] && grep -qx 'PHASE=error: no task-ids given' "$work/output" || {
    cat "$work/output"; echo 'FAIL: empty task list diagnostic'; exit 1;
  }
done
echo 'PASS conformance empty phase'
