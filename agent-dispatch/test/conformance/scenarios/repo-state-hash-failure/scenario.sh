#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=agent-dispatch/test/conformance/repo-state-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-fixture.sh"
fixture
git -C "$R" config credential.helper SECRET
mkdir "$TMP/digest-bin"
REAL_SHASUM=$(command -v shasum)
export REAL_SHASUM
# Fail only on the credential digest, after earlier snapshot digests succeeded.
for tool in shasum sha256sum; do
  cat > "$TMP/digest-bin/$tool" <<'HASH'
#!/usr/bin/env bash
set -eu
data=$(cat; printf x)
data=${data%x}
[ "$data" != SECRET ] || exit 1
printf '%s' "$data" | "$REAL_SHASUM" -a 256
HASH
  chmod +x "$TMP/digest-bin/$tool"
done
PATH="$TMP/digest-bin:$PATH" rc_is 3 "$BIN/repo-state-check" snapshot "$R" "$TMP/failed" 2> "$TMP/err"
grep -qx unreadable "$TMP/failed"
! grep -q SECRET "$TMP/failed" "$TMP/err"
echo 'PASS: repo-state-hash-failure'
