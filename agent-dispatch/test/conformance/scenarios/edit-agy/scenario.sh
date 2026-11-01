#!/usr/bin/env bash
set -eu
id=edit-agy
mode=edit
# shellcheck source=agent-dispatch/test/conformance/edit-fixture.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/edit-fixture.sh"
cp "$SCN_TMP/bin/codex" "$SCN_TMP/bin/agy"
export AGY_MODEL=fixture-model
"$IMPL_BIN/coding-dispatch.sh"  agy "$SCN_REPO" "$SCN_TMP/brief" "true"
