#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=agent-dispatch/test/conformance/repo-state-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-fixture.sh"

# Handwritten snapshot inputs are data passed through the public compare command.
printf 'repo\tfixture\nconfig\tlocal\tfile:fixture\tcore.hookspath\told\n' > "$TMP/old"
printf 'repo\tfixture\nconfig\tlocal\tfile:fixture\tcore.hookspath\tnew\n' > "$TMP/new"
printf 'repo\tfixture\n' > "$TMP/empty"
: > "$TMP/invalid"
printf garbage > "$TMP/garbage"
rc_is 3 compare "$TMP/invalid" "$TMP/invalid" "$TMP/changes"
rc_is 2 compare "$TMP/old" "$TMP/garbage" "$TMP/changes"
printf 'repo\tfixture\000\n' > "$TMP/nul"
rc_is 3 compare "$TMP/nul" "$TMP/new" "$TMP/changes"
rc_is 2 compare "$TMP/old" "$TMP/nul" "$TMP/changes"
rc_is 0 compare "$TMP/old" "$TMP/old" "$TMP/changes"
[ ! -s "$TMP/changes" ]
rc_is 2 compare "$TMP/empty" "$TMP/new" "$TMP/changes"
grep -q '(absent) ->' "$TMP/changes"
rc_is 2 compare "$TMP/old" "$TMP/empty" "$TMP/changes"
grep -q -- '-> (absent)' "$TMP/changes"
rc_is 2 compare "$TMP/old" "$TMP/new" "$TMP/changes"
mkfifo "$TMP/before"
(cat "$TMP/old" > "$TMP/before") & writer=$!
rc_is 2 compare "$TMP/before" "$TMP/new" "$TMP/changes"
wait "$writer"
grep -q '^config core.hookspath' "$TMP/changes"
fixture
git -C "$R" config example.multiline $'first\nsecond'
printf dirty > "$R/path with spaces"
printf dirty > "$R/"$'path\nwith newline'
snap "$TMP/a"
snap "$TMP/b"
rc_is 0 compare "$TMP/a" "$TMP/b" "$TMP/changes"
grep -q 'first%0Asecond' "$TMP/a"
grep -q 'path%0Awith newline' "$TMP/a"
git -C "$R" config core.hooksPath changed
snap "$TMP/b"
rc_is 2 compare "$TMP/a" "$TMP/b" "$TMP/changes"
# Preserve unsafe diagnostics even when the remainder of a snapshot is unreadable.
mkfifo "$R/.git/fixture-fifo"
# Keep the scratch-path diagnostic out of the golden while checking it exactly.
snap "$TMP/unsafe" 2> "$TMP/unsafe-err"
printf 'repo-state-check: baseline contains special files: %s/.git/fixture-fifo\n' "$R" > "$TMP/expected-unsafe-err"
cmp "$TMP/expected-unsafe-err" "$TMP/unsafe-err"
{ printf 'unreadable\n'; grep '^unsafe' "$TMP/unsafe"; } > "$TMP/unreadable"
rc_is 2 compare "$TMP/a" "$TMP/unreadable" "$TMP/changes"
grep -q 'nonregular .*fixture-fifo: critical' "$TMP/changes"
rc_is 2 compare "$TMP/unreadable" "$TMP/unreadable" "$TMP/changes"
grep -q 'nonregular .*fixture-fifo: critical' "$TMP/changes"
(TMPDIR="$TMP/nonexistent"; export TMPDIR
 rc_is 3 "$BIN/repo-state-check" compare "$TMP/a" "$TMP/a" 2> "$TMP/setup-err")
grep -q 'nonexistent/' "$TMP/setup-err"


# Hash fallback must consume the same bytes after the primary tool fails.
mkdir "$TMP/digest-bin"
REAL_SHASUM=$(command -v shasum)
export REAL_SHASUM
printf '#!/bin/sh\ncat >/dev/null\nexit 1\n' > "$TMP/digest-bin/shasum"
cat > "$TMP/digest-bin/sha256sum" <<'HASH'
#!/usr/bin/env bash
exec "$REAL_SHASUM" -a 256 "$@"
HASH
chmod +x "$TMP/digest-bin/"*
fixture
git -C "$R" config credential.helper synthetic-secret
snap "$TMP/a"
PATH="$TMP/digest-bin:$PATH" snap "$TMP/b"
rc_is 0 compare "$TMP/a" "$TMP/b" "$TMP/changes"
echo "PASS: repo-state-inputs"

