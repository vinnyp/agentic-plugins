#!/usr/bin/env bash
set -eu
id=edit-phase-dispatch-refused
mode=edit
# shellcheck source=agent-dispatch/test/conformance/edit-fixture.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/edit-fixture.sh"
printf "### Task 2: Second\nEdit tracked.txt.\n### Task 3: Third\nEdit tracked.txt.\n" >> "$SCN_TMP/plan"
mkdir "$SCN_TMP/phase-bin"
cp "$IMPL_BIN/coding-build-phase.sh" "$SCN_TMP/phase-bin/"
ln -s "$IMPL_BIN/lib" "$SCN_TMP/phase-bin/lib"
printf '#!/usr/bin/env bash
exit 9
' > "$SCN_TMP/phase-bin/coding-dispatch.sh"
chmod +x "$SCN_TMP/phase-bin/coding-dispatch.sh"
export PATH="$SCN_TMP/phase-bin:$PATH"
"$SCN_TMP/phase-bin/coding-build-phase.sh" codex "$SCN_TMP/plan" "$SCN_REPO" 1 --build-cmd true
