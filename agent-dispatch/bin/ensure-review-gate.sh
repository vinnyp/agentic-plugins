#!/usr/bin/env bash
# ensure-review-gate.sh — build tools/review-gate into <plugin>/.bin/review-gate if the
# binary is missing or stale. Build-from-source: no compiled artifact is committed, so
# this needs a Go toolchain on the machine. Idempotent; keyed on a hash of the Go sources.
#
# Everything resolves relative to THIS script's own location, so the plugin works from a
# marketplace install, a git checkout, or a symlink on PATH without any environment.
#
# Output lands in <plugin>/.bin/ rather than <plugin>/bin/ because bin/ holds shell
# entrypoints only — the doctor's entrypoint registry and the suite's shellcheck sweep
# both walk it, and a compiled binary belongs to neither.
#
#   rc 0  binary present and current (built if it was not)
#   rc 2  no Go toolchain, missing sources, or a failed build
set -uo pipefail

SELF_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SELF_DIR")"
SRC="$PLUGIN_DIR/tools/review-gate"
OUT_DIR="$PLUGIN_DIR/.bin"
BIN="$OUT_DIR/review-gate"
STAMP="$OUT_DIR/.review-gate.srchash"

if ! command -v go >/dev/null 2>&1; then
  for g in /opt/homebrew/bin/go /usr/local/bin/go /usr/local/go/bin/go "${HOME}/go/bin/go" /opt/go/bin/go; do
    [ -x "$g" ] && { PATH="$(dirname "$g"):$PATH"; export PATH; break; }
  done
fi
command -v go >/dev/null 2>&1 || {
  echo "ensure-review-gate.sh: no Go toolchain on PATH — install Go, then re-run" >&2
  exit 2
}
[ -d "$SRC" ] || { echo "ensure-review-gate.sh: source missing at $SRC" >&2; exit 2; }

cur="$(find "$SRC" -name '*.go' -type f -exec shasum {} + 2>/dev/null | sort | shasum | cut -d' ' -f1)"
if [ -x "$BIN" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$cur" ]; then
  exit 0
fi

mkdir -p "$OUT_DIR" || exit 2
( cd "$SRC" && go build -o "$BIN.$$.tmp" . ) && mv "$BIN.$$.tmp" "$BIN" || {
  rm -f "$BIN.$$.tmp"
  echo "ensure-review-gate.sh: build failed" >&2
  exit 2
}
printf '%s' "$cur" > "$STAMP.$$.tmp" && mv "$STAMP.$$.tmp" "$STAMP"
echo "ensure-review-gate.sh: built $BIN" >&2
exit 0
