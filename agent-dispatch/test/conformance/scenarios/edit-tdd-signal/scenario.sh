#!/usr/bin/env bash
set -eu
export id=edit-tdd-signal
export mode=tdd-signal
here=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/edit-fixture.sh"
printf 'fixture-base=%s\n' "$(git -C "$SCN_REPO" rev-parse HEAD)"
python3 "$here/edit-signal.py"
