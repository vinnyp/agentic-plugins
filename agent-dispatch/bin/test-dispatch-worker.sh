#!/usr/bin/env bash
# Test dispatch-worker's --review (read-only peer-review) mode against the default
# autonomous-EDIT mode. The unit-of-proof is the BRIEF that gets assembled and fed
# to the runtime on stdin — observable by stubbing `agy`/`codex` on PATH. We do NOT
# drive real agy/codex (slow, non-deterministic, and out of scope: the contract this
# guards is the brief text, not the runtime's behavior).
#
# Load-bearing assertions:
#   - agy --review brief carries the read-only preamble and does NOT carry the
#     `_coding-result.json` marker or "narration ... IGNORED" (the edit-mode language
#     that corrupts a review by telling it its output doesn't count).
#   - agy edit mode (no flag) STILL carries the marker (regression guard).
#   - the post-dispatch dep-gate is skipped under --review (rc 0) but fires without it (rc 4).
#   - codex --review forces a read-only sandbox even when --ceremony is also passed.

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/test-dispatch-worker-lib.sh
. "$SELF_DIR/lib/test-dispatch-worker-lib.sh"

# Prompt-only fixtures still need a readable status probe. A local filter selects
# the documented non-hermetic path, and generated fixture data stays ignored.
PROMPT_FIXTURE="$TMP/prompt-fixture"
make_git_repo "$PROMPT_FIXTURE"
git -C "$PROMPT_FIXTURE" config filter.fixture.clean cat
export WORKDIR="$PROMPT_FIXTURE"

# Missing review pin refuses dispatch; an offered override bypasses the dead pin.
AGY_MISSING_REVIEW=1 TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" >"$TMP/missing" 2>&1; rc=$?
[ "$rc" -eq 9 ] || fail "missing review default expected rc9, got $rc"
grep -qF "$AGY_MODEL_REVIEW_DEFAULT" "$TMP/missing" || fail "missing-model diagnostic lacks ID"
[ -z "$(agy_exec_args)" ] || fail "missing model dispatched agy"
AGY_MISSING_REVIEW=1 DISPATCH_MIN_REVIEW_BYTES=1 DISPATCH_REVIEW_REQUIRE_EVIDENCE=0 TIMEOUT=0 "$DW" --runtime agy --review --model custom-id --brief "$BRIEF" >"$TMP/override" 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "offered override should dispatch, got $rc"
grep -qF -- '--model custom-id' "$AGY_ARGS_FILE" || fail "override did not reach dispatch"
: > "$AGY_ARGS_FILE"

# 1. agy --review → read-only preamble, no edit marker, no "IGNORED", brief preserved.
OUT="$(TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$PROMPT_FIXTURE" 2>/dev/null)"
grep -q "READ-ONLY REVIEW MODE" <<<"$OUT"  || fail "agy --review missing the read-only preamble"
grep -q "_coding-result.json"   <<<"$OUT"  && fail "agy --review leaked the edit-mode marker"
grep -q "IGNORED"               <<<"$OUT"  && fail "agy --review kept 'narration ... IGNORED'"
grep -q "Review the diff."      <<<"$OUT"  || fail "agy --review dropped the brief body"
grep -q "FINDING FORMAT: label EVERY finding" <<<"$OUT" || fail "agy --review missing labelled-finding contract"
grep -q "Do NOT edit, create, or delete any files" <<<"$OUT" || fail "non-hermetic agy --review lost the original read-only prohibition"
grep -q "If a tool, command, or capability your method requires is unavailable or denied" <<<"$OUT" || fail "non-hermetic agy --review missing degradation clause"
echo "test 1 (agy --review brief) PASS"

# 2. agy edit mode (no --review) → marker preamble preserved (regression guard).
OUT="$(TIMEOUT=0 "$DW" --runtime agy --brief "$BRIEF" --workdir /repo/x 2>/dev/null)"
grep -q "_coding-result.json"   <<<"$OUT"  || fail "agy edit mode lost the marker (REGRESSION)"
grep -q "READ-ONLY REVIEW MODE" <<<"$OUT"  && fail "agy edit mode wrongly used the review preamble"
echo "test 2 (agy edit-mode regression) PASS"

# 3. dep-gate skipped under --review (rc 0) but fires in edit mode (rc 4).
# This test is about the dep-gate, not review substantiveness, so disable both
# review-content gates around the passthrough stub's short shared $BRIEF.
mkdir -p "$TMP/mod"; printf 'module x\n\ngo 1.22\n' > "$TMP/mod/go.mod"
if ! DISPATCH_MIN_REVIEW_BYTES=1 DISPATCH_REVIEW_REQUIRE_EVIDENCE=0 TIMEOUT=0 "$DW" --runtime agy --review --require-dep nonexistent/dep \
  --module-dir "$TMP/mod" --brief "$BRIEF" >/dev/null 2>&1; then
  fail "--review should skip the dep gate (expected rc 0)"
fi
TIMEOUT=0 "$DW" --runtime agy --require-dep nonexistent/dep \
  --module-dir "$TMP/mod" --brief "$BRIEF" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 4 ] || fail "edit mode should fire the dep gate (expected rc 4)"
echo "test 3 (dep-gate skip under --review) PASS"

# 4. codex --review forces read-only sandbox even with --ceremony.
TIMEOUT=0 "$DW" --runtime codex --review --ceremony --brief "$BRIEF" >/dev/null 2>&1
grep -q -- "--sandbox read-only" "$CODEX_ARGS_FILE" \
  || fail "codex --review --ceremony did not force a read-only sandbox (got: $(cat "$CODEX_ARGS_FILE"))"
echo "test 4 (codex --review forces read-only) PASS"

# 4b. codex --review honors --workdir by threading it to `codex exec -C <dir>`.
CODEX_WORKDIR="$TMP/codex-review-target"; mkdir -p "$CODEX_WORKDIR"
TIMEOUT=0 "$DW" --runtime codex --review --brief "$BRIEF" --workdir "$CODEX_WORKDIR" >/dev/null 2>&1
grep -qF -- "-C $CODEX_WORKDIR" "$CODEX_ARGS_FILE" \
  || fail "codex --review did not thread --workdir as -C (got: $(cat "$CODEX_ARGS_FILE"))"
TIMEOUT=0 "$DW" --runtime codex --review --model gpt-5.4-mini --brief "$BRIEF" --workdir "$CODEX_WORKDIR" >/dev/null 2>&1
grep -qF -- "-C $CODEX_WORKDIR" "$CODEX_ARGS_FILE" \
  || fail "codex --review with --model did not thread --workdir as -C (got: $(cat "$CODEX_ARGS_FILE"))"
echo "test 4b (codex --review threads workdir via -C) PASS"

# 5. --help advertises --review.
"$DW" --help 2>&1 | grep -qi "review" || fail "--help doesn't mention --review"
echo "test 5 (--help) PASS"

# 6. agy --review defaults to the review model (Pro/High), multi-word name intact.
TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$PROMPT_FIXTURE" >/dev/null 2>&1
grep -qF -- "--model $AGY_MODEL_REVIEW_DEFAULT" <<<"$(agy_exec_args)" || fail "agy --review missing/!= review model (got: $(cat "$AGY_ARGS_FILE"))"
echo "test 6 (agy review model default) PASS"

# 7. agy edit mode defaults to the coding model (Flash/Medium).
TIMEOUT=0 "$DW" --runtime agy --brief "$BRIEF" --workdir /repo/x >/dev/null 2>&1
grep -qF -- "--model $AGY_MODEL_CODING_DEFAULT" <<<"$(agy_exec_args)" || fail "agy edit missing/!= coding model"
echo "test 7 (agy edit model default) PASS"

# 8. explicit --model overrides.
TIMEOUT=0 "$DW" --runtime agy --review --model "GPT-OSS 120B (Medium)" --brief "$BRIEF" --workdir "$PROMPT_FIXTURE" >/dev/null 2>&1
grep -qF -- "--model GPT-OSS 120B (Medium)" <<<"$(agy_exec_args)" || fail "--model override ignored"
echo "test 8 (--model override) PASS"

# 8b. agy dispatch uses bare stdin: no stale `exec` token and no bare `-`
# positional. The stub exits non-zero on either rejected arg, so this asserts the
# runtime actually reached dispatch after healthy auth.
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
case "${1:-}" in models) printf '%s\tGemini 3.8 Flash (Medium)\n%s\tGemini 4 Argon (High)\ncustom-id\tCustom Display\ngpt-oss\tGPT-OSS 120B (Medium)\n' "$AGY_TEST_CODING_PIN" "$AGY_TEST_REVIEW_PIN"; exit 0;; esac
for arg in "$@"; do
  case "$arg" in
    exec|-) printf 'unexpected positional arg: %s\n' "$arg" >&2; exit 64 ;;
  esac
done
cat
STUB
chmod +x "$TMP/bin/agy"
: > "$AGY_ARGS_FILE"
TIMEOUT=0 "$DW" --runtime agy --brief "$BRIEF" --workdir /repo/x >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "agy bare-stdin invocation should succeed, got rc $rc"
grep -qFx "models" "$AGY_ARGS_FILE" || fail "agy invocation regression did not set up healthy auth first"
assert_agy_invocation_has_no_rejected_positionals
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
case "${1:-}" in models) printf '%s\tGemini 3.8 Flash (Medium)\n%s\tGemini 4 Argon (High)\n' "$AGY_TEST_CODING_PIN" "$AGY_TEST_REVIEW_PIN"; exit 0 ;; esac
cat
STUB
chmod +x "$TMP/bin/agy"
echo "test 8b (agy invocation uses bare stdin, no exec/no bare dash) PASS"

# 9. claude runtime invokes `claude -p` and threads --model.
TIMEOUT=0 "$DW" --runtime claude --model claude-haiku-4-5 --brief "$BRIEF" >/dev/null 2>&1 </dev/null
grep -q -- "-p" "$CLAUDE_ARGS_FILE"                || fail "claude not invoked with -p (got: $(cat "$CLAUDE_ARGS_FILE"))"
grep -qF -- "--model claude-haiku-4-5" "$CLAUDE_ARGS_FILE" || fail "claude --model not threaded"
echo "test 9 (claude -p + --model) PASS"

# 9b. The brief reaches claude on STDIN, not on argv. A brief on the command line is visible
# to every process on the machine via `ps` and can exceed the OS argument-length limit.
rm -f "$CLAUDE_STDIN_FILE"
# </dev/null so a regression that puts the brief back on argv fails FAST (the stub's stdin
# read gets EOF) instead of blocking the suite forever on an inherited terminal.
TIMEOUT=0 "$DW" --runtime claude --brief "$BRIEF" >/dev/null 2>&1 </dev/null
cmp -s "$BRIEF" "$CLAUDE_STDIN_FILE" || fail "claude brief not delivered byte-identically on stdin (got: $(head -c 120 "$CLAUDE_STDIN_FILE" 2>/dev/null))"
grep -qF "Review the diff." "$CLAUDE_ARGS_FILE" && fail "claude brief content is still on argv (visible in ps): $(cat "$CLAUDE_ARGS_FILE")"
echo "test 9b (claude brief on stdin, not argv) PASS"

# 10. claude --ceremony auto-approves tools (the firing branch).
TIMEOUT=0 "$DW" --runtime claude --ceremony --brief "$BRIEF" >/dev/null 2>&1 </dev/null
grep -q -- "--dangerously-skip-permissions" "$CLAUDE_ARGS_FILE" \
  || fail "claude --ceremony did not auto-approve (got: $(cat "$CLAUDE_ARGS_FILE"))"
echo "test 10 (claude --ceremony auto-approves) PASS"

# 11. claude --review is read-only (plan mode) and IGNORES --ceremony's auto-approve.
TIMEOUT=0 "$DW" --runtime claude --review --ceremony --brief "$BRIEF" >/dev/null 2>&1 </dev/null
grep -q -- "--permission-mode plan" "$CLAUDE_ARGS_FILE" \
  || fail "claude --review not read-only (plan) (got: $(cat "$CLAUDE_ARGS_FILE"))"
grep -q -- "--dangerously-skip-permissions" "$CLAUDE_ARGS_FILE" \
  && fail "claude --review wrongly auto-approved (ceremony must be ignored under review)"
echo "test 11 (claude --review read-only, ignores --ceremony) PASS"

# 12. codex now honors --model (threaded as `codex exec -m M`).
TIMEOUT=0 "$DW" --runtime codex --model gpt-5.4-mini --brief "$BRIEF" >/dev/null 2>&1
grep -qF -- "-m gpt-5.4-mini" "$CODEX_ARGS_FILE" \
  || fail "codex --model not threaded as -m (got: $(cat "$CODEX_ARGS_FILE"))"
echo "test 12 (codex --model threads -m) PASS"

# 13. codex --ceremony skips the git-repo-trust gate (a ceremony task may be outside a repo);
#     a non-ceremony codex run keeps the trust check (the negative).
TIMEOUT=0 "$DW" --runtime codex --ceremony --brief "$BRIEF" >/dev/null 2>&1
grep -q -- "--skip-git-repo-check" "$CODEX_ARGS_FILE" \
  || fail "codex --ceremony did not skip the git-trust gate (got: $(cat "$CODEX_ARGS_FILE"))"
TIMEOUT=0 "$DW" --runtime codex --brief "$BRIEF" >/dev/null 2>&1
grep -q -- "--skip-git-repo-check" "$CODEX_ARGS_FILE" \
  && fail "codex without --ceremony wrongly skipped the git-trust gate"
echo "test 13 (codex --ceremony skips git-trust; off otherwise) PASS"

# 13b-13d. rc 6 requires a limit signature AND structural evidence that codex did no work.
# The signature alone is not sufficient: codex echoes the brief and its own answer, so any
# deliverable DISCUSSING rate limits matches. Narrowing the patterns was tried and rejected --
# every phrasing is either generic enough to hit prose or specific enough to miss a real
# banner. The recorded incident was "exited 0, zero edits, only echoed the prompt": nothing
# on stdout.

# 13b. Review deliverable about HTTP 429 -- reproduced against the real binary 2026-08-27,
# which returned rc 6 while carrying a complete, correct review.
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$CODEX_ARGS_FILE"
for i in $(seq 1 80); do
  printf 'REVIEW LINE %s: treat HTTP 429 as a rate limit signal; the quota resets at midnight, so try again later with backoff.\n' "$i"
done
STUB
chmod +x "$TMP/bin/codex"
TIMEOUT=0 "$DW" --runtime codex --review --brief "$BRIEF" >"$TMP/t13b.out" 2>"$TMP/t13b.err"
rc=$?
[ "$rc" -ne 6 ] || fail "a review ABOUT rate limiting must not be misread as a usage limit (rc 6)"
[ "$rc" -eq 0 ] || fail "codex review discussing rate limits should otherwise succeed, got rc $rc"
echo "test 13b (review prose about 429 is not a limit banner) PASS"

# 13c. The generic phrasings a narrowed regex could never safely keep. Each is substantive
# output, so none may trip rc 6. Build mode: a coding brief hits the identical path.
while IFS= read -r prose; do
  cat > "$TMP/bin/codex" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$*" > "\$CODEX_ARGS_FILE"
for i in \$(seq 1 40); do printf '%s\\n' "$prose"; done
STUB
  chmod +x "$TMP/bin/codex"
  TIMEOUT=0 "$DW" --runtime codex --brief "$BRIEF" >/dev/null 2>&1
  [ "$?" -ne 6 ] || fail "substantive output must not be misread as a usage limit: $prose"
done <<'PROSE'
Ensure the script properly enforces the usage limit.
Write a test for the quota exceeded exception.
Make sure you have reached your target audience.
Too many requests should trigger a retry; please try again later.
PROSE
echo "test 13c (generic limit words in substantive output are not rc6) PASS"

# 13d. A real limit: the signature WITH no substantive stdout ("only echoed the prompt").
# Several phrasings, including ones a narrowed regex would have missed.
while IFS= read -r banner; do
  cat > "$TMP/bin/codex" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$*" > "\$CODEX_ARGS_FILE"
printf '%s\\n' "$banner" >&2
STUB
  chmod +x "$TMP/bin/codex"
  TIMEOUT=0 "$DW" --runtime codex --review --brief "$BRIEF" >/dev/null 2>&1
  [ "$?" -eq 6 ] || fail "real limit banner must return rc 6 in review mode: $banner"
  TIMEOUT=0 "$DW" --runtime codex --brief "$BRIEF" >/dev/null 2>&1
  [ "$?" -eq 6 ] || fail "real limit banner must return rc 6 in build mode: $banner"
done <<'BANNERS'
You've hit your usage limit. Try again after 3:00 PM.
Too many requests. Please try again later.
You have reached the rate limit.
Rate limiting active. Try again in 10s.
Quota exceeded for this account.
Your usage limit will reset at 14:00 UTC.
BANNERS
echo "test 13d (real limit banners with no output still return rc6) PASS"

# 13e. rc 5 (auth/config refusal) is unchanged and stays distinct from rc 6. It is gated on a
# non-zero rc, which is why it does not need the same narrowing.
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$CODEX_ARGS_FILE"
printf '%s\n' 'all models were rejected by this ChatGPT account' >&2
exit 1
STUB
chmod +x "$TMP/bin/codex"
TIMEOUT=0 "$DW" --runtime codex --brief "$BRIEF" >/dev/null 2>&1
[ "$?" -eq 5 ] || fail "codex auth refusal should still return rc 5"
echo "test 13e (auth refusal rc5 unchanged) PASS"

# 13f-13j. Exercise each capture path independently. A delayed stderr tee exposes
# an unwaited process substitution when its stdout pipe is closed before capture.
# These distinguish old from new code under bash >= 4; bash 3.2 happens to wait for
# the process substitution. CI uses bash 5 and is the authority for the race cases.
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "NOTICE: bash 3.2 may wait for process substitution; CI bash 5 decides the race cases"
fi

cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf 'You have hit your usage' >&2
sleep 0.15
printf ' limit. Try again in 2h\n' >&2
STUB
chmod +x "$TMP/bin/codex"
rm -f "$CODEX_ARGS_FILE.tee-delay"
DELAY_CODEX_STDERR_TEE=1 TIMEOUT=0 "$DW" --runtime codex --brief "$BRIEF" >"$TMP/t13f.out" 2>"$TMP/t13f.err"
rc=$?
[ -f "$CODEX_ARGS_FILE.tee-delay" ] || fail "late stderr tee delay was not exercised"
[ "$rc" -eq 6 ] || fail "late stderr usage limit should return rc 6, got $rc"
echo "test 13f (late stderr limit rc6) PASS"

cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf 'You have hit your usage limit. Try again in 2h\n'
STUB
chmod +x "$TMP/bin/codex"
TIMEOUT=0 "$DW" --runtime codex --brief "$BRIEF" >"$TMP/t13g.out" 2>"$TMP/t13g.err"
rc=$?
[ "$rc" -eq 6 ] || fail "stdout-only usage limit should return rc 6, got $rc"
echo "test 13g (stdout-only limit rc6) PASS"

cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf 'all models were ' >&2
sleep 0.15
printf 'rejected by this ChatGPT account\n' >&2
exit 1
STUB
chmod +x "$TMP/bin/codex"
rm -f "$CODEX_ARGS_FILE.tee-delay"
DELAY_CODEX_STDERR_TEE=1 TIMEOUT=0 "$DW" --runtime codex --brief "$BRIEF" >"$TMP/t13h.out" 2>"$TMP/t13h.err"
rc=$?
[ -f "$CODEX_ARGS_FILE.tee-delay" ] || fail "late stderr auth tee delay was not exercised"
[ "$rc" -eq 5 ] || fail "late stderr auth refusal should return rc 5, got $rc"
echo "test 13h (late stderr auth rc5) PASS"

cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf 'all models were rejected by this ChatGPT account\n'
exit 1
STUB
chmod +x "$TMP/bin/codex"
TIMEOUT=0 "$DW" --runtime codex --brief "$BRIEF" >"$TMP/t13i.out" 2>"$TMP/t13i.err"
rc=$?
[ "$rc" -eq 5 ] || fail "stdout-only auth refusal should return rc 5, got $rc"
echo "test 13i (stdout-only auth rc5) PASS"

cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf 'OUT-MARK\n'
for i in $(seq 1 12); do printf 'substantive output line %s\n' "$i"; done
printf 'ERR-MARK\n' >&2
exit 3
STUB
chmod +x "$TMP/bin/codex"
TIMEOUT=0 "$DW" --runtime codex --brief "$BRIEF" >"$TMP/t13j.out" 2>"$TMP/t13j.err"
rc=$?
[ "$rc" -eq 3 ] || fail "codex exit 3 should propagate as rc 3, got $rc"
grep -qFx 'OUT-MARK' "$TMP/t13j.out" || fail "codex stdout marker was lost"
grep -qFx 'ERR-MARK' "$TMP/t13j.err" || fail "codex stderr marker was lost"
grep -qFx 'ERR-MARK' "$TMP/t13j.out" && fail "codex stderr marker leaked to stdout"
grep -qFx 'OUT-MARK' "$TMP/t13j.err" && fail "codex stdout marker leaked to stderr"
echo "test 13j (stream separation and codex rc preserved) PASS"

# 13k. An echoed brief can make stderr large without providing any stdout deliverable.
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
for i in $(seq 1 40); do
  printf 'Echoed brief line %s: inspect the implementation and report the result.\n' "$i" >&2
done
printf 'You have hit your usage limit. Try again in 2h\n' >&2
STUB
chmod +x "$TMP/bin/codex"
TIMEOUT=0 "$DW" --runtime codex --brief "$BRIEF" >"$TMP/t13k.out" 2>"$TMP/t13k.err"
rc=$?
[ "$rc" -eq 6 ] || fail "echoed brief on stderr with a limit should return rc 6, got $rc"
[ ! -s "$TMP/t13k.out" ] || fail "stderr-only echoed brief leaked to stdout"
echo "test 13k (stderr echoed brief with usage limit rc6) PASS"

# 13l. Auth phrases quoted in a substantial successful answer are not an auth refusal.
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
for i in $(seq 1 12); do
  printf 'Answer line %s: with a ChatGPT account, all models were rejected in the example; explain the recovery steps.\n' "$i"
done
STUB
chmod +x "$TMP/bin/codex"
TIMEOUT=0 "$DW" --runtime codex --brief "$BRIEF" >"$TMP/t13l.out" 2>"$TMP/t13l.err"
rc=$?
[ "$rc" -eq 0 ] || fail "successful answer quoting auth phrases should return rc 0, got $rc"
echo "test 13l (auth phrases in successful answer rc0) PASS"

# 13m. The external bound must propagate through the waited codex pipelines.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
sleep 5
STUB
  chmod +x "$TMP/bin/codex"
  TIMEOUT=1 KILL_AFTER=1 "$DW" --runtime codex --brief "$BRIEF" >"$TMP/t13m.out" 2>"$TMP/t13m.err"
  rc=$?
  [ "$rc" -eq 124 ] || fail "codex external timeout should return rc 124, got $rc"
  grep -qF 'exceeded the external 1 bound and was killed' "$TMP/t13m.err" \
    || fail "codex external timeout bound message was missing"
  echo "test 13m (codex external timeout rc124) PASS"
elif [ "${CI:-}" = true ]; then
  fail "CI requires timeout or gtimeout for the codex external timeout case"
else
  echo "SKIP test 13m (timeout and gtimeout unavailable)"
fi

cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$CODEX_ARGS_FILE"
cat >/dev/null
STUB
chmod +x "$TMP/bin/codex"

# 14. agy --review rc 0 with empty/short output fails closed as rc 8.
R14="$TMP/repo14"; make_git_repo "$R14"
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
printf 'ok'
STUB
chmod +x "$TMP/bin/agy"
TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R14" >"$TMP/t14.out" 2>"$TMP/t14.err"
rc=$?
[ "$rc" -eq 8 ] || fail "short review should return rc 8, got $rc"
grep -q "REVIEW FAILED" "$TMP/t14.err" || fail "short review rc 8 did not print REVIEW FAILED"
echo "test 14 (agy short review returns rc 8) PASS"

# 15. agy --review substantive output remains rc 0 and preserves REVIEW_OUTFILE content.
# The stub remains substantive and carries an explicit severity marker.
R15="$TMP/repo15"; make_git_repo "$R15"
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
for i in $(seq 1 60); do printf 'Minor: REVIEW LINE %s: no issues found in this pass.\n' "$i"; done
STUB
chmod +x "$TMP/bin/agy"
# A caller that wants the review file KEPT supplies REVIEW_OUTFILE itself; an unsupplied
# (mktemp'd) file is a temp of ours and is deleted on exit (see test 15c).
REVIEW_OUTFILE="$TMP/t15.review.md" TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R15" >"$TMP/t15.out" 2>"$TMP/t15.err"
rc=$?
[ "$rc" -eq 0 ] || fail "substantive review should return rc 0, got $rc"
review_file="$(sed -n 's/^REVIEW_OUTFILE=\([^ ]*\).*/\1/p' "$TMP/t15.err" | tail -n 1)"
[ -n "$review_file" ] || fail "substantive review did not emit REVIEW_OUTFILE"
[ "$review_file" = "$TMP/t15.review.md" ] || fail "emitted REVIEW_OUTFILE path is not the caller-supplied one: $review_file"
[ -f "$review_file" ] || fail "a caller-supplied REVIEW_OUTFILE must be RETAINED after dispatch-worker exits"
review_bytes="$(wc -c < "$review_file" | tr -d ' ')"
[ "$review_bytes" -ge 1200 ] || fail "substantive REVIEW_OUTFILE too short: $review_bytes"
echo "test 15 (agy substantive review passes) PASS"

# 15c. With NO caller-supplied REVIEW_OUTFILE, dispatch-worker mktemps the file and MUST
# delete it on exit — the review on STDOUT is the deliverable, and the comment in
# dispatch-worker promised that cleanup while nothing performed it. A stale
# $TMPDIR/dispatch-review.*.md per review is a leak of the reviewed code's content.
R15C="$TMP/repo15c"; make_git_repo "$R15C"
TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R15C" >"$TMP/t15c.out" 2>"$TMP/t15c.err"
rc=$?
[ "$rc" -eq 0 ] || fail "15c substantive review should return rc 0, got $rc"
tmp_review="$(sed -n 's/^REVIEW_OUTFILE=\([^ ]*\).*/\1/p' "$TMP/t15c.err" | tail -n 1)"
[ -n "$tmp_review" ] || fail "15c did not emit REVIEW_OUTFILE"
case "$tmp_review" in *dispatch-review.*) ;; *) fail "15c expected an mktemp'd dispatch-review path, got $tmp_review";; esac
[ ! -e "$tmp_review" ] || fail "15c dispatch-worker left its own temp review file behind: $tmp_review"
grep -q "REVIEW LINE 1:" "$TMP/t15c.out" || fail "15c the review must still be on STDOUT (that is the deliverable)"
echo "test 15c (unsupplied REVIEW_OUTFILE temp is deleted; review stays on stdout) PASS"

# 15b. A short sign-off-shaped output ("I have completed the review...", ~40B)
# with no override must fail closed as rc 8, not pass silently as the original
# 392B agy sign-off did (measured).
R15B="$TMP/repo15b"; make_git_repo "$R15B"
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
printf 'I have completed the review. No issues found.'
STUB
chmod +x "$TMP/bin/agy"
TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R15B" >"$TMP/t15b.out" 2>"$TMP/t15b.err"
rc=$?
[ "$rc" -eq 8 ] || fail "sign-off-shaped output under the default byte backstop should return rc 8, got $rc"
grep -q "REVIEW FAILED" "$TMP/t15b.err" || fail "sign-off-shaped short review rc 8 did not print REVIEW FAILED"
echo "test 15b (default byte backstop rejects a sign-off-only review) PASS"

# 16. DISPATCH_MIN_REVIEW_BYTES lowers the byte floor.
R16="$TMP/repo16"; make_git_repo "$R16"
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
printf 'short'
STUB
chmod +x "$TMP/bin/agy"
DISPATCH_MIN_REVIEW_BYTES=1 DISPATCH_REVIEW_REQUIRE_EVIDENCE=0 TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R16" >"$TMP/t16.out" 2>"$TMP/t16.err"
rc=$?
[ "$rc" -eq 0 ] || fail "configurable review byte floor should allow tiny output, got rc $rc"
echo "test 16 (agy min review bytes is configurable) PASS"

# 17. Hermetic review: a mutating reviewer cannot dirty or move the real repo.
R17="$TMP/repo17"; make_git_repo "$R17"
pre_head="$(git -C "$R17" rev-parse HEAD)"
pre_branch="$(git -C "$R17" branch --show-current)"
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
printf '%s\n' "$*" >> "$AGY_ARGS_FILE"
cat > "$AGY_STDIN_FILE"
touch scratch_evil.py
git checkout --detach >/dev/null 2>&1 || true
git init . >/dev/null 2>&1
for i in $(seq 1 100); do printf 'Minor: REVIEW LINE %s ok no issues\n' "$i"; done
STUB
chmod +x "$TMP/bin/agy"
: > "$AGY_ARGS_FILE"
(
  cd "$TMP" || exit 1
  TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R17" >"$TMP/t17.out" 2>"$TMP/t17.err"
)
rc=$?
[ "$rc" -eq 0 ] || fail "hermetic mutating review should still return rc 0, got $rc"
[ -z "$(git -C "$R17" status --porcelain)" ] || fail "mutating reviewer dirtied real repo: $(git -C "$R17" status --porcelain)"
[ "$(git -C "$R17" rev-parse HEAD)" = "$pre_head" ] || fail "mutating reviewer moved real repo HEAD"
[ "$(git -C "$R17" branch --show-current)" = "$pre_branch" ] || fail "mutating reviewer changed real repo branch"
[ ! -e "$R17/scratch_evil.py" ] || fail "mutating reviewer wrote scratch file into real repo"
[ ! -e "$TMP/scratch_evil.py" ] || fail "auth probe or runner cwd was mutated by agy stub"
[ ! -e "$TMP/.git" ] || fail "auth probe or runner cwd got git-initialized by agy stub"
grep -qF -- "--dangerously-skip-permissions" <<<"$(agy_exec_args)" || fail "hermetic agy review did not bypass command permissions"
grep -qF 'DISPOSABLE local clone at' "$AGY_STDIN_FILE" || fail "hermetic review preamble did not identify the disposable local clone"
grep -qF "Origin's fetch and push URLs point at a disabled path; other remotes and the operator's credential helper remain reachable, so do not fetch or push." "$AGY_STDIN_FILE" || fail "hermetic review preamble missing remote warning"
grep -qF "detached at $pre_head" "$AGY_STDIN_FILE" || fail "hermetic review preamble did not identify the disposable local clone"
grep -qF "Translate every $(git -C "$R17" rev-parse --show-toplevel)" "$AGY_STDIN_FILE" || fail "hermetic review preamble did not map brief paths"
# shellcheck disable=SC2016 # Match the literal scratch command, without expansion.
grep -qF 'tmp=$(mktemp -d "${TMPDIR:-/tmp}/<name>.XXXXXX")' "$AGY_STDIN_FILE" || fail "hermetic review preamble missing literal scratch allocation"
# shellcheck disable=SC2016 # Match the literal scratch path variable.
grep -qF -- '-C "$tmp"' "$AGY_STDIN_FILE" || fail "hermetic review preamble missing literal scratch git path"
grep -qF 'the real repository is untouched' "$AGY_STDIN_FILE" && fail "hermetic review preamble still promises the real repository is untouched"
grep -qF 'DISPOSABLE, DETACHED git worktree' "$AGY_STDIN_FILE" && fail "hermetic review preamble still describes a linked worktree"
grep -q "MUTATING code to prove something" "$AGY_STDIN_FILE" || fail "hermetic review preamble did not permit mutation checks"
# foundry#259: the permission comes with the contract — expected failure text
# plus a knock-out (control recommended), and UNPROVEN (never CAUGHT) as the fallback.
grep -q "mutation-verify.sh with BOTH --expect-fail-output" "$AGY_STDIN_FILE" || fail "hermetic review preamble does not require --expect-fail-output for mutation checks"
grep -q "AND --knockout-cmd (the same test command with only the hazard test deselected) plus its required scope proof" "$AGY_STDIN_FILE" || fail "hermetic review preamble does not require a knock-out with its scope proof"
grep -q "with --knockout-delta-line '=== RUN '" "$AGY_STDIN_FILE" || fail "hermetic review preamble does not give the go delta line"
grep -q "The knock-out is supported only for cargo, go and pytest" "$AGY_STDIN_FILE" || fail "hermetic review preamble does not limit the knock-out to supported runners"
grep -q "For any other runner (node included), report the mutant as UNPROVEN" "$AGY_STDIN_FILE" || fail "hermetic review preamble does not make other runners UNPROVEN"
grep -q "+ -- --exact --skip <path::name> with --knockout-expect-output '1 filtered out'" "$AGY_STDIN_FILE" || fail "hermetic review preamble does not give the exact cargo form"
grep -q "a control refusal stands; report every control you tried, including refused ones" "$AGY_STDIN_FILE" || fail "hermetic review preamble does not say a control refusal stands and must be reported"
grep -qF 'requires a control, which runs first as a canary' "$AGY_STDIN_FILE" || fail "hermetic review preamble lacks copy-mode canary rule"
grep -qF 'INCONCLUSIVE until a serial in-place run confirms it' "$AGY_STDIN_FILE" || fail "hermetic review preamble lacks copy-mode confirmation rule"
grep -q "A control mutant (--control-sed or --control-cmd with --control-expect-fail-output) is recommended, not required" "$AGY_STDIN_FILE" || fail "hermetic review preamble does not mark the control as recommended"
grep -q "a CAUGHT whose knock-out clause says it did not run, or whose deselect is not one of these exact forms, is UNPROVEN" "$AGY_STDIN_FILE" || fail "hermetic review preamble does not bind the knock-out clause to CAUGHT"
grep -q "the runner cannot deselect the single hazard test" "$AGY_STDIN_FILE" || fail "hermetic review preamble does not state the no-deselect fallback"
grep -q "report that mutant as UNPROVEN, never CAUGHT" "$AGY_STDIN_FILE" || fail "hermetic review preamble does not state the UNPROVEN fallback"
# Intent: the hermetic preamble must NAME the isolated worktree. It must NOT do so with the
# blanket "(do not change)" / "DO NOT write any files" phrasing, which contradicts the
# may-mutate permission granted just above it — a reviewer resolving that conflict toward the
# prohibition silently skips its mutation check, the defect this whole change removes.
grep -F "is the disposable clone: " "$AGY_STDIN_FILE" | grep -q "dispatch-review-wt\." || fail "hermetic review preamble did not contain the isolated worktree path"
grep -q "Repo to read (do not change)" "$AGY_STDIN_FILE" && fail "hermetic review preamble still carries the contradictory read-only phrasing"
grep -q "DO NOT write any files to disk" "$AGY_STDIN_FILE" && fail "hermetic review preamble still forbids all disk writes, contradicting the mutation-check permission"
grep -q "If a tool, command, or capability your method requires is unavailable or denied" "$AGY_STDIN_FILE" || fail "hermetic review preamble missing degradation clause"
echo "test 17 (agy review runs hermetically) PASS"

# 18. Unsuitable private-clone targets warn and still return read-only output.
R18="$TMP/non-hermetic-review"; make_git_repo "$R18"
git -C "$R18" config filter.fixture.clean cat
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
printf '%s\n' "$*" >> "$AGY_ARGS_FILE"
cat > "$AGY_STDIN_FILE"
for i in $(seq 1 60); do printf 'Minor: REVIEW LINE %s: non-git target reviewed.\n' "$i"; done
STUB
chmod +x "$TMP/bin/agy"
: > "$AGY_ARGS_FILE"
TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R18" >"$TMP/t18.out" 2>"$TMP/t18.err"
rc=$?
[ "$rc" -eq 0 ] || fail "non-git review should return rc 0, got $rc"
grep -q "unsuitable for a private clone" "$TMP/t18.err" || fail "non-git review did not print non-hermetic warning"
grep -q "non-hermetically and therefore read-only" "$TMP/t18.err" || fail "non-git review did not print the execution-method read-only warning"
grep -qF -- "--dangerously-skip-permissions" <<<"$(agy_exec_args)" && fail "non-hermetic agy review bypassed command permissions"
grep -q "Do NOT edit, create, or delete any files" "$AGY_STDIN_FILE" || fail "non-hermetic review preamble lost the original prohibition"
grep -q "If a tool, command, or capability your method requires is unavailable or denied" "$AGY_STDIN_FILE" || fail "non-hermetic review preamble missing degradation clause"
[ "$(wc -c < "$TMP/t18.out" | tr -d ' ')" -ge 1200 ] || fail "non-git review did not return substantive output"
echo "test 18 (agy non-git review warns and returns output) PASS"

# 19. Missing agy auth still returns rc 7, distinct from short-review rc 8.
R19="$TMP/repo19"; make_git_repo "$R19"
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
case "$*" in *models*) printf '%s\n' 'Error: Please sign in to view available models. Launch the CLI without arguments to sign in.' >&2; exit 1;; esac
printf 'ok'
STUB
chmod +x "$TMP/bin/agy"
: > "$AGY_ARGS_FILE"   # reset so the assertion below cannot match an earlier test's argv
TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R19" >"$TMP/t19.out" 2>"$TMP/t19.err"
rc=$?
[ "$rc" -eq 7 ] || fail "missing agy auth should return rc 7, got $rc"
# Assert the verdict came from the LIVE probe, not a filesystem pre-check. Without this,
# the test passes for the wrong reason under the old creds-file short-circuit.
grep -qF -- "models" "$AGY_ARGS_FILE" || fail "rc7 must come from the live 'agy models' probe (argv: $(cat "$AGY_ARGS_FILE"))"
echo "test 19 (agy auth rc 7 comes from the live probe) PASS"

# 20. A dirty real tree warns that uncommitted changes are NOT in the hermetic (HEAD-only) review.
R20="$TMP/repo20"; make_git_repo "$R20"
printf 'uncommitted draft line\n' >> "$R20/README.md"   # dirty the real tree
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
for i in $(seq 1 60); do printf 'Minor: REVIEW LINE %s: reviewed committed HEAD.\n' "$i"; done
STUB
chmod +x "$TMP/bin/agy"
TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R20" >"$TMP/t20.out" 2>"$TMP/t20.err"
rc=$?
[ "$rc" -eq 0 ] || fail "dirty-tree review should still return rc 0, got $rc"
grep -q "uncommitted changes that are NOT included" "$TMP/t20.err" \
  || fail "dirty-tree review did not warn that uncommitted changes were excluded"
echo "test 20 (dirty real tree warns uncommitted excluded) PASS"

# 21. agy --review timeout (rc=124) with an empty/short outfile retries the SAME
# call ONCE before falling back — and if the retry ALSO times out empty/short, the
# fallback hint is printed and dispatch-worker fails closed as rc 8 (the same
# "fall back to a LOCAL reviewer" contract as the rc=0 byte-floor case).
# (residual defect: the byte-floor/retry block was gated on
# `[ "$agy_rc" -eq 0 ]`, so a TIMEOUT fell straight through with no retry.)
R21="$TMP/repo21"; make_git_repo "$R21"
export AGY_COUNT_FILE="$TMP/agy-count-21"
: > "$AGY_COUNT_FILE"
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
n=$(( $(cat "$AGY_COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$AGY_COUNT_FILE"
printf 'x'
exit 124
STUB
chmod +x "$TMP/bin/agy"
TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R21" >"$TMP/t21.out" 2>"$TMP/t21.err"
rc=$?
[ "$rc" -eq 124 ] || fail "timeout-exhausted-after-retry should return rc 124, got $rc"
[ "$(cat "$AGY_COUNT_FILE")" -eq 2 ] || fail "expected exactly ONE retry (2 agy invocations total), got $(cat "$AGY_COUNT_FILE")"
grep -q "retrying ONCE" "$TMP/t21.err" || fail "timeout retry did not announce the retry"
grep -q "Re-run an agy lens once on codex if codex egress is approved, else use a Claude reviewer" "$TMP/t21.err" || fail "timeout-exhausted-after-retry did not print the fallback hint"
echo "test 21 (agy review timeout retries once then falls back with hint) PASS"

# 22. Non-regression: an rc=0 short/empty outfile (a real completed short review,
# not a hang) still fails closed as rc=8 WITHOUT retrying — retry is scoped to
# 124/137 only.
R22="$TMP/repo22"; make_git_repo "$R22"
export AGY_COUNT_FILE="$TMP/agy-count-22"
: > "$AGY_COUNT_FILE"
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
n=$(( $(cat "$AGY_COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$AGY_COUNT_FILE"
printf 'ok'
STUB
chmod +x "$TMP/bin/agy"
TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R22" >"$TMP/t22.out" 2>"$TMP/t22.err"
rc=$?
[ "$rc" -eq 8 ] || fail "rc=0 short-output non-regression: expected rc 8, got $rc"
[ "$(cat "$AGY_COUNT_FILE")" -eq 1 ] || fail "rc=0 short output should NOT retry (expected 1 agy invocation), got $(cat "$AGY_COUNT_FILE")"
grep -q "REVIEW FAILED" "$TMP/t22.err" || fail "rc=0 short-output non-regression did not print REVIEW FAILED"
echo "test 22 (rc=0 short-output non-regression: no retry) PASS"
unset AGY_COUNT_FILE

# 23. agy --review retry HAPPY path (peer-review follow-up):
# test 21 only proves that when the retry ALSO times out, dispatch-worker falls
# back to rc 8. Nothing previously proved that when the retry SUCCEEDS, the
# review is actually ACCEPTED — if the retry scrambled the output, lost the
# return code, or failed to recompute review_bytes, no test would notice. The
# stub exits 124 with a tiny partial on its FIRST call and 0 with a long, valid
# review on its SECOND call; we assert dispatch-worker exits 0 and that the
# REVIEW_OUTFILE actually contains the retry's content (not the first attempt's).
R23="$TMP/repo23"; make_git_repo "$R23"
export AGY_COUNT_FILE="$TMP/agy-count-23"
: > "$AGY_COUNT_FILE"
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
n=$(( $(cat "$AGY_COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$AGY_COUNT_FILE"
if [ "$n" -eq 1 ]; then
  printf 'x'
  exit 124
fi
for i in $(seq 1 60); do printf 'Minor: REVIEW LINE %s: retry succeeded, no issues found.\n' "$i"; done
exit 0
STUB
chmod +x "$TMP/bin/agy"
REVIEW_OUTFILE="$TMP/t23.review.md" TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R23" >"$TMP/t23.out" 2>"$TMP/t23.err"
rc=$?
[ "$rc" -eq 0 ] || fail "retry-succeeds should return rc 0, got $rc"
[ "$(cat "$AGY_COUNT_FILE")" -eq 2 ] || fail "expected exactly TWO agy invocations (initial + retry), got $(cat "$AGY_COUNT_FILE")"
review_file="$(sed -n 's/^REVIEW_OUTFILE=\([^ ]*\).*/\1/p' "$TMP/t23.err" | tail -n 1)"
[ -n "$review_file" ] || fail "retry-succeeds did not emit REVIEW_OUTFILE"
grep -q "retry succeeded, no issues found" "$review_file" || fail "retry-succeeds REVIEW_OUTFILE did not contain the retry's actual output"
review_bytes="$(wc -c < "$review_file" | tr -d ' ')"
[ "$review_bytes" -ge 1200 ] || fail "retry-succeeds REVIEW_OUTFILE too short: $review_bytes"
echo "test 23 (agy review retry succeeds and accepts retry output) PASS"
unset AGY_COUNT_FILE

# 24. FINDING 1 (interface-lens review follow-up): BOTH timeout branches used to
# be gated on `review_bytes < MIN_REVIEW_BYTES`. A LONG partial review (>= the
# floor) that then times out matched NEITHER branch — no retry, no fallback —
# instead of retrying before returning BLOCKED rc=124
# ("fall back to a LOCAL reviewer"). Byte count says nothing about whether a
# timed-out review is COMPLETE. The stub always exits 124 but always prints a
# long (>=2000B) partial, on every call, so this isolates the byte-gating bug
# specifically (as opposed to test 21, whose stub prints a short partial).
R24="$TMP/repo24"; make_git_repo "$R24"
export AGY_COUNT_FILE="$TMP/agy-count-24"
: > "$AGY_COUNT_FILE"
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
n=$(( $(cat "$AGY_COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$AGY_COUNT_FILE"
for i in $(seq 1 60); do printf 'REVIEW LINE %s: long partial before the hang.\n' "$i"; done
exit 124
STUB
chmod +x "$TMP/bin/agy"
TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R24" >"$TMP/t24.out" 2>"$TMP/t24.err"
rc=$?
[ "$rc" -eq 124 ] || fail "long-partial timeout should return BLOCKED rc 124, got $rc"
[ "$(cat "$AGY_COUNT_FILE")" -eq 2 ] || fail "long-partial timeout should still retry exactly once (2 invocations), got $(cat "$AGY_COUNT_FILE")"
grep -q "retrying ONCE" "$TMP/t24.err" || fail "long-partial timeout did not retry (byte count wrongly gated the retry)"
grep -q "a primary codex lens at rc 124 goes to Claude" "$TMP/t24.err" || fail "long-partial timeout did not print the fallback hint"
echo "test 24 (long-partial timeout still retries+falls back to rc 124) PASS"
unset AGY_COUNT_FILE

# 25-28: a brief that NAMES an uncommitted/untracked path in a
# dirty real tree must REFUSE (exit 2, path listed, no worker launched) instead of
# only warning — a stderr warning alone has demonstrably failed twice to stop a long
# review running against a tree missing the file it was briefed to review.

# 25. brief names docs/plan.md while it is UNTRACKED -> exit 2, path listed, no
# worker launched (only the auth probe's "models" call should have reached agy).
R25="$TMP/repo25"; make_git_repo "$R25"
mkdir -p "$R25/docs"; printf 'plan content\n' > "$R25/docs/plan.md"   # untracked
BRIEF25="$TMP/brief25.md"
printf 'PERSONA: peer-code-reviewer\nReview docs/plan.md for correctness.\n' > "$BRIEF25"
restore_default_agy_stub
: > "$AGY_ARGS_FILE"
TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF25" --workdir "$R25" >"$TMP/t25.out" 2>"$TMP/t25.err"
rc=$?
[ "$rc" -eq 2 ] || fail "brief naming an untracked path should refuse with rc 2, got $rc"
grep -q "brief names uncommitted files" "$TMP/t25.err" || fail "rc2 refusal did not print the expected message"
grep -q "docs/plan.md" "$TMP/t25.err" || fail "rc2 refusal did not list the offending path"
[ "$(wc -l < "$AGY_ARGS_FILE" | tr -d ' ')" -eq 1 ] || fail "worker should NOT have been launched (expected only the auth probe, got: $(cat "$AGY_ARGS_FILE"))"
[ "$(git -C "$R25" worktree list | wc -l | tr -d ' ')" -eq 1 ] || fail "no review worktree should have been created"
echo "test 25 (brief names untracked path -> refuse rc 2, no launch) PASS"

# 26. Same, but the named path is MODIFIED-TRACKED (not untracked).
R26="$TMP/repo26"; make_git_repo "$R26"
mkdir -p "$R26/docs"; printf 'plan content\n' > "$R26/docs/plan.md"
git -C "$R26" add docs/plan.md >/dev/null 2>&1
git -C "$R26" -c user.email=test@example.com -c user.name='Test User' commit -m add-plan >/dev/null 2>&1
printf 'more\n' >> "$R26/docs/plan.md"   # dirty a TRACKED file
: > "$AGY_ARGS_FILE"
TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF25" --workdir "$R26" >"$TMP/t26.out" 2>"$TMP/t26.err"
rc=$?
[ "$rc" -eq 2 ] || fail "brief naming a modified-tracked path should refuse with rc 2, got $rc"
grep -q "docs/plan.md" "$TMP/t26.err" || fail "rc2 refusal (modified-tracked) did not list the offending path"
[ "$(wc -l < "$AGY_ARGS_FILE" | tr -d ' ')" -eq 1 ] || fail "worker should NOT have been launched for a modified-tracked named path"
echo "test 26 (brief names modified-tracked path -> refuse rc 2, no launch) PASS"

# Substantive, severity-shaped output is orthogonal to what tests 27/27b/28 check.
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
for i in $(seq 1 60); do printf 'Minor: REVIEW LINE %s: reviewed despite the dirty tree.\n' "$i"; done
STUB
chmod +x "$TMP/bin/agy"

# 27. Same as 26, but --allow-dirty keeps today's warn-and-proceed behavior.
: > "$AGY_ARGS_FILE"
TIMEOUT=0 "$DW" --runtime agy --review --allow-dirty --brief "$BRIEF25" --workdir "$R26" >"$TMP/t27.out" 2>"$TMP/t27.err"
rc=$?
[ "$rc" -eq 0 ] || fail "--allow-dirty should proceed (rc 0) despite the named dirty path, got $rc"
grep -q "uncommitted changes that are NOT included" "$TMP/t27.err" || fail "--allow-dirty run should still print the existing warning"
grep -q "brief names uncommitted files" "$TMP/t27.err" && fail "--allow-dirty should not also print the refusal message"
echo "test 27 (--allow-dirty keeps warn-and-proceed) PASS"

# 27b. DISPATCH_ALLOW_DIRTY=1 env var does the same as --allow-dirty.
: > "$AGY_ARGS_FILE"
DISPATCH_ALLOW_DIRTY=1 TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF25" --workdir "$R26" >"$TMP/t27b.out" 2>"$TMP/t27b.err"
rc=$?
[ "$rc" -eq 0 ] || fail "DISPATCH_ALLOW_DIRTY=1 should proceed (rc 0) despite the named dirty path, got $rc"
grep -q "uncommitted changes that are NOT included" "$TMP/t27b.err" || fail "DISPATCH_ALLOW_DIRTY=1 run should still print the existing warning"
echo "test 27b (DISPATCH_ALLOW_DIRTY=1 keeps warn-and-proceed) PASS"

# 28. A dirty file NOT named in the brief still only WARNS and proceeds (no new
# false refusal) -- this is test 20's scenario restated with the new refusal path
# active, to prove it doesn't over-trigger.
R28="$TMP/repo28"; make_git_repo "$R28"
printf 'uncommitted draft line\n' >> "$R28/README.md"   # dirty a file the brief never mentions
: > "$AGY_ARGS_FILE"
TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R28" >"$TMP/t28.out" 2>"$TMP/t28.err"
rc=$?
[ "$rc" -eq 0 ] || fail "dirty file not named in brief should still return rc 0, got $rc"
grep -q "uncommitted changes that are NOT included" "$TMP/t28.err" || fail "dirty-not-named should still warn"
grep -q "brief names uncommitted files" "$TMP/t28.err" && fail "dirty-not-named should NOT trigger the refusal message"
echo "test 28 (dirty file not named in brief: warn + proceed, no false refusal) PASS"

# 31b. The byte backstop is independently load-bearing: severity evidence cannot
# rescue an output below 1200B, and the distinct byte-specific diagnostic fires.
R31B="$TMP/repo31b"; make_git_repo "$R31B"
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
printf 'Major: concrete but deliberately short finding.'
STUB
chmod +x "$TMP/bin/agy"
TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R31B" >"$TMP/t31b.out" 2>"$TMP/t31b.err"
rc=$?
[ "$rc" -eq 8 ] || fail "short severity-bearing review should return rc 8, got $rc"
grep -q "output too short" "$TMP/t31b.err" || fail "short severity-bearing review did not hit byte-specific branch"
echo "test 31b (byte backstop rejects short evidence-bearing review) PASS"

# 31c-d. Each file:line alternative is sufficient by itself (no severity token).
for evidence_case in pathslash pathext; do
  R31P="$TMP/repo31-$evidence_case"; make_git_repo "$R31P"
  if [ "$evidence_case" = pathslash ]; then evidence='agent-dispatch/bin/dispatch-worker:585'; else evidence='dispatch-worker.sh:585'; fi
  export EVIDENCE_FIXTURE="$evidence"
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
printf '%s\n' "$EVIDENCE_FIXTURE"
for i in $(seq 1 30); do printf 'Concrete review analysis item %s explains behavior and verification. ' "$i"; done
STUB
  chmod +x "$TMP/bin/agy"
  TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R31P" >"$TMP/t31-$evidence_case.out" 2>"$TMP/t31-$evidence_case.err"
  rc=$?
  [ "$rc" -eq 0 ] || fail "$evidence_case-only review should pass, got rc $rc"
done
while IFS="$(printf '\t')" read -r want evidence; do
  export EVIDENCE_FIXTURE="$evidence"
  # Reuse the file:line stub, placing the fixture at line start.
  TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$R31P" >"$TMP/parity.out" 2>"$TMP/parity.err"
  rc=$?
  [ "$rc" -eq "$want" ] || fail "evidence parity '$evidence': rc $rc, want $want"
done < "$SELF_DIR/../test/review-evidence.tsv"
unset EVIDENCE_FIXTURE
echo "test 31c-d (both file:line evidence alternatives pass independently) PASS"

restore_default_agy_stub
assert_no_review_residue
if [ "$FAILS" -ne 0 ]; then
  echo "$FAILS TEST(S) FAILED"
  exit 1
fi
echo "ALL PASS"
