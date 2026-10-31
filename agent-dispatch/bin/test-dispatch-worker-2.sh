#!/usr/bin/env bash
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SELF_DIR/lib/timeout-bin.sh"
# shellcheck source=lib/test-dispatch-worker-lib.sh
. "$SELF_DIR/lib/test-dispatch-worker-lib.sh"

# 29. A concise genuine review above the new 1200B floor passes the hybrid gate.
R29="$TMP/repo29"; make_git_repo "$R29"
cat > "$TMP/bin/agy" <<'STUB'
#!/usr/bin/env bash
# PERSONA_ROSTER_STUB
case "${1:-}" in
  agent)
    printf '%s\n' "$*" >> "$AGY_ARGS_FILE"
    [ "${AGY_ROSTER_MODE:-}" = nonzero ] && exit 19
    [ "${AGY_ROSTER_MODE:-}" = empty ] || printf '%s\n' peer-security-reviewer peer-code-reviewer
    exit 0
    ;;
esac
case "$*" in *models*) printf '%s\tGemini 3.8 Flash (Medium)\n%s\tGemini 4 Argon (High)\ncustom-id\tCustom Display\ngpt-oss\tGPT-OSS 120B (Medium)\n' "$AGY_TEST_CODING_PIN" "$AGY_TEST_REVIEW_PIN"; exit 0;; esac
for i in $(seq 1 40); do printf 'Major: finding %s concise evidence.\n' "$i"; done
STUB
chmod +x "$TMP/bin/agy"
REVIEW_OUTFILE="$TMP/t29.review.md" TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R29" >"$TMP/t29.out" 2>"$TMP/t29.err"
rc=$?
review_file="$(sed -n 's/^REVIEW_OUTFILE=\([^ ]*\).*/\1/p' "$TMP/t29.err" | tail -n 1)"
[ -n "$review_file" ] || fail "concise review did not emit REVIEW_OUTFILE"
review_bytes="$(wc -c < "$review_file" | tr -d ' ')"
[ "$rc" -eq 0 ] || fail "concise evidence-shaped review should pass, got rc $rc"
[ "$review_bytes" -ge 1200 ] && [ "$review_bytes" -lt 1931 ] \
  || fail "concise regression fixture must sit above 1200B and below the measured 1931B real-review floor, got ${review_bytes}B"
echo "test 29 (concise review with severity passes) PASS"

# 30-31. Realistic sign-offs clear the byte backstop but fail without evidence; the
# explicit compatibility switch disables only that evidence half of the gate.
R30="$TMP/repo30"; make_git_repo "$R30"
cat > "$TMP/bin/agy" <<'STUB'
#!/usr/bin/env bash
# PERSONA_ROSTER_STUB
case "${1:-}" in
  agent)
    printf '%s\n' "$*" >> "$AGY_ARGS_FILE"
    [ "${AGY_ROSTER_MODE:-}" = nonzero ] && exit 19
    [ "${AGY_ROSTER_MODE:-}" = empty ] || printf '%s\n' peer-security-reviewer peer-code-reviewer
    exit 0
    ;;
esac
case "$*" in *models*) printf '%s\tGemini 3.8 Flash (Medium)\n%s\tGemini 4 Argon (High)\ncustom-id\tCustom Display\ngpt-oss\tGPT-OSS 120B (Medium)\n' "$AGY_TEST_CODING_PIN" "$AGY_TEST_REVIEW_PIN"; exit 0;; esac
printf '%s\n' '## Review summary' '- The change is internally consistent and the implementation follows the brief.' '- Tests cover the expected success and failure cases.' '- Documentation appears synchronized with behavior.' '- No major issues were found after reading the affected paths.' '- Confidence is high and operational risk is low.'
for i in $(seq 1 "${SIGNOFF_NOTES:-18}"); do printf 'Additional verification note %s confirms the same findings-free sign-off without a labelled item.\n' "$i"; done
STUB
chmod +x "$TMP/bin/agy"
SIGNOFF_NOTES=3 DISPATCH_MIN_REVIEW_BYTES=1 REVIEW_OUTFILE="$TMP/t30-short.review.md" TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R30" >"$TMP/t30-short.out" 2>"$TMP/t30-short.err"
rc=$?
[ "$rc" -eq 8 ] || fail "~550B findings-free sign-off should return rc 8, got $rc"
review_file="$(sed -n 's/^REVIEW_OUTFILE=\([^ ]*\).*/\1/p' "$TMP/t30-short.err" | tail -n 1)"
review_bytes="$(wc -c < "$review_file" | tr -d ' ')"
[ "$review_bytes" -ge 450 ] && [ "$review_bytes" -le 700 ] || fail "short realistic sign-off fixture should remain ~550B, got ${review_bytes}B"
grep -q "no labelled severity or file:line evidence" "$TMP/t30-short.err" || fail "~550B sign-off did not exercise evidence-specific rejection"
REVIEW_OUTFILE="$TMP/t30.review.md" TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R30" >"$TMP/t30.out" 2>"$TMP/t30.err"
rc=$?
[ "$rc" -eq 8 ] || fail "long output without evidence should return rc 8, got $rc"
review_file="$(sed -n 's/^REVIEW_OUTFILE=\([^ ]*\).*/\1/p' "$TMP/t30.err" | tail -n 1)"
[ "$(wc -c < "$review_file" | tr -d ' ')" -gt 1200 ] || fail "sign-off evidence fixture must exceed 1200B"
grep -q "no labelled severity or file:line evidence" "$TMP/t30.err" || fail "missing-evidence failure did not name its distinct cause"
echo "test 30 (long review without evidence fails closed) PASS"

DISPATCH_REVIEW_REQUIRE_EVIDENCE=0 TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R30" >"$TMP/t31.out" 2>"$TMP/t31.err"
rc=$?
[ "$rc" -eq 0 ] || fail "disabled evidence gate should allow the same long output, got rc $rc"
echo "test 31 (evidence gate can be disabled) PASS"

# R33 is reused by persona retries; origin and decoy are reused by config cases.
# 31e. Requirements-mode evidence: a per-row disposition table (row ID
# + ALIGN/OBJECT/ABSTAIN) is the deliverable a PRD review brief asks for and carries neither
# a severity token nor a file:line cite. It must pass the evidence gate AND the byte backstop
# (a small PRD's complete table is well under 1200B), while row-free prose in the same
# vocabulary ("Aligned rows: no objection ... ALIGN") still fails closed as rc 8.
R31E="$TMP/repo31e"; make_git_repo "$R31E"
cat > "$TMP/bin/agy" <<'STUB'
#!/usr/bin/env bash
# PERSONA_ROSTER_STUB
case "${1:-}" in
  agent)
    printf '%s\n' "$*" >> "$AGY_ARGS_FILE"
    [ "${AGY_ROSTER_MODE:-}" = nonzero ] && exit 19
    [ "${AGY_ROSTER_MODE:-}" = empty ] || printf '%s\n' peer-security-reviewer peer-code-reviewer
    exit 0
    ;;
esac
case "$*" in *models*) printf '%s\tGemini 3.8 Flash (Medium)\n%s\tGemini 4 Argon (High)\ncustom-id\tCustom Display\ngpt-oss\tGPT-OSS 120B (Medium)\n' "$AGY_TEST_CODING_PIN" "$AGY_TEST_REVIEW_PIN"; exit 0;; esac
if [ "${ROWVERDICT_MODE:-table}" = table ]; then
  printf '%s\n' '## Per-row dispositions' '| Row | Disposition |' '|---|---|' '| R1.1 | ALIGN |' '| R1.2 | ALIGN |' '| E3 | ABSTAIN (out of lens) |' '| M1 | ALIGN |' '' 'Findings: none.'
else
  printf '%s\n' '## Per-row dispositions' 'Aligned rows: no objection. Every row reads as ALIGN from this lens.' 'Findings: none.'
fi
STUB
chmod +x "$TMP/bin/agy"
REVIEW_OUTFILE="$TMP/t31e-table.review.md" TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R31E" >"$TMP/t31e-table.out" 2>"$TMP/t31e-table.err"
rc=$?
[ "$rc" -eq 0 ] || fail "short per-row disposition table should pass as requirements-mode evidence, got rc $rc"
review_file="$(sed -n 's/^REVIEW_OUTFILE=\([^ ]*\).*/\1/p' "$TMP/t31e-table.err" | tail -n 1)"
[ "$(wc -c < "$review_file" | tr -d ' ')" -lt 1200 ] || fail "row-verdict fixture must sit below the 1200B backstop to prove the exemption"
ROWVERDICT_MODE=prose DISPATCH_MIN_REVIEW_BYTES=1 REVIEW_OUTFILE="$TMP/t31e-prose.review.md" TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R31E" >"$TMP/t31e-prose.out" 2>"$TMP/t31e-prose.err"
rc=$?
[ "$rc" -eq 8 ] || fail "row-free ALIGN prose should still fail closed as rc 8, got $rc"
grep -q "no labelled severity or file:line evidence" "$TMP/t31e-prose.err" || fail "row-free ALIGN prose did not hit the evidence-specific rejection"
ROWVERDICT_MODE=prose REVIEW_OUTFILE="$TMP/t31e-prose-short.review.md" TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R31E" >"$TMP/t31e-prose-short.out" 2>"$TMP/t31e-prose-short.err"
rc=$?
[ "$rc" -eq 8 ] || fail "row-free short prose must still hit the byte backstop, got rc $rc"
grep -q "output too short" "$TMP/t31e-prose-short.err" || fail "row-free short prose did not hit the byte-specific branch"
echo "test 31e (requirements-mode per-row verdicts pass; row-free ALIGN prose still fails) PASS"

# 32. The default isolated worktree is adjacent to the source repos under the
# house .worktrees directory, not the platform temporary worktree template.
R32="$TMP/repo32"; make_git_repo "$R32"
cat > "$TMP/bin/agy" <<'STUB'
#!/usr/bin/env bash
# PERSONA_ROSTER_STUB
case "${1:-}" in
  agent)
    printf '%s\n' "$*" >> "$AGY_ARGS_FILE"
    [ "${AGY_ROSTER_MODE:-}" = nonzero ] && exit 19
    [ "${AGY_ROSTER_MODE:-}" = empty ] || printf '%s\n' peer-security-reviewer peer-code-reviewer
    exit 0
    ;;
esac
printf 'PWD=%s\n' "$PWD" >> "$AGY_ARGS_FILE"
case "$*" in *models*) printf '%s\tGemini 3.8 Flash (Medium)\n%s\tGemini 4 Argon (High)\ncustom-id\tCustom Display\ngpt-oss\tGPT-OSS 120B (Medium)\n' "$AGY_TEST_CODING_PIN" "$AGY_TEST_REVIEW_PIN"; exit 0;; esac
# GNU coreutils stat may precede BSD stat on PATH, and its -f means something else
# entirely (filesystem info), so try the GNU form FIRST and fall back to BSD.
parent_mode="$(stat -c '%a' "$(dirname "$PWD")" 2>/dev/null || stat -f '%Lp' "$(dirname "$PWD")" 2>/dev/null)"
[ -d .git ] && echo GIT_DIR_DIRECTORY >> "$AGY_ARGS_FILE"
printf 'PARENT_MODE=%s\n' "$parent_mode" >> "$AGY_ARGS_FILE"
for i in $(seq 1 40); do printf 'Minor: finding %s: worktree location checked.\n' "$i"; done
STUB
chmod +x "$TMP/bin/agy"
: > "$AGY_ARGS_FILE"
TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R32" >"$TMP/t32.out" 2>"$TMP/t32.err"
rc=$?
[ "$rc" -eq 0 ] || fail "default worktree-location review should pass, got rc $rc"
review_pwd="$(sed -n 's/^PWD=//p' "$AGY_ARGS_FILE" | tail -n 1)"
tmp_real="$(cd -P "$TMP" && pwd)"
case "$review_pwd" in "$tmp_real/.worktrees/dispatch-review-wt."*) ;; *) fail "review cwd was not in adjacent .worktrees: $review_pwd";; esac
case "$review_pwd" in "$TMPDIR"/*) fail "review cwd was created under TMPDIR: $review_pwd";; esac
[ ! -e "$review_pwd" ] || fail "default review worktree was not cleaned up: $review_pwd"
[ ! -d "$TMP/.worktrees" ] || fail "empty default .worktrees parent was left behind"
grep -qFx GIT_DIR_DIRECTORY "$AGY_ARGS_FILE" || fail "review .git was not a directory"
echo "test 32 (review worktree is outside platform temp template and cleaned) PASS"

# 33. A parent created by dispatch is private, honored, and reclaimed when empty.
R33="$TMP/repo33"; make_git_repo "$R33"
WT_OVERRIDE="$TMP/review-wt-override"
: > "$AGY_ARGS_FILE"
DISPATCH_REVIEW_WT_DIR="$WT_OVERRIDE" TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R33" >"$TMP/t33.out" 2>"$TMP/t33.err"
rc=$?
[ "$rc" -eq 0 ] || fail "worktree override review should pass, got rc $rc"
review_pwd="$(sed -n 's/^PWD=//p' "$AGY_ARGS_FILE" | tail -n 1)"
case "$review_pwd" in "$WT_OVERRIDE/dispatch-review-wt."*) ;; *) fail "DISPATCH_REVIEW_WT_DIR was not honored: $review_pwd";; esac
grep -q '^PARENT_MODE=700$' "$AGY_ARGS_FILE" || fail "created review parent was not mode 0700"
[ ! -e "$review_pwd" ] || fail "overridden review worktree was not cleaned up"
[ ! -d "$WT_OVERRIDE" ] || fail "empty overridden worktree parent was left behind"
grep -qFx GIT_DIR_DIRECTORY "$AGY_ARGS_FILE" || fail "review .git was not a directory"
echo "test 33 (review worktree directory override is honored) PASS"

# 33b. A pre-existing empty operator-owned parent survives cleanup unchanged.
WT_PREEXIST="$TMP/review-wt-preexisting"; mkdir -m 700 "$WT_PREEXIST"
: > "$AGY_ARGS_FILE"
DISPATCH_REVIEW_WT_DIR="$WT_PREEXIST" TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R33" >"$TMP/t33b.out" 2>"$TMP/t33b.err"
rc=$?
[ "$rc" -eq 0 ] || fail "pre-existing-parent review should pass, got rc $rc"
[ -d "$WT_PREEXIST" ] || fail "cleanup removed the operator's pre-existing empty parent"
[ -z "$(find "$WT_PREEXIST" -mindepth 1 -maxdepth 1 -print -quit)" ] || fail "pre-existing parent retained a stray entry"
echo "test 33b (pre-existing empty parent survives cleanup) PASS"

# V13. Reap old clones and source worktrees, preserving fresh and foreign entries.
REAPER_PARENT="$TMP/reaper preferred"
mkdir -p "$REAPER_PARENT"
REAPER_OTHER="$TMP/reaper-other-repo"; make_git_repo "$REAPER_OTHER"
git clone --quiet --local "$R33" "$REAPER_PARENT/dispatch-review-wt.old1" || fail "V13 old clone setup"
git -C "$R33" worktree add --quiet --detach "$REAPER_PARENT/dispatch-review-wt.old2" HEAD || fail "V13 legacy setup"
git clone --quiet --local "$R33" "$REAPER_PARENT/dispatch-review-wt.new" || fail "V13 fresh clone setup"
mkdir "$REAPER_PARENT/other-dir"
git -C "$REAPER_OTHER" worktree add --quiet --detach "$REAPER_PARENT/dispatch-review-wt.sib" HEAD || fail "V13 foreign setup"
touch -t 202001010000 "$REAPER_PARENT/dispatch-review-wt.old1" "$REAPER_PARENT/dispatch-review-wt.old2" "$REAPER_PARENT/other-dir" "$REAPER_PARENT/dispatch-review-wt.sib"
DISPATCH_REVIEW_WT_DIR="$REAPER_PARENT" TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R33" >"$TMP/v13.out" 2>"$TMP/v13.err"
rc=$?
[ "$rc" -eq 0 ] || fail "V13 preferred review failed"
[ ! -e "$REAPER_PARENT/dispatch-review-wt.old1" ] || fail "V13 old clone survived"
[ ! -e "$REAPER_PARENT/dispatch-review-wt.old2" ] || fail "V13 old source worktree survived"
[ -d "$REAPER_PARENT/dispatch-review-wt.new/.git" ] || fail "V13 fresh clone removed"
[ -d "$REAPER_PARENT/other-dir" ] || fail "V13 unrelated directory removed"
[ -f "$REAPER_PARENT/dispatch-review-wt.sib/.git" ] || fail "V13 foreign worktree removed"
git -C "$REAPER_PARENT/dispatch-review-wt.sib" rev-parse --verify HEAD >/dev/null || fail "V13 foreign worktree damaged"
REAPER_CACHE="$TMP/reaper-cache"
mkdir -p "$REAPER_CACHE/dispatch-review-worktrees"
git clone --quiet --local "$R33" "$REAPER_CACHE/dispatch-review-worktrees/dispatch-review-wt.old1" || fail "V13 cache clone setup"
touch -t 202001010000 "$REAPER_CACHE/dispatch-review-worktrees/dispatch-review-wt.old1"
DISPATCH_REVIEW_WT_DIR="$TMPDIR/reaper-rejected" XDG_CACHE_HOME="$REAPER_CACHE" TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R33" >"$TMP/v13-cache.out" 2>"$TMP/v13-cache.err"
rc=$?
[ "$rc" -eq 0 ] || fail "V13 cache review failed"
[ ! -e "$REAPER_CACHE/dispatch-review-worktrees/dispatch-review-wt.old1" ] || fail "V13 cache old clone survived"
echo "test V13 (reaper handles clones and legacy worktrees in both parents) PASS"

# 34. Cleanup removes only its worktree: a concurrent sibling worktree survives.
R34="$TMP/repo34"; make_git_repo "$R34"
WT_SHARED="$TMP/review-wt-shared"; mkdir -p "$WT_SHARED"
SIBLING_WT="$WT_SHARED/concurrent-review"
git -C "$R34" worktree add --quiet --detach "$SIBLING_WT" HEAD || fail "could not create concurrent sibling fixture"
: > "$AGY_ARGS_FILE"
DISPATCH_REVIEW_WT_DIR="$WT_SHARED" TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R34" >"$TMP/t34.out" 2>"$TMP/t34.err"
rc=$?
[ "$rc" -eq 0 ] || fail "shared-parent cleanup review should pass, got rc $rc"
review_pwd="$(sed -n 's/^PWD=//p' "$AGY_ARGS_FILE" | tail -n 1)"
[ ! -e "$review_pwd" ] || fail "review worktree remained in non-empty parent"
[ -d "$SIBLING_WT" ] || fail "cleanup removed the concurrent sibling worktree"
[ "$(find "$WT_SHARED" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 1 ] || fail "cleanup left a stray entry beside the sibling worktree"
git -C "$R34" worktree remove --force "$SIBLING_WT" >/dev/null 2>&1 || true
grep -qFx GIT_DIR_DIRECTORY "$AGY_ARGS_FILE" || fail "review .git was not a directory"
echo "test 34 (cleanup preserves non-empty parent without stray worktree) PASS"

# 35. An unusable preferred parent falls back loudly and remains hermetic.
R35="$TMP/repo35"; make_git_repo "$R35"
pre_head="$(git -C "$R35" rev-parse HEAD)"
WT_DENIED="$TMP/review-wt-denied"; mkdir "$WT_DENIED"; chmod 555 "$WT_DENIED"
XDG35="$(mktemp -d /tmp/dispatch-cache-test.XXXXXX)"
: > "$AGY_ARGS_FILE"
DISPATCH_REVIEW_WT_DIR="$WT_DENIED" XDG_CACHE_HOME="$XDG35" TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R35" >"$TMP/t35.out" 2>"$TMP/t35.err"
rc=$?
chmod 755 "$WT_DENIED"
[ "$rc" -eq 0 ] || fail "fallback review should still pass, got rc $rc"
grep -q "preferred review worktree parent is unusable" "$TMP/t35.err" || fail "fallback did not print its warning"
review_pwd="$(sed -n 's/^PWD=//p' "$AGY_ARGS_FILE" | tail -n 1)"
[ "$review_pwd" != "$R35" ] || fail "fallback review ran non-hermetically in the operator tree"
[ "$(git -C "$R35" rev-parse HEAD)" = "$pre_head" ] && [ -z "$(git -C "$R35" status --porcelain)" ] || fail "fallback review changed the operator tree"
rmdir "$WT_DENIED" 2>/dev/null || true; rm -rf "$XDG35"
grep -qFx GIT_DIR_DIRECTORY "$AGY_ARGS_FILE" || fail "review .git was not a directory"
echo "test 35 (unusable parent fallback remains hermetic) PASS"

# 36. A source repo whose adjacent parent resolves under TMPDIR is redirected
# to the outside cache; the suite-wide TMPDIR redirection remains intact.
TMP36="$(mktemp -d /tmp/dispatch-platform-test.XXXXXX)"
R36="$TMP36/repos/repo36"; make_git_repo "$R36"
XDG36="$(mktemp -d /tmp/dispatch-outside-cache.XXXXXX)"
: > "$AGY_ARGS_FILE"
TMPDIR="$TMP36" XDG_CACHE_HOME="$XDG36" TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R36" >"$TMP/t36.out" 2>"$TMP/t36.err"
rc=$?
[ "$rc" -eq 0 ] || fail "TMPDIR-contained source review should pass via cache, got rc $rc"
review_pwd="$(sed -n 's/^PWD=//p' "$AGY_ARGS_FILE" | tail -n 1)"
case "$review_pwd" in "$TMP36"/*) fail "review worktree silently remained under resolved TMPDIR: $review_pwd";; esac
rm -rf "$TMP36" "$XDG36"
echo "test 36 (TMPDIR-contained source redirects outside TMPDIR) PASS"

# 37. --agent is agy-only, validates the installed roster, and is threaded into
# edit dispatch. Keep the one-line-per-invocation "$*" capture: counts prove the
# number of dispatch calls without disturbing the existing multi-word --model checks.
cat > "$TMP/bin/agy" <<'STUB'
#!/usr/bin/env bash
# PERSONA_ROSTER_STUB
case "${1:-}" in
  agent)
    printf '%s\n' "$*" >> "$AGY_ARGS_FILE"
    [ "${AGY_ROSTER_MODE:-}" = nonzero ] && exit 19
    [ "${AGY_ROSTER_MODE:-}" = empty ] || printf '%s\n' peer-security-reviewer peer-code-reviewer
    exit 0
    ;;
esac
printf '%s\n' "$*" >> "$AGY_ARGS_FILE"
case "${1:-}" in
  models) printf '%s\tGemini 3.8 Flash (Medium)\n%s\tGemini 4 Argon (High)\ncustom-id\tCustom Display\ngpt-oss\tGPT-OSS 120B (Medium)\n' "$AGY_TEST_CODING_PIN" "$AGY_TEST_REVIEW_PIN"; exit 0 ;;
  agent) printf '%s\n' peer-security-reviewer peer-code-reviewer; exit 0 ;;
esac
cat
STUB
chmod +x "$TMP/bin/agy"
: > "$AGY_ARGS_FILE"
TIMEOUT=0 "$DW" --runtime agy --brief "$BRIEF" --workdir /repo/x >/dev/null 2>&1
[ "$(agy_exec_args)" = "--model $AGY_MODEL_CODING_DEFAULT" ] \
  || fail "non---agent argv changed; golden filters only the auth-probe 'models' line (got: $(cat "$AGY_ARGS_FILE"))"
: > "$AGY_ARGS_FILE"
TIMEOUT=0 "$DW" --runtime agy --agent peer-security-reviewer --brief "$BRIEF" --workdir /repo/x >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "known agy persona should dispatch, got rc $rc"
[ "$(grep -c -- '--agent=peer-security-reviewer' "$AGY_ARGS_FILE")" -eq 1 ] \
  || fail "agy edit should carry --agent exactly once (got: $(cat "$AGY_ARGS_FILE"))"
echo "test 37 (agy --agent validates and threads edit invocation) PASS"

# 38. Unknown personas fail loudly before dispatch instead of falling through to
# agy's rc-0 general assistant. The args log may contain auth + roster probes only.
: > "$AGY_ARGS_FILE"
TIMEOUT=0 "$DW" --runtime agy --agent totally-bogus-persona-zzz --brief "$BRIEF" --workdir /repo/x >"$TMP/t38.out" 2>"$TMP/t38.err"
rc=$?
[ "$rc" -eq 2 ] || fail "unknown agy persona should exit 2, got rc $rc"
grep -qF "unknown agy persona: totally-bogus-persona-zzz" "$TMP/t38.err" \
  || fail "unknown persona error did not name the persona"
[ "$(agy_exec_args | wc -l | tr -d ' ')" -eq 1 ] || fail "unknown persona reached review/edit dispatch: $(cat "$AGY_ARGS_FILE")"
echo "test 38 (unknown agy persona fails before dispatch) PASS"

# 39. A persona selector on unsupported runtimes is an argument error.
for unsupported in codex claude; do
  TIMEOUT=0 "$DW" --runtime "$unsupported" --agent peer-security-reviewer --brief "$BRIEF" >"$TMP/t39.out" 2>"$TMP/t39.err"
  rc=$?
  [ "$rc" -eq 2 ] || fail "--agent with $unsupported should exit 2, got rc $rc"
  grep -qF -- "--agent is only supported with --runtime agy" "$TMP/t39.err" \
    || fail "--agent with $unsupported lacked the agy-only error"
done
echo "test 39 (--agent rejects codex and claude) PASS"

# An ambient CI variable named AGENT must not act like the explicit --agent flag.
export AGENT=some-ci-value
TIMEOUT=0 "$DW" --runtime codex --brief "$BRIEF" >"$TMP/t39b.out" 2>"$TMP/t39b.err"
rc=$?
unset AGENT
[ "$rc" -eq 0 ] || fail "ambient AGENT broke default codex dispatch with rc $rc"
! grep -qFx -- 'dispatch-worker: --agent is only supported with --runtime agy' "$TMP/t39b.err" \
  || fail "ambient AGENT was incorrectly treated as an explicit --agent flag"
echo "test 39b (ambient AGENT cannot select an agy persona) PASS"

# 40. Review first attempt and its one timeout retry both retain the persona.
export AGY_COUNT_FILE="$TMP/agy-agent-retry-count"
printf '0\n' > "$AGY_COUNT_FILE"
cat > "$TMP/bin/agy" <<'STUB'
#!/usr/bin/env bash
# PERSONA_ROSTER_STUB
case "${1:-}" in
  agent)
    printf '%s\n' "$*" >> "$AGY_ARGS_FILE"
    [ "${AGY_ROSTER_MODE:-}" = nonzero ] && exit 19
    [ "${AGY_ROSTER_MODE:-}" = empty ] || printf '%s\n' peer-security-reviewer peer-code-reviewer
    exit 0
    ;;
esac
printf '%s\n' "$*" >> "$AGY_ARGS_FILE"
case "${1:-}" in
  models) printf '%s\tGemini 3.8 Flash (Medium)\n%s\tGemini 4 Argon (High)\ncustom-id\tCustom Display\ngpt-oss\tGPT-OSS 120B (Medium)\n' "$AGY_TEST_CODING_PIN" "$AGY_TEST_REVIEW_PIN"; exit 0 ;;
  agent) printf '%s\n' peer-security-reviewer peer-code-reviewer; exit 0 ;;
esac
n="$(cat "$AGY_COUNT_FILE")"; n=$((n + 1)); printf '%s\n' "$n" > "$AGY_COUNT_FILE"
if [ "$n" -eq 1 ]; then exit 124; fi
for i in $(seq 1 40); do printf 'Major: security review evidence at src/auth.sh:12, line %s.\n' "$i"; done
STUB
chmod +x "$TMP/bin/agy"
: > "$AGY_ARGS_FILE"
TIMEOUT=0 "$DW" --runtime agy --review --agent peer-security-reviewer --brief "$BRIEF" --workdir "$R33" >"$TMP/t40.out" 2>"$TMP/t40.err"
rc=$?
[ "$rc" -eq 0 ] || fail "persona review timeout retry should succeed, got rc $rc"
[ "$(grep -c -- '--agent=peer-security-reviewer' "$AGY_ARGS_FILE")" -eq 2 ] \
  || fail "review first attempt and retry did not both carry persona: $(cat "$AGY_ARGS_FILE")"
echo "test 40 (agy review first attempt and retry both carry --agent) PASS"

# 41. Persona-roster failures are fail-closed and never reach review dispatch.
for roster_mode in nonzero empty; do
  export AGY_ROSTER_MODE="$roster_mode"
  cat > "$TMP/bin/agy" <<'STUB'
#!/usr/bin/env bash
# PERSONA_ROSTER_STUB
case "${1:-}" in
  agent)
    printf '%s\n' "$*" >> "$AGY_ARGS_FILE"
    [ "${AGY_ROSTER_MODE:-}" = nonzero ] && exit 19
    [ "${AGY_ROSTER_MODE:-}" = empty ] || printf '%s\n' peer-security-reviewer peer-code-reviewer
    exit 0
    ;;
esac
printf '%s\n' "$*" >> "$AGY_ARGS_FILE"
case "${1:-}" in
  models) printf '%s\tGemini 3.8 Flash (Medium)\n%s\tGemini 4 Argon (High)\ncustom-id\tCustom Display\ngpt-oss\tGPT-OSS 120B (Medium)\n' "$AGY_TEST_CODING_PIN" "$AGY_TEST_REVIEW_PIN"; exit 0 ;;
  agent)
    [ "$AGY_ROSTER_MODE" = nonzero ] && exit 19
    exit 0
    ;;
esac
printf 'DISPATCHED\n'
STUB
  chmod +x "$TMP/bin/agy"
  : > "$AGY_ARGS_FILE"
  TIMEOUT=0 "$DW" --runtime agy --agent peer-security-reviewer --brief "$BRIEF" --workdir /repo/x >"$TMP/t41.out" 2>"$TMP/t41.err"
  rc=$?
  [ "$rc" -ne 0 ] || fail "$roster_mode persona roster should fail closed"
  ! grep -qFx 'DISPATCHED' "$TMP/t41.out" || fail "$roster_mode persona roster dispatched anyway"
  [ "$(agy_exec_args | wc -l | tr -d ' ')" -eq 1 ] || fail "$roster_mode roster reached dispatch: $(cat "$AGY_ARGS_FILE")"
done
echo "test 41 (agy persona roster failure/empty output fail closed) PASS"

# 41b. The persona roster probe must detach stdin. This stub's roster arm blocks
# on cat if the worker leaks its caller's still-open stdin into `agy agent`.
cat > "$TMP/bin/agy" <<'STUB'
#!/usr/bin/env bash
# PERSONA_ROSTER_STUB
case "${1:-}" in
  models) printf '%s\tGemini 3.8 Flash (Medium)\n%s\tGemini 4 Argon (High)\ncustom-id\tCustom Display\ngpt-oss\tGPT-OSS 120B (Medium)\n' "$AGY_TEST_CODING_PIN" "$AGY_TEST_REVIEW_PIN"; exit 0 ;;
  agent) cat; exit 0 ;;
esac
printf 'DISPATCHED\n'
STUB
chmod +x "$TMP/bin/agy"
timeout_cmd=$(dispatch_timeout_bin) || { echo "FAIL: no usable timer" >&2; exit 1; }
  set +e
  ( sleep 10 ) | "$timeout_cmd" 6s env TIMEOUT=0 "$DW" --runtime agy --agent peer-security-reviewer --brief "$BRIEF" --workdir /repo/x >"$TMP/t41b.out" 2>"$TMP/t41b.err"
  rc=$?
  set -e
  [ "$rc" -ne 124 ] || fail "agy persona roster probe hung on inherited stdin"
  [ "$rc" -eq 2 ] || fail "empty detached roster should fail closed with rc 2, got rc $rc"
echo "test 41b (agy persona roster probe detaches stdin) PASS"

install_cfg_agy_stub
unset AGY_ROSTER_MODE
R43="$TMP/repo43"; make_git_repo "$R43"
cat > "$AGY_STUB_ACTIONS" <<'ACTIONS'
git rev-parse --path-format=absolute --git-dir > "$AGY_ARGS_FILE.gitdir"
git rev-parse --path-format=absolute --git-common-dir > "$AGY_ARGS_FILE.common"
{ test -d .git && echo dir; ls -ld . | cut -c1-10; } > "$AGY_ARGS_FILE.mode"
env | grep -c '^GIT_DIR=' > "$AGY_ARGS_FILE.env"
ACTIONS
before=$(git -C "$R43" worktree list)
run_cfg_review "$R43" || fail 'V1 launch failed'
[ ! -e "$(git -C "$R43" rev-parse --absolute-git-dir)/review-pinned" ] || fail "review pin not released normal"
review_pwd=$(sed -n 's/^PWD=//p' "$AGY_ARGS_FILE")
[ "$(cat "$AGY_ARGS_FILE.gitdir")" = "$review_pwd/.git" ] || fail 'V1 git dir shared'
[ "$(cat "$AGY_ARGS_FILE.common")" = "$review_pwd/.git" ] || fail 'V1 common dir shared'
grep -qFx dir "$AGY_ARGS_FILE.mode" || fail 'V1 .git not directory'
grep -qFx drwx------ "$AGY_ARGS_FILE.mode" || fail 'V1 workspace not private'
[ "$before" = "$(git -C "$R43" worktree list)" ] || fail 'V1 source worktrees changed'
decoy="$TMP/decoy43"; make_git_repo "$decoy"
GIT_DIR="$decoy/.git" run_cfg_review "$R43"
[ "$(cat "$AGY_ARGS_FILE.env")" = 0 ] || fail 'review inherited GIT_DIR'

origin="$TMP/origin43"; git -C "$TMP" init --bare "$origin" >/dev/null 2>&1
git -C "$R43" remote add origin "$origin"
git -C "$R43" push origin review-main:main >/dev/null 2>&1
git -C "$R43" checkout -b feature >/dev/null 2>&1
echo feature >> "$R43/README.md"
git -C "$R43" -c user.name=Test -c user.email=test@example.com commit -am feature >/dev/null 2>&1
git -C "$R43" tag example
echo stash >> "$R43/README.md"
git -C "$R43" -c user.name=Test -c user.email=test@example.com stash >/dev/null 2>&1
cat > "$AGY_STUB_ACTIONS" <<'ACTIONS'
{
git rev-list --count review-main..feature
git rev-parse origin/main
git rev-parse HEAD
git fetch origin >/dev/null 2>&1; echo fetch=$?
git rev-parse origin/main
} > "$AGY_ARGS_FILE.refs"
ACTIONS
run_cfg_review "$R43" || fail 'V2 launch failed'
expected_origin=$(git -C "$R43" rev-parse origin/main)
expected_head=$(git -C "$R43" rev-parse HEAD)
[ "$(sed -n '1p' "$AGY_ARGS_FILE.refs")" = "$(git -C "$R43" rev-list --count review-main..feature)" ] || fail 'V2 range changed'
[ "$(sed -n '2p' "$AGY_ARGS_FILE.refs")" = "$expected_origin" ] || fail 'V2 origin changed'
[ "$(sed -n '3p' "$AGY_ARGS_FILE.refs")" = "$expected_head" ] || fail 'V2 HEAD changed'
! grep -qFx fetch=0 "$AGY_ARGS_FILE.refs" || fail 'V2 fetch enabled'
[ "$(sed -n '5p' "$AGY_ARGS_FILE.refs")" = "$expected_origin" ] || fail 'V2 fetch moved origin'
! grep -q unsuitable "$TMP/cfg.err" || fail 'stash disabled clone'
linked="$TMP/linked43"
git -C "$R43" checkout review-main >/dev/null 2>&1
git -C "$R43" worktree add "$linked" feature >/dev/null 2>&1
run_cfg_review "$linked"
[ ! -e "$(git -C "$linked" rev-parse --absolute-git-dir)/review-pinned" ] || fail "review pin not released linked"
[ "$(sed -n '3p' "$AGY_ARGS_FILE.refs")" = "$expected_head" ] || fail 'linked source HEAD changed'
git -C "$R43" config filter.x.clean cat
run_cfg_review "$R43" || fail 'unsuitable fallback failed'
grep -q 'unsuitable for a private clone' "$TMP/cfg.err" || fail 'missing unsuitable warning'
! grep -q -- --dangerously-skip-permissions "$AGY_ARGS_FILE" || fail 'fallback bypasses permissions'
last_repo="$TMP/last-repo"; make_git_repo "$last_repo"
denied="$TMP/last-denied"; mkdir -m 555 "$denied"
DISPATCH_REVIEW_WT_DIR="$denied" XDG_CACHE_HOME="$TMPDIR/cache" run_cfg_review "$last_repo" || fail 'last-resort launch failed'
review_pwd=$(sed -n 's/^PWD=//p' "$AGY_ARGS_FILE")
grep -qF "falling back to $review_pwd, where agy" "$TMP/cfg.err" || fail "last-resort path not reached: $review_pwd"
[ ! -e "$review_pwd" ] || fail "last-resort workspace survived: $review_pwd"
[ -z "$(find "$TMPDIR" -name 'dispatch-review-wt.*' -print)" ] || fail 'last-resort workspace leaked'
echo 'test 43 (private clone, refs, environment and fallback) PASS'

# V3. Global reads are flattened and every reviewer write stays private.
r44="$TMP/repo44"; make_config_fixture "$r44"
cp "$GIT_CONFIG_GLOBAL" "$TMP/global.before"
cp "$r44/.git/config" "$TMP/local.before"
git -C "$r44" for-each-ref > "$TMP/refs.before"
git -C "$r44" worktree list --porcelain > "$TMP/worktrees.before"
cat > "$AGY_STUB_ACTIONS" <<'ACTIONS'
{
git config --global --get user.email
git config --global --get core.editor
git config --global --bool --get x.flag
ls -l "$GIT_CONFIG_GLOBAL" | cut -c1-10
} > "$AGY_ARGS_FILE.global"
git config user.name x
git config --global user.email x@x.invalid
git branch scratch
git branch -D feature
git checkout -b other
git push origin HEAD:refs/heads/evil >/dev/null 2>&1; echo push=$? > "$AGY_ARGS_FILE.push"
ACTIONS
run_cfg_review "$r44" || fail 'V3 launch failed'
grep -qF 'DISPATCH_REVIEW_STATE=clean' "$TMP/cfg.err" || fail 'V3 missing clean state'
[ "$(sed -n '1p' "$AGY_ARGS_FILE.global")" = review@example.invalid ] || fail 'V3 global identity lost'
[ "$(sed -n '2p' "$AGY_ARGS_FILE.global")" = ed ] || fail 'V3 included editor lost'
[ "$(sed -n '3p' "$AGY_ARGS_FILE.global")" = true ] || fail 'V3 valueless flag lost'
[ "$(sed -n '4p' "$AGY_ARGS_FILE.global")" = -rw------- ] || fail 'V3 global config permissions'
cmp -s "$GIT_CONFIG_GLOBAL" "$TMP/global.before" || fail 'V3 global config changed'
cmp -s "$r44/.git/config" "$TMP/local.before" || fail 'V3 source config changed'
git -C "$r44" for-each-ref > "$TMP/refs.after"
git -C "$r44" worktree list --porcelain > "$TMP/worktrees.after"
cmp -s "$TMP/refs.before" "$TMP/refs.after" || fail 'V3 source refs changed'
cmp -s "$TMP/worktrees.before" "$TMP/worktrees.after" || fail 'V3 source worktrees changed'
grep -q '^push=[1-9][0-9]*$' "$AGY_ARGS_FILE.push" || fail 'V3 push enabled'
[ -z "$(find "$TMPDIR" -name 'dispatch-review-state.*' -print)" ] || fail 'V3 state directory leaked'
[ -z "$(find "$TMPDIR" -name 'dispatch-snapshots.*' -print)" ] || fail 'V3 snapshot directory leaked'
: > "$AGY_STUB_ACTIONS"
GIT_CONFIG_GLOBAL="$TMP/missing-global" run_cfg_review "$r44" || fail 'missing global config launch failed'
[ ! -e "$TMP/missing-global" ] || fail 'missing global config created outside review'
[ -z "$(find "$TMPDIR" -name 'dispatch-review-state.*' -print)" ] || fail 'missing global state directory leaked'
[ -z "$(find "$TMPDIR" -name 'dispatch-snapshots.*' -print)" ] || fail 'missing global snapshot directory leaked'
echo 'test 44 (private flattened global config and absent global config) PASS'

restore_default_agy_stub
assert_no_review_residue
if [ "$FAILS" -ne 0 ]; then
  echo "$FAILS TEST(S) FAILED"
  exit 1
fi
echo "ALL PASS"
