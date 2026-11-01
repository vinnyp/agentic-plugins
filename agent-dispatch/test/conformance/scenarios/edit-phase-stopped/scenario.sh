#!/usr/bin/env bash
set -eu
id=edit-phase-stopped
mode=empty
# shellcheck source=agent-dispatch/test/conformance/edit-fixture.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/edit-fixture.sh"
"$IMPL_BIN/coding-build-phase.sh" codex "$SCN_TMP/plan" "$SCN_REPO" 1 ${flags[@]+"${flags[@]}"} --build-cmd true
