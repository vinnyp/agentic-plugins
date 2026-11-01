#!/usr/bin/env bash
set -eu
id=edit-phase-usage
mode=empty
# shellcheck source=agent-dispatch/test/conformance/edit-fixture.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/edit-fixture.sh"
"$IMPL_BIN/coding-build-phase.sh" --worktree codex "$SCN_TMP/plan" "$SCN_REPO" 1 --build-cmd true
