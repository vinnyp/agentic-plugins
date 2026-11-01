#!/usr/bin/env bash
set -eu
id=edit-keep-fail
mode=edit
# shellcheck source=agent-dispatch/test/conformance/edit-fixture.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/edit-fixture.sh"
"$IMPL_BIN/coding-dispatch.sh" --keep-on-fail codex "$SCN_REPO" "$SCN_TMP/brief" "false"
