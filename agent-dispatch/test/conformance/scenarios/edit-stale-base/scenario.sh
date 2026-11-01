#!/usr/bin/env bash
set -eu
id=edit-stale-base
mode=edit
# shellcheck source=agent-dispatch/test/conformance/edit-fixture.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/edit-fixture.sh"
git -C "$SCN_REPO" -c user.name=Conformance -c user.email=conformance@example.invalid commit --allow-empty -qm upstream
git -C "$SCN_REPO" update-ref refs/remotes/origin/main HEAD
git -C "$SCN_REPO" branch old HEAD~1
git -C "$SCN_REPO" update-ref refs/remotes/origin/old HEAD
"$IMPL_BIN/coding-dispatch.sh" --worktree --base old codex "$SCN_REPO" "$SCN_TMP/brief" "true"
