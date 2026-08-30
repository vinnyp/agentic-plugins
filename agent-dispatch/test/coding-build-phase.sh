#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CBP_SRC="$ROOT/bin/coding-build-phase.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

mkdir -p "$TMP/bin" "$TMP/plugin-bin"
export PATH="$TMP/bin:$PATH"
export CD_CAPTURE_DIR="$TMP/prompts"
recall_cmd="dispatch-recall"
export RECALL_CAPTURE_FILE="$TMP/$recall_cmd.capture"
mkdir -p "$CD_CAPTURE_DIR"
cp "$CBP_SRC" "$TMP/plugin-bin/coding-build-phase.sh"
CBP="$TMP/plugin-bin/coding-build-phase.sh"

cat > "$TMP/bin/coding-dispatch.sh" <<'STUB'
#!/usr/bin/env bash
agent="$1"; repo="$2"; prompt="$3"; gate="$4"
idx_file="$CD_CAPTURE_DIR/.idx"
idx=0
[ -f "$idx_file" ] && idx="$(cat "$idx_file")"
idx=$((idx + 1))
printf '%s' "$idx" > "$idx_file"
cp "$prompt" "$CD_CAPTURE_DIR/$idx.prompt"
printf '%s\n' "$agent|$repo|$gate" > "$CD_CAPTURE_DIR/$idx.args"
exit 0
STUB
chmod +x "$TMP/bin/coding-dispatch.sh"

cat > "$TMP/plugin-bin/$recall_cmd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RECALL_CAPTURE_FILE"
STUB
chmod +x "$TMP/plugin-bin/$recall_cmd"

new_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  printf 'base\n' > "$repo/base.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm base
}

write_plan() {
  local path="$1"
  cat > "$path" <<'PLAN'
### Task 1: alpha
implement alpha
```
ignore code alpha
```
done alpha
### Task 2: beta
implement beta
done beta
PLAN
}

reset_captures() {
  rm -f "$RECALL_CAPTURE_FILE"
  rm -rf "$CD_CAPTURE_DIR"
  mkdir -p "$CD_CAPTURE_DIR"
}

REPO="$TMP/repo"
new_repo "$REPO"
PLAN_FILE="$TMP/plan.md"
write_plan "$PLAN_FILE"

reset_captures
RECALL_PROJECT=agent-tooling "$CBP" codex "$PLAN_FILE" "$REPO" 1 2 --build-cmd "true" >/dev/null 2>&1
grep -qF "implement alpha" "$CD_CAPTURE_DIR/1.prompt" || fail "task 1 prompt missing task body"
grep -qF "implement beta" "$CD_CAPTURE_DIR/2.prompt" || fail "task 2 prompt missing task body"
[ ! -f "$RECALL_CAPTURE_FILE" ] || fail "recall stub should not be invoked"
echo "test 1 (recall env and sibling stub are ignored) PASS"

reset_captures
RECALL_PROJECT=agent-tooling "$CBP" codex "$PLAN_FILE" "$REPO" 2 1 --build-cmd "true" >/dev/null 2>&1
grep -qF "implement beta" "$CD_CAPTURE_DIR/1.prompt" || fail "reordered first prompt should carry task 2 body"
grep -qF "implement alpha" "$CD_CAPTURE_DIR/2.prompt" || fail "reordered second prompt should carry task 1 body"
[ ! -f "$RECALL_CAPTURE_FILE" ] || fail "reordered phase should not call recall stub"
echo "test 2 (reorder preserves task bodies without recall) PASS"

reset_captures
"$CBP" codex "$PLAN_FILE" "$REPO" 1 --no-recall --build-cmd "true" >/dev/null 2>&1
cp "$CD_CAPTURE_DIR/1.prompt" "$TMP/baseline.prompt"

reset_captures
RECALL_PROJECT=agent-tooling "$CBP" codex "$PLAN_FILE" "$REPO" 1 --no-recall --build-cmd "true" >/dev/null 2>&1
cmp -s "$TMP/baseline.prompt" "$CD_CAPTURE_DIR/1.prompt" || fail "--no-recall prompt should be byte-identical to baseline"
[ ! -f "$RECALL_CAPTURE_FILE" ] || fail "--no-recall should not call recall stub"
echo "test 3 (--no-recall byte-identical/off) PASS"

reset_captures
RECALL_PROJECT=agent-tooling "$CBP" codex "$PLAN_FILE" "$REPO" 1 --build-cmd "true" >/dev/null 2>&1
cp "$CD_CAPTURE_DIR/1.prompt" "$TMP/env.prompt"
[ ! -f "$RECALL_CAPTURE_FILE" ] || fail "env project should not call recall stub"

reset_captures
"$CBP" codex "$PLAN_FILE" "$REPO" 1 --recall-project agent-tooling --build-cmd "true" >/dev/null 2>&1
cmp -s "$TMP/env.prompt" "$CD_CAPTURE_DIR/1.prompt" || fail "--recall-project flag should match env no-op prompt"
[ ! -f "$RECALL_CAPTURE_FILE" ] || fail "--recall-project should not call recall stub"
echo "test 4 (--recall-project flag parity/no-op) PASS"

echo "ALL PASS"
