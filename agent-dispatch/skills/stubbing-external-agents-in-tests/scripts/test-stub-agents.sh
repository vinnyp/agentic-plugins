#!/usr/bin/env bash
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
fail() { echo "FAIL: $1"; exit 1; }

# stub-agents.sh prints a dir to stdout; that dir must hold inert agy/codex/claude at 0700.
DIR="$(bash "$SELF_DIR/stub-agents.sh")" || fail "stub-agents.sh exited non-zero"
[ -d "$DIR" ] || fail "did not print a real dir, got: $DIR"
trap 'rm -rf "$DIR"' EXIT

# 0700 dir from mktemp -d (not a predictable /tmp path). GNU stat first, BSD fallback.
perms="$(stat -c '%a' "$DIR" 2>/dev/null || stat -f '%Lp' "$DIR")"
[ "$perms" = "700" ] || fail "stub dir should be 0700, got '$perms'"

for a in agy codex claude; do
  [ -x "$DIR/$a" ] || fail "$a stub missing/not executable"
  PATH="$DIR:$PATH" "$a" -p whatever >/dev/null 2>&1 || fail "$a stub should exit 0"
done

# Prepended PATH must resolve to the stub, not a real binary.
resolved="$(PATH="$DIR:$PATH" command -v agy)"
[ "$resolved" = "$DIR/agy" ] || fail "prepended PATH should resolve agy to the stub, got '$resolved'"

echo "ALL PASS"
