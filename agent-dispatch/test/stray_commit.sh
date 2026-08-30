#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CD="$ROOT/bin/coding-dispatch.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

mkdir -p "$TMP/bin"
export PATH="$TMP/bin:$PATH"

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

write_prompt() {
  local path="$1"
  printf 'Implement the feature.\n' > "$path"
}

# Test 1: single stray self-commit (no marker → unwind)
# Stub codex: makes one commit but does NOT write _coding-result.json
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
# parse -C <dir> from args: codex exec --dangerously-bypass-approvals-and-sandbox -C <dir> -
while [ $# -gt 0 ]; do
  case "$1" in
    -C) shift; cd "$1" || exit 1; shift ;;
    *) shift ;;
  esac
done
printf 'stray content\n' > stray.txt
git add stray.txt
git commit -qm "stray commit by agent"
# no _coding-result.json
exit 0
STUB
chmod +x "$TMP/bin/codex"

REPO1="$TMP/repo1"
new_repo "$REPO1"
BASE1="$(git -C "$REPO1" rev-parse HEAD)"
PROMPT1="$TMP/prompt1.txt"
write_prompt "$PROMPT1"

out="$("$CD" codex "$REPO1" "$PROMPT1" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "test 1: expected exit 0, got $rc (output: $out)"
HEAD1="$(git -C "$REPO1" rev-parse HEAD)"
[ "$HEAD1" = "$BASE1" ] || fail "test 1: HEAD should equal BASE after unwind (HEAD=$HEAD1, BASE=$BASE1)"
# stray.txt should be in the working tree as an uncommitted change
[ -f "$REPO1/stray.txt" ] || fail "test 1: stray.txt should be in working tree after unwind"
# confirm there is an uncommitted diff (stray.txt is untracked or modified vs HEAD)
uncommitted="$(git -C "$REPO1" status --porcelain)"
[ -n "$uncommitted" ] || fail "test 1: working tree should have uncommitted changes after unwind"
echo "test 1 (single stray commit unwound) PASS"

# Test 2: multi-commit stray self-commit (no marker → all collapsed)
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in
    -C) shift; cd "$1" || exit 1; shift ;;
    *) shift ;;
  esac
done
for i in 1 2 3; do
  printf 'file%s content\n' "$i" > "file$i.txt"
  git add "file$i.txt"
  git commit -qm "stray commit $i"
done
# no _coding-result.json
exit 0
STUB
chmod +x "$TMP/bin/codex"

REPO2="$TMP/repo2"
new_repo "$REPO2"
BASE2="$(git -C "$REPO2" rev-parse HEAD)"
PROMPT2="$TMP/prompt2.txt"
write_prompt "$PROMPT2"

out="$("$CD" codex "$REPO2" "$PROMPT2" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "test 2: expected exit 0, got $rc (output: $out)"
HEAD2="$(git -C "$REPO2" rev-parse HEAD)"
[ "$HEAD2" = "$BASE2" ] || fail "test 2: HEAD should equal BASE after 3-commit unwind (HEAD=$HEAD2, BASE=$BASE2)"
# all 3 files should exist in working tree
[ -f "$REPO2/file1.txt" ] || fail "test 2: file1.txt missing from working tree"
[ -f "$REPO2/file2.txt" ] || fail "test 2: file2.txt missing from working tree"
[ -f "$REPO2/file3.txt" ] || fail "test 2: file3.txt missing from working tree"
uncommitted2="$(git -C "$REPO2" status --porcelain)"
[ -n "$uncommitted2" ] || fail "test 2: working tree should have uncommitted changes after 3-commit unwind"
echo "test 2 (multi-commit stray unwind) PASS"

# Test 3: legitimate TDD path — agent commits code AND writes marker as an uncommitted
# working-tree file. Because the marker is untracked, git status --porcelain is NON-EMPTY,
# so the clean-tree / stray-unwind block is never entered. The dispatch continues through
# the mutation check, build gate, and marker synthesis normally. HEAD != BASE is preserved.
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in
    -C) shift; cd "$1" || exit 1; shift ;;
    *) shift ;;
  esac
done
printf 'tdd content\n' > tdd.txt
git add tdd.txt
git commit -qm "TDD per-task commit"
# Write marker as an UNCOMMITTED working-tree file (makes tree dirty → clean-tree block skipped)
printf '{"status":"complete","files_written":["tdd.txt"],"timestamp":"2026-01-01T00:00:00Z"}\n' > _coding-result.json
exit 0
STUB
chmod +x "$TMP/bin/codex"

REPO3="$TMP/repo3"
new_repo "$REPO3"
BASE3="$(git -C "$REPO3" rev-parse HEAD)"
PROMPT3="$TMP/prompt3.txt"
write_prompt "$PROMPT3"

out="$("$CD" codex "$REPO3" "$PROMPT3" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "test 3: expected exit 0, got $rc (output: $out)"
HEAD3="$(git -C "$REPO3" rev-parse HEAD)"
[ "$HEAD3" != "$BASE3" ] || fail "test 3: TDD commit should be kept; HEAD should NOT equal BASE"
# the commit should appear in the log
commits="$(git -C "$REPO3" log --oneline HEAD)"
[ -n "$commits" ] || fail "test 3: git log should show at least one commit"
echo "test 3 (TDD path: committed code + uncommitted marker → HEAD kept) PASS"

# Test 4: normal run (no self-commit, changes uncommitted → unaffected)
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in
    -C) shift; cd "$1" || exit 1; shift ;;
    *) shift ;;
  esac
done
printf 'normal content\n' > normal.txt
# do NOT commit — leave changes uncommitted
printf '{"status":"complete","files_written":["normal.txt"],"timestamp":"2026-01-01T00:00:00Z"}\n' > _coding-result.json
exit 0
STUB
chmod +x "$TMP/bin/codex"

REPO4="$TMP/repo4"
new_repo "$REPO4"
BASE4="$(git -C "$REPO4" rev-parse HEAD)"
PROMPT4="$TMP/prompt4.txt"
write_prompt "$PROMPT4"

out="$("$CD" codex "$REPO4" "$PROMPT4" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "test 4: expected exit 0, got $rc (output: $out)"
HEAD4="$(git -C "$REPO4" rev-parse HEAD)"
[ "$HEAD4" = "$BASE4" ] || fail "test 4: HEAD should still equal BASE (no self-commit)"
[ -f "$REPO4/normal.txt" ] || fail "test 4: normal.txt should be in working tree"
uncommitted4="$(git -C "$REPO4" status --porcelain)"
[ -n "$uncommitted4" ] || fail "test 4: normal.txt should be an uncommitted change"
echo "test 4 (normal run unaffected) PASS"

# Test 5: stray commit that INCLUDES _coding-result.json in the commit body → still unwound.
# This is the BLOCKER case: the agent commits stray2.txt + _coding-result.json together, so
# after the commit git status is clean AND marker_status="complete" is readable from the
# tracked file. The correct fix (always-unwind when clean+HEAD!=BASE) catches this; the
# earlier marker-discriminator did not.
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in
    -C) shift; cd "$1" || exit 1; shift ;;
    *) shift ;;
  esac
done
printf 'stray content\n' > stray2.txt
printf '{"status":"complete","files_written":["stray2.txt"],"timestamp":"2026-01-01T00:00:00Z"}\n' > _coding-result.json
git add stray2.txt _coding-result.json
git commit -qm "stray commit including marker"
exit 0
STUB
chmod +x "$TMP/bin/codex"

REPO5="$TMP/repo5"
new_repo "$REPO5"
BASE5="$(git -C "$REPO5" rev-parse HEAD)"
PROMPT5="$TMP/prompt5.txt"
write_prompt "$PROMPT5"

out="$("$CD" codex "$REPO5" "$PROMPT5" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "test 5: expected exit 0, got $rc (output: $out)"
HEAD5="$(git -C "$REPO5" rev-parse HEAD)"
[ "$HEAD5" = "$BASE5" ] || fail "test 5: stray commit with marker should be unwound; HEAD should equal BASE (HEAD=$HEAD5, BASE=$BASE5)"
[ -f "$REPO5/stray2.txt" ] || fail "test 5: stray2.txt should be in working tree after unwind"
uncommitted5="$(git -C "$REPO5" status --porcelain)"
[ -n "$uncommitted5" ] || fail "test 5: working tree should have uncommitted changes after unwind"
echo "test 5 (stray commit with committed marker unwound) PASS"

echo "ALL PASS"
