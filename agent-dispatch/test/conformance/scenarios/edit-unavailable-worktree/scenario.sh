#!/usr/bin/env bash
set -eu
id=edit-unavailable-worktree
mode=unavailable
# shellcheck source=agent-dispatch/test/conformance/edit-fixture.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/edit-fixture.sh"
"$IMPL_BIN/coding-dispatch.sh" --worktree codex "$SCN_REPO" "$SCN_TMP/brief" "true"
