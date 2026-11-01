#!/usr/bin/env bash
set -eu
id=edit-timeout
mode=timeout
# shellcheck source=agent-dispatch/test/conformance/edit-fixture.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/edit-fixture.sh"
export CODING_DISPATCH_TIMEOUT=1s
"$IMPL_BIN/coding-dispatch.sh"  codex "$SCN_REPO" "$SCN_TMP/brief" "true"
