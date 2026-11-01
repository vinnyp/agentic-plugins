#!/usr/bin/env bash
set -eu
id=edit-tdd-fail
mode=tdd
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/edit-fixture.sh"
printf 'fixture-base=%s\n' "$(git -C "$SCN_REPO" rev-parse HEAD)"
"$IMPL_BIN/coding-dispatch.sh" codex "$SCN_REPO" "$SCN_TMP/brief" "false"
