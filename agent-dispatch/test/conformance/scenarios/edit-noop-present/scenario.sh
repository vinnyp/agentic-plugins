#!/usr/bin/env bash
set -eu
id=edit-noop-present
mode=noop
# shellcheck source=agent-dispatch/test/conformance/edit-fixture.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/edit-fixture.sh"
"$IMPL_BIN/coding-dispatch.sh" ${flags[@]+"${flags[@]}"} codex "$SCN_REPO" "$SCN_TMP/brief" "$gate"
