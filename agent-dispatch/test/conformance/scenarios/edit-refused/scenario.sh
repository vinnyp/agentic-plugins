#!/usr/bin/env bash
set -eu
id=edit-refused
mode=empty
# shellcheck source=agent-dispatch/test/conformance/edit-fixture.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/edit-fixture.sh"
"$IMPL_BIN/review-pin.sh" pin "$SCN_REPO" --label capture >/dev/null
"$IMPL_BIN/coding-dispatch.sh" ${flags[@]+"${flags[@]}"} codex "$SCN_REPO" "$SCN_TMP/brief" "$gate"
