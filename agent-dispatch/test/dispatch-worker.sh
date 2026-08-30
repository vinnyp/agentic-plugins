#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DW_SRC="$ROOT/bin/dispatch-worker"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

mkdir -p "$TMP/bin" "$TMP/plugin-bin" "$TMP/home"
export HOME="$TMP/home"
export PATH="$TMP/bin:$PATH"
export CODEX_STDIN_FILE="$TMP/codex.stdin"
export AGY_STDIN_FILE="$TMP/agy.stdin"
export CLAUDE_ARGS_FILE="$TMP/claude.args"
recall_cmd="dispatch-recall"
export RECALL_CAPTURE_FILE="$TMP/$recall_cmd.capture"
cp "$DW_SRC" "$TMP/plugin-bin/dispatch-worker"
DW_MUT="$TMP/plugin-bin/dispatch-worker"
DW="$DW_SRC"

cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
cat > "$CODEX_STDIN_FILE"
STUB

cat > "$TMP/bin/agy" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  models) exit 0 ;;
esac
cat > "$AGY_STDIN_FILE"
STUB

cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$CLAUDE_ARGS_FILE"
STUB

cat > "$TMP/plugin-bin/$recall_cmd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RECALL_CAPTURE_FILE"
STUB

chmod +x "$TMP/bin/codex" "$TMP/bin/agy" "$TMP/bin/claude" "$TMP/plugin-bin/$recall_cmd"

BRIEF="$TMP/brief.md"
cat > "$BRIEF" <<'BRIEF'
# Implement Worker Seam

Original brief body.
BRIEF

rm -f "$CODEX_STDIN_FILE" "$RECALL_CAPTURE_FILE"
RECALL_PROJECT=agent-tooling TIMEOUT=0 "$DW_MUT" --runtime codex --brief "$BRIEF" >/dev/null 2>&1
grep -qF "Original brief body." "$CODEX_STDIN_FILE" || fail "codex brief body missing"
cmp -s "$BRIEF" "$CODEX_STDIN_FILE" || fail "codex brief should be byte-identical with recall env and stub present"
[ ! -f "$RECALL_CAPTURE_FILE" ] || fail "recall stub should not be invoked"
echo "test 1 (recall env and stub are ignored) PASS"

rm -f "$AGY_STDIN_FILE" "$RECALL_CAPTURE_FILE"
TIMEOUT=0 "$DW" --runtime agy --recall-project agent-tooling --brief "$BRIEF" --workdir "$TMP/repo" >/dev/null 2>&1
grep -qF "Original brief body." "$AGY_STDIN_FILE" || fail "agy brief body missing"
[ ! -f "$RECALL_CAPTURE_FILE" ] || fail "agy --recall-project should not call recall stub"
echo "test 2 (agy --recall-project is no-op) PASS"

rm -f "$RECALL_CAPTURE_FILE"
TIMEOUT=0 "$DW" --runtime workflow --recall-project agent-tooling --brief "$BRIEF" >/dev/null 2>&1
[ ! -f "$RECALL_CAPTURE_FILE" ] || fail "workflow should not call recall stub"
echo "test 3 (workflow --recall-project is no-op) PASS"

rm -f "$CODEX_STDIN_FILE" "$RECALL_CAPTURE_FILE"
TIMEOUT=0 "$DW" --runtime codex --recall-project agent-tooling --no-recall --brief "$BRIEF" >/dev/null 2>&1
cmp -s "$BRIEF" "$CODEX_STDIN_FILE" || fail "--no-recall codex brief should be byte-identical"
[ ! -f "$RECALL_CAPTURE_FILE" ] || fail "--no-recall should not call recall stub"
echo "test 4 (--no-recall byte-identical brief) PASS"

echo "ALL PASS"
