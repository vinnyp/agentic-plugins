#!/usr/bin/env bash
set -eu
id=edit-tdd-signal
mode=tdd-signal
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/edit-fixture.sh"
printf 'fixture-base=%s\n' "$(git -C "$SCN_REPO" rev-parse HEAD)"
python3 "$here/edit-signal.py"
