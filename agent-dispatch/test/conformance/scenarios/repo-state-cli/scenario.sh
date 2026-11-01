#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=agent-dispatch/test/conformance/repo-state-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-fixture.sh"
fixture
snap "$TMP/before"
printf '[core\n bad' >> "$R/.git/config"
rc_is 3 "$BIN/repo-state-check" snapshot "$R" "$TMP/corrupt-after"
grep -qx unreadable "$TMP/corrupt-after"
rc_is 2 "$BIN/repo-state-check" compare "$TMP/before" "$TMP/corrupt-after" > "$TMP/output"
grep -qx 'config: <unreadable after review>' "$TMP/output"
rc_is 2 "$BIN/repo-state-check" compare "$TMP/before" "$TMP/nonexistent" > "$TMP/output"
grep -qx 'config: <unreadable after review>' "$TMP/output"
rc_is 3 "$BIN/repo-state-check" compare "$TMP/nonexistent" "$TMP/before" > "$TMP/output"
grep -qx 'state: <unreadable before snapshot>' "$TMP/output"
rc_is 64 "$BIN/repo-state-check" > "$TMP/output" 2> "$TMP/error"
grep -q '^usage: repo-state-check ' "$TMP/error"
[ ! -s "$TMP/output" ]
for help in --help -h; do
  rc_is 0 "$BIN/repo-state-check" "$help" > "$TMP/output" 2> "$TMP/error"
  grep -q '^usage: repo-state-check ' "$TMP/output"
  [ ! -s "$TMP/error" ]
done
for args in snapshot compare; do
  rc_is 64 "$BIN/repo-state-check" "$args" > "$TMP/output" 2> "$TMP/error"
  grep -q '^usage: repo-state-check ' "$TMP/error"
done
echo "PASS: repo-state-cli"
