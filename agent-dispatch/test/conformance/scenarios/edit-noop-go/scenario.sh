#!/usr/bin/env bash
set -eu
id=edit-noop-go
mode=noop
# shellcheck source=agent-dispatch/test/conformance/edit-fixture.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/edit-fixture.sh"
printf 'module fixture.invalid/example
' > "$SCN_REPO/go.mod"
git -C "$SCN_REPO" add go.mod
git -C "$SCN_REPO" -c user.name=Conformance -c user.email=conformance@example.invalid commit -qm module
printf '#!/usr/bin/env bash
printf "go gate: %%s\n" "$*"
' > "$SCN_TMP/bin/go"
chmod +x "$SCN_TMP/bin/go"
"$IMPL_BIN/coding-dispatch.sh"  codex "$SCN_REPO" "$SCN_TMP/brief"
