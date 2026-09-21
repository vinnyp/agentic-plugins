#!/usr/bin/env bash
# The dispatch preamble must reach a GENERATED brief, not merely be cited by one.
#
# Two correct rules were unreachable because every mechanism naming them was a
# citation, and the next path that assembled a brief did not join the citation
# register. So this suite extracts the clauses from the shipped block and asserts
# they appear in what coding-dispatch.sh actually hands the agent — which means
# deleting a clause from docs/dispatch-preamble.md turns this red at once.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CD="$SCRIPT_DIR/coding-dispatch.sh"
BLOCK="$PLUGIN_ROOT/docs/dispatch-preamble.md"
SKILL="$PLUGIN_ROOT/skills/running-the-peer-review-gate/SKILL.md"

pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- The shipped block ------------------------------------------------------
if [ ! -f "$BLOCK" ]; then
  echo "FAIL: the vendored preamble is missing at $BLOCK"
  echo "pass=$pass fail=$((fail + 1))"
  exit 1
fi
CLAUSES="$(sed -n '/<!-- PREAMBLE:START -->/,/<!-- PREAMBLE:END -->/p' "$BLOCK" | sed '1d;$d')"
if [ -n "$CLAUSES" ]; then ok "the preamble block is delimited and non-empty"
else bad "the preamble block is empty or its markers moved"; fi

# Extracted from the single source, so a clause deleted there fails every
# assertion below rather than silently narrowing what is checked.
C_CLEANUP="$(printf '%s\n' "$CLAUSES" | grep -o 'Never touch a file you did not create' | head -1)"
C_DIRTY="$(printf '%s\n'   "$CLAUSES" | grep -o 'already dirty and are not yours'      | head -1)"
C_GATE="$(printf '%s\n'    "$CLAUSES" | grep -o 'You do not run the long gate'         | head -1)"
for c in "$C_CLEANUP" "$C_DIRTY" "$C_GATE"; do
  if [ -z "$c" ]; then
    bad "a required clause is missing from the shipped block — the rest of this suite cannot discriminate"
    echo "pass=$pass fail=$fail"
    exit 1
  fi
done
ok "all three clauses are present in the shipped block"

# Nothing private may ship in a public repository. The vendored block came from
# a private source, so this asserts the copy carries none of that source's
# shape. NOTE for anyone running a private-leakage scan over a diff: the pattern
# on the next line is the detector, not a finding — it is the one line in this
# change that such a scan is expected to flag.
if grep -nE '(/Users/|\$HOME|FOUNDRY_HOME|BINDERY_ROOT|Documents/Obsidian)' "$BLOCK" >/dev/null; then
  bad "the vendored preamble references a private path or root"
else
  ok "the vendored preamble references no private path or root"
fi

# --- The generated brief ----------------------------------------------------
# A codex stub that captures the brief on stdin, which is exactly how
# coding-dispatch.sh delivers it.
STUB_DIR="$TMP/bin"; mkdir -p "$STUB_DIR"
CAPTURE="$TMP/brief.txt"
cat > "$STUB_DIR/codex" <<STUB
#!/usr/bin/env bash
wd=""; while [ \$# -gt 0 ]; do [ "\$1" = "-C" ] && { wd="\$2"; shift 2; continue; }; shift; done
: "\${wd:=\$PWD}"
cat > "$CAPTURE"
printf '{"status":"complete","files_written":[],"timestamp":"1970-01-01T00:00:00Z"}\n' > "\$wd/_coding-result.json"
printf 'touched\n' >> "\$wd/stub_change.txt"
STUB
chmod +x "$STUB_DIR/codex"

REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name "Preamble Test"
printf 'seed\n' > "$REPO/seed.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "seed"
printf 'do the thing\n' > "$TMP/prompt.md"

PATH="$STUB_DIR:$PATH" bash "$CD" codex "$REPO" "$TMP/prompt.md" "true" > "$TMP/dispatch.out" 2>&1
dispatch_rc=$?
if [ "$dispatch_rc" -eq 0 ] && [ -s "$CAPTURE" ]; then
  ok "the dispatch reached the agent and the brief was captured"
  miss=""
  grep -qF -- "$C_CLEANUP" "$CAPTURE" || miss="$miss cleanup"
  grep -qF -- "$C_DIRTY"   "$CAPTURE" || miss="$miss dirty-paths"
  grep -qF -- "$C_GATE"    "$CAPTURE" || miss="$miss long-gate"
  if [ -z "$miss" ]; then ok "the generated brief carries every clause"
  else bad "the generated brief is missing:$miss"; fi
  if grep -qF '{{DIRTY_PATHS}}' "$CAPTURE"; then
    bad "the generated brief still carries an unsubstituted {{DIRTY_PATHS}} token"
  else
    ok "{{DIRTY_PATHS}} was substituted in the generated brief"
  fi
  # The caller's own prompt must survive alongside the preamble.
  if grep -qF 'do the thing' "$CAPTURE"; then ok "the caller's prompt is still in the brief"
  else bad "the caller's prompt was lost"; fi
else
  bad "the dispatch exited $dispatch_rc without a captured brief (output: $(tail -3 "$TMP/dispatch.out"))"
fi

# --- A missing block is a refusal, never a shorter brief --------------------
# On a CLEAN tree, so the rc 2 under test is the preamble's own. In-place mode
# also exits 2 for an unclean tree, and when two defects produce the same rc,
# rc is not evidence — hence the message assertion beside it.
: > "$CAPTURE"
CODING_DISPATCH_PREAMBLE="$TMP/no-such-preamble.md" PATH="$STUB_DIR:$PATH" \
  bash "$CD" codex "$REPO" "$TMP/prompt.md" "true" > "$TMP/dispatch3.out" 2>&1
miss_rc=$?
if [ "$miss_rc" -eq 2 ]; then ok "a missing preamble file exits 2"
else bad "a missing preamble file exited $miss_rc, expected 2"; fi
if grep -q 'dispatch preamble not found' "$TMP/dispatch3.out"; then
  ok "the refusal names the missing preamble"
else
  bad "the refusal message is missing (output: $(tail -3 "$TMP/dispatch3.out"))"
fi
if [ -s "$CAPTURE" ]; then
  bad "the agent was dispatched anyway, with a brief that carried no ground rules"
else
  ok "no brief reached the agent when the preamble was missing"
fi

# The refusal must land before any side effect: a broken install that first
# creates a worktree and a branch leaves them behind for someone else to find.
: > "$CAPTURE"
CODING_DISPATCH_PREAMBLE="$TMP/no-such-preamble.md" CODING_DISPATCH_WORKTREE="preamble-refusal" \
  PATH="$STUB_DIR:$PATH" bash "$CD" --worktree codex "$REPO" "$TMP/prompt.md" "true" \
  > "$TMP/dispatch4.out" 2>&1
if [ -e "$TMP/.worktrees/preamble-refusal" ]; then
  bad "the refusal created a worktree before checking the preamble"
else
  ok "a missing preamble refuses before creating a worktree"
fi

# --- What `{{DIRTY_PATHS}}` resolves to here, stated rather than assumed ----
# coding-dispatch.sh refuses to dispatch into a dirty tree in BOTH modes:
# in-place requires a clean tree (the revert net hard-resets to HEAD), and a
# REUSED worktree must be clean too ("reused worktree ... is dirty (salvaged
# failure?)"). So `none` is not a fallback at this site — it is the only
# truthful value this tool can produce, and the clause tells the agent that
# anything it finds in the tree is something it created. The substitution is
# still what runs: the token assertion above is what fails if it does not.
: > "$CAPTURE"
CODING_DISPATCH_WORKTREE="preamble-clean" PATH="$STUB_DIR:$PATH" \
  bash "$CD" --worktree codex "$REPO" "$TMP/prompt.md" "true" > "$TMP/dispatch5.out" 2>&1
if [ ! -s "$CAPTURE" ]; then
  bad "the worktree dispatch produced no brief (output: $(tail -3 "$TMP/dispatch5.out"))"
elif grep -qF 'are not yours:** `none`' "$CAPTURE" || grep -qF 'are not yours:** none' "$CAPTURE"; then
  ok "the dirty-paths clause resolves to none in a tree this tool guarantees is clean"
else
  bad "the dirty-paths clause did not resolve to a value: $(grep -o 'are not yours:.\{0,40\}' "$CAPTURE" | head -1)"
fi

# --- The peer-review gate skill carries the clauses -------------------------
miss=""
grep -qF -- "$C_CLEANUP" "$SKILL" || miss="$miss cleanup"
grep -qF -- "$C_DIRTY"   "$SKILL" || miss="$miss dirty-paths"
grep -qF -- "$C_GATE"    "$SKILL" || miss="$miss long-gate"
if [ -z "$miss" ]; then ok "running-the-peer-review-gate carries every clause"
else bad "running-the-peer-review-gate is missing:$miss"; fi
if grep -qF 'docs/dispatch-preamble.md' "$SKILL"; then
  ok "the skill points at the shipped block as the source to concatenate"
else
  bad "the skill does not name the shipped block"
fi

echo "pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
