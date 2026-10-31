#!/usr/bin/env bash
# The dispatch preamble must reach a GENERATED brief, not merely be cited by one.
#
# Two correct rules were unreachable because every mechanism naming them was a
# citation, and the next path that assembled a brief did not join the citation
# register. So this suite pins the clauses as literals and asserts they appear in
# what coding-dispatch.sh and the review skill actually hand the agent — which
# means changing a clause in docs/dispatch-preamble.md turns this red at once.
set -uo pipefail
# A suite launched from a git hook inherits these and would write to the caller's repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/test-env-reset.sh"
reset_dispatch_env  # neutralize any operator-exported dispatch vars before the suite runs
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

# Literals, independent of the block, so a clause changed there cannot rewrite its own
# expectation. A changed clause stops the suite here, naming it, before any brief runs.
# foundry#262: every clause is a whole line, because each carries a rule a fragment would not
# hold. Bindery's snapshot reads the vault copy, not this file, so nothing else guards them here.
# read, not $(cat <<...): bash 3.2 cannot parse a heredoc inside a command substitution.
IFS= read -r C_CLAUSE1 <<'CLAUSE'
- **Never touch a file you did not create.** `rm`, `git checkout`, `git restore`, `git reset`, `git clean` and `git stash` are forbidden against any path outside your task's declared files. Treat unknown files as foreign and leave them. This binds every dispatched agent — a coding worker, a reviewer, a research or archival subagent, any runtime — not only a `coding-dispatch.sh` run. If your task is to change files, the files it declares are yours to edit, even if they already exist, unless the next clause lists them.
CLAUSE
IFS= read -r C_CLAUSE2 <<'CLAUSE'
- **These paths are already dirty and are not yours:** {{DIRTY_PATHS}}. Reverting or deleting one of them is the failure this rule exists to prevent.
CLAUSE
IFS= read -r C_CLAUSE3 <<'CLAUSE'
- **You do not run the long gate.** Run every command in the foreground and let it finish. A subagent cannot receive a completion notification, so a backgrounded command hangs forever with nothing to wake it; if you catch yourself writing "I'll wait for the notification", that IS the violation. Never kill or signal a process you did not start. Bound any load generator you start (`yes`, `node -e 'for(;;);'`, a spin loop) with `timeout -k`, and make sure it is gone before you return: a burner left behind holds a shared machine's cores for hours.
CLAUSE
IFS= read -r C_CLAUSE4 <<'CLAUSE'
- **Scratch repos fail closed.** Create a throwaway repo only under an absolute `mktemp -d "${TMPDIR:-/tmp}/<name>.XXXXXX"`, in a script running `set -eu`, and abort if the path is empty. Every `git config`, `checkout`, `branch`, `merge`, `commit` or `push` in it carries `-C <that path>`. Pass an identity per command (`-c user.name=… -c user.email=…`, or `GIT_AUTHOR_*`/`GIT_COMMITTER_*` env), never with `git config`, and never `--global`. `git -C ""` silently runs in the current directory, and in a linked worktree `git config` rewrites the shared repository's config. One exception: a new case in an existing test suite may follow that suite's fixture idiom, inside that suite's own temporary directory. Everything else stays under this clause, whether typed or scripted.
CLAUSE
C_DIRTY='already dirty and are not yours'
require_clause() { # <label> <whole line>
  printf '%s\n' "$CLAUSES" | grep -qxF -- "$2" && return 0
  bad "the shipped block has changed the $1 clause"; echo "pass=$pass fail=$fail"; exit 1
}
require_clause cleanup "$C_CLAUSE1"
require_clause dirty-paths "$C_CLAUSE2"
require_clause long-gate "$C_CLAUSE3"
require_clause scratch "$C_CLAUSE4"
if [ "$(printf '%s\n' "$CLAUSES" | grep -c .)" -eq 4 ] && [ "$(printf '%s\n' "$CLAUSES" | grep -c '^- \*\*')" -eq 4 ]; then
  ok "the shipped block is exactly four clauses, each pinned as a whole line"
else
  bad "the shipped block is not exactly four clause lines"
fi

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

clauses_above_body() { # <brief> <body text>
  local top bottom
  top=$(grep -nxF -- "$C_CLAUSE4" "$1" | head -1 | cut -d: -f1)
  bottom=$(grep -nF -- "$2" "$1" | head -1 | cut -d: -f1)
  [ -n "$top" ] && [ -n "$bottom" ] && [ "$top" -lt "$bottom" ]
}

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
  grep -qxF -- "$C_CLAUSE1" "$CAPTURE" || miss="$miss cleanup"
  grep -qF -- "$C_DIRTY"    "$CAPTURE" || miss="$miss dirty-paths"
  grep -qxF -- "$C_CLAUSE3" "$CAPTURE" || miss="$miss long-gate"
  grep -qxF -- "$C_CLAUSE4" "$CAPTURE" || miss="$miss scratch"
  if [ -z "$miss" ]; then ok "the generated brief carries every clause"
  else bad "the generated brief is missing:$miss"; fi
  if grep -qF '{{DIRTY_PATHS}}' "$CAPTURE"; then
    bad "the generated brief still carries an unsubstituted {{DIRTY_PATHS}} token"
  else
    ok "{{DIRTY_PATHS}} was substituted in the generated brief"
  fi
  # The caller's own prompt must survive alongside the preamble, below it.
  if grep -qF 'do the thing' "$CAPTURE"; then ok "the caller's prompt is still in the brief"
  else bad "the caller's prompt was lost"; fi
  if clauses_above_body "$CAPTURE" 'do the thing'; then ok "the preamble sits above the caller's prompt"
  else bad "the preamble is not above the caller's prompt"; fi
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
# The list is compared exactly, so a stale extra line or a reordered clause fails too.
awk '/The four clauses are:/ {on=1; next} on && /^- / {print; seen=1; next} seen {exit}' "$SKILL" > "$TMP/skill-clauses"
printf '%s\n' "$CLAUSES" > "$TMP/block-clauses"
if cmp -s "$TMP/skill-clauses" "$TMP/block-clauses"; then ok "the skill's clause list matches the shipped block exactly"
else bad "the skill's clause list differs from the shipped block"; fi
if grep -qF 'docs/dispatch-preamble.md' "$SKILL"; then
  ok "the skill points at the shipped block as the source to concatenate"
else
  bad "the skill does not name the shipped block"
fi

# --- The reviewer route: run the skill's own snippet ------------------------
# Real reviewer briefs come from this snippet, not from the prose above. Its /tmp glob is pointed
# at a private directory, and the run is refused unless that rewrite took, so running it cannot
# touch another session's briefs. The tree is dirty on purpose: this is the one route where
# clause 2 carries a real value, and clause 1's permission rests on that list.
RB="$TMP/reviewer-briefs"; mkdir -p "$RB"
printf 'REVIEWER-BRIEF-BODY\n' > "$RB/brief-one.md"
SNIP_REPO="$TMP/snippet-repo"; mkdir -p "$SNIP_REPO"
git -C "$SNIP_REPO" init -q
printf 'seed\n' > "$SNIP_REPO/seed.txt"
git -C "$SNIP_REPO" add -A
git -C "$SNIP_REPO" -c user.name=t -c user.email=t@example.invalid commit -qm seed
printf 'mine\n' > "$SNIP_REPO/dirty-on-purpose.txt"
RENDERED_DIRTY="$(printf '%s\n' "$C_CLAUSE2" | sed 's/{{DIRTY_PATHS}}/`dirty-on-purpose.txt`/')"
awk '
  /^```bash$/ {buf=""; inside=1; next}
  /^```$/ {if (inside && buf ~ /PREAMBLE:START/) {printf "%s", buf; exit} inside=0; next}
  inside {buf=buf $0 "\n"}
' "$SKILL" | sed "s#/tmp/brief-#$RB/brief-#g" > "$TMP/reviewer-snippet.sh"
if ! grep -qF 'PREAMBLE:START' "$TMP/reviewer-snippet.sh"; then
  bad "the skill's preamble snippet could not be extracted"
elif ! grep -qF "for b in $RB/brief-" "$TMP/reviewer-snippet.sh" ||
     sed "s#$RB##g" "$TMP/reviewer-snippet.sh" | grep -qF '/tmp/'; then
  bad "the skill's snippet still reaches outside the private directory; it was not run"
elif (cd "$SNIP_REPO" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash -eu "$TMP/reviewer-snippet.sh") > "$TMP/snippet.out" 2>&1; then
  rendered=0
  for line in "$C_CLAUSE1" "$RENDERED_DIRTY" "$C_CLAUSE3" "$C_CLAUSE4"; do
    grep -qxF -- "$line" "$RB/brief-one.md" || rendered=$((rendered + 1))
  done
  if [ "$rendered" -eq 0 ]; then ok "the skill's snippet renders every clause into a reviewer brief, naming the dirty path"
  else bad "the skill's snippet dropped or changed $rendered clause(s) in a reviewer brief"; fi
  if grep -qF 'REVIEWER-BRIEF-BODY' "$RB/brief-one.md"; then ok "the reviewer brief keeps its own body"
  else bad "the skill's snippet lost the reviewer brief's body"; fi
  if clauses_above_body "$RB/brief-one.md" 'REVIEWER-BRIEF-BODY'; then ok "the preamble sits above the reviewer brief"
  else bad "the preamble is not above the reviewer brief"; fi
  if grep -qF '{{DIRTY_PATHS}}' "$RB/brief-one.md"; then bad "the reviewer brief still carries {{DIRTY_PATHS}}"
  else ok "the skill's snippet leaves no {{DIRTY_PATHS}} token"; fi
else
  bad "the skill's snippet failed: $(tail -2 "$TMP/snippet.out")"
fi

echo "pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
