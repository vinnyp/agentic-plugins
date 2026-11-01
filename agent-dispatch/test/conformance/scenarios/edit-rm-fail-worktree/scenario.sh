#!/usr/bin/env bash
set -eu
id=edit-rm-fail-worktree
mode=edit
# shellcheck source=agent-dispatch/test/conformance/edit-fixture.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/edit-fixture.sh"
export CODING_DISPATCH_RM_ON_FAIL=1
"$IMPL_BIN/coding-dispatch.sh" --worktree codex "$SCN_REPO" "$SCN_TMP/brief" "false"
