#!/usr/bin/env bash
set -eu
id=edit-phase-three
mode=edit
# shellcheck source=agent-dispatch/test/conformance/edit-fixture.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/edit-fixture.sh"
printf "### Task 2: Second\nEdit tracked.txt.\n### Task 3: Third\nEdit tracked.txt.\n" >> "$SCN_TMP/plan"
"$IMPL_BIN/coding-build-phase.sh" codex "$SCN_TMP/plan" "$SCN_REPO" 1 2 3 --build-cmd true
