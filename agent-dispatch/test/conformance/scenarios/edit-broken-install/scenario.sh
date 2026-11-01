#!/usr/bin/env bash
set -eu
id=edit-broken-install
mode=empty
# shellcheck source=agent-dispatch/test/conformance/edit-fixture.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/edit-fixture.sh"
mkdir "$SCN_TMP/broken"
cp "$IMPL_BIN/coding-dispatch.sh" "$SCN_TMP/broken/"
bash "$SCN_TMP/broken/coding-dispatch.sh"
