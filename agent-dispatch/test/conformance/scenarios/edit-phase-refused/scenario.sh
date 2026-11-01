#!/usr/bin/env bash
set -eu
id=edit-phase-refused
mode=empty
# shellcheck source=agent-dispatch/test/conformance/edit-fixture.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/edit-fixture.sh"
"$IMPL_BIN/review-pin.sh" pin "$SCN_REPO" --label capture >/dev/null
"$IMPL_BIN/coding-build-phase.sh" codex "$SCN_TMP/plan" "$SCN_REPO" 1 ${flags[@]+"${flags[@]}"} --build-cmd true
