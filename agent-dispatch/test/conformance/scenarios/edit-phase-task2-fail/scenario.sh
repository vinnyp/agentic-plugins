#!/usr/bin/env bash
set -eu
id=edit-phase-task2-fail
mode=task2
# shellcheck source=agent-dispatch/test/conformance/edit-fixture.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/edit-fixture.sh"
printf "### Task 2: Second\nEdit tracked.txt.\n" >> "$SCN_TMP/plan"
"$IMPL_BIN/coding-build-phase.sh" codex "$SCN_TMP/plan" "$SCN_REPO" 1 2 --build-cmd true
