#!/usr/bin/env bash
# Wiring tests for worktree caveats that are documented, not enforced by code.
# The two caveats below are agent-dispatch's OWN behaviour (a worktree does not share
# untracked files with the source checkout), so they must be documented inside this
# plugin — not in a sibling plugin this one cannot see once it is published on its own.
# Keep grep tokens short and single-line.
set -uo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$BIN/.." && pwd)"
README="$PLUGIN_ROOT/README.md"

pass=0; fail=0
ok(){ echo "ok: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

requires_phrase() {
  local file="$1" phrase="$2" label="$3"
  if [ ! -f "$file" ]; then
    bad "$label: $file not found"
    return
  fi
  if grep -qF -- "$phrase" "$file"; then
    ok "$label contains $phrase"
  else
    bad "$label contains $phrase"
  fi
}

requires_phrase "$README" "source checkout directly" "README worktree caveat"
requires_phrase "$README" "never inside the worktree" "README worktree caveat"

echo "pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
