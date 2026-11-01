#!/usr/bin/env bash
set -eu
id=edit-usage
mode=empty
# shellcheck source=agent-dispatch/test/conformance/edit-fixture.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/edit-fixture.sh"
"$IMPL_BIN/coding-dispatch.sh" --unknown
