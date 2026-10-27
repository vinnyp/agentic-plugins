#!/usr/bin/env bash
set -uo pipefail
# Shared isolated environment and runtime fixtures for dispatch-worker suites.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/lib/test-env-reset.sh"
reset_dispatch_env  # neutralize any operator-exported dispatch vars before the suite runs
# shellcheck disable=SC1091
. "$SELF_DIR/lib/agy-models.sh"
export AGY_TEST_CODING_PIN="$AGY_MODEL_CODING_DEFAULT" AGY_TEST_REVIEW_PIN="$AGY_MODEL_REVIEW_DEFAULT"
DW="$SELF_DIR/dispatch-worker"
TMP="$(set -eu; scratch=$(mktemp -d "${TMPDIR:-/tmp}/dispatch-worker-test.XXXXXX"); [ -n "$scratch" ]; printf '%s\n' "$scratch")" || exit 1
TMP="$(cd "$TMP" && pwd -P)" || exit 1
cd "$TMP" || exit 1
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
: > "$GIT_CONFIG_GLOBAL"
# Keep the platform-temp namespace distinct from test repos so the review
# location regression can prove the worktree is not created beneath $TMPDIR.
export TMPDIR="$TMP/platform-tmp"
mkdir -p "$TMPDIR"

# Stub runtimes on PATH. agy: cat stdin (the brief) straight through so $() can read
# it. codex: record its argv to a file and swallow the brief.
REAL_TEE="$(command -v tee)"
export REAL_TEE
mkdir -p "$TMP/bin"
cat > "$TMP/bin/tee" <<'STUB'
#!/usr/bin/env bash
# Hold the stderr tee before its first read to expose an unwaited capture.
if [ "${DELAY_CODEX_STDERR_TEE:-0}" = 1 ]; then
  case "${2:-}" in
    *dispatch-codex-out.*)
      printf 'delayed\n' > "$CODEX_ARGS_FILE.tee-delay"
      sleep 0.5
      ;;
  esac
fi
exec "$REAL_TEE" "$@"
STUB
cat > "$TMP/bin/agy" <<'STUB'
#!/usr/bin/env bash
# PERSONA_ROSTER_STUB
case "${1:-}" in
  models)
    printf '%s\n' "$*" >> "$AGY_ARGS_FILE"
    if [ "${AGY_MISSING_REVIEW:-0}" = 1 ]; then
      printf 'custom-id\tCustom Display\ngpt-oss\tGPT-OSS 120B (Medium)\n'
    else
      printf '%s\tGemini 3.8 Flash (Medium)\n%s\tGemini 4 Argon (High)\ncustom-id\tCustom Display\ngpt-oss\tGPT-OSS 120B (Medium)\n' "$AGY_TEST_CODING_PIN" "$AGY_TEST_REVIEW_PIN"
    fi
    exit 0 ;;
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
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$CODEX_ARGS_FILE"
cat >/dev/null
STUB
# claude: native one-shot (`claude -p ...` with the prompt on STDIN) — record argv AND stdin.
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$CLAUDE_ARGS_FILE"
cat > "$CLAUDE_STDIN_FILE"
STUB
chmod +x "$TMP/bin/agy" "$TMP/bin/codex" "$TMP/bin/claude" "$TMP/bin/tee"
export PATH="$TMP/bin:$PATH"
export CODEX_ARGS_FILE="$TMP/codex-args"
export AGY_ARGS_FILE="$TMP/agy-args"
export AGY_STDIN_FILE="$TMP/agy-stdin"
export CLAUDE_ARGS_FILE="$TMP/claude-args"
export CLAUDE_STDIN_FILE="$TMP/claude-stdin"

BRIEF="$TMP/brief.md"
printf 'PERSONA: peer-code-reviewer\nReview the diff.\n' > "$BRIEF"

FAILS=0
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

assert_no_review_residue() {
  local residue
  [ ! -d "$TMP/.worktrees" ] || fail 'empty default .worktrees parent was left behind'
  residue=$(find "$TMPDIR" \( -name 'dispatch-review-wt.*' -o -name 'dispatch-review-state.*' \
    -o -name 'dispatch-snapshots.*' -o -name 'dispatch-review.*.md' \) -print) || fail 'review residue scan failed'
  [ -z "$residue" ] || fail "review residue leaked: $residue"
}

# Match the global config and source refs inherited after the original test 44.
make_config_fixture() {
  local origin="$TMP/origin43" r44="$1"
  [ -d "$origin" ] || git -C "$TMP" init --bare "$origin" >/dev/null 2>&1
  make_git_repo "$r44"
  git -C "$r44" branch feature
  git -C "$r44" remote add origin "$origin"
  cat > "$TMP/included.gitconfig" <<'CONFIG'
[core]
 editor = ed
CONFIG
  cat > "$GIT_CONFIG_GLOBAL" <<CONFIG
[user]
 name = Review Test
 email = review@example.invalid
[include]
 path = $TMP/included.gitconfig
[x]
 flag
CONFIG
}

agy_exec_args() {
  grep -vFx 'models' "$AGY_ARGS_FILE" || true
}

assert_agy_invocation_has_no_rejected_positionals() {
  if grep -Eq '(^| )exec( |$)|(^| )-( |$)' "$AGY_ARGS_FILE"; then
    fail "agy invocation used rejected positional args (got: $(cat "$AGY_ARGS_FILE"))"
  fi
}

make_git_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init >/dev/null 2>&1
  git -C "$repo" checkout -b review-main >/dev/null 2>&1
  printf 'initial\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c user.email=test@example.com -c user.name='Test User' commit -m initial >/dev/null 2>&1
}

restore_default_agy_stub() {
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
}

# Configurable review runtime: probes never count as launches.
install_cfg_agy_stub() {
  cat > "$TMP/bin/agy" <<'STUB'
#!/usr/bin/env bash
# PERSONA_ROSTER_STUB
case "${1:-}" in
  models)
    printf '%s\n' "$*" >> "$AGY_ARGS_FILE"
    if [ "${AGY_MISSING_REVIEW:-0}" = 1 ]; then
      printf 'custom-id\tCustom Display\ngpt-oss\tGPT-OSS 120B (Medium)\n'
    else
      printf '%s\tGemini 3.8 Flash (Medium)\n%s\tGemini 4 Argon (High)\ncustom-id\tCustom Display\ngpt-oss\tGPT-OSS 120B (Medium)\n' "$AGY_TEST_CODING_PIN" "$AGY_TEST_REVIEW_PIN"
    fi
    exit 0 ;;
  agent)
    printf '%s\n' "$*" >> "$AGY_ARGS_FILE"
    [ "${AGY_ROSTER_MODE:-}" = nonzero ] && exit 19
    [ "${AGY_ROSTER_MODE:-}" = empty ] || printf '%s\n' peer-security-reviewer peer-code-reviewer
    exit 0 ;;
esac
n=$(cat "$AGY_STUB_COUNT_FILE"); n=$((n + 1)); echo "$n" > "$AGY_STUB_COUNT_FILE"
printf 'PWD=%s\nCALL=%s\n%s\n' "$PWD" "$n" "$*" >> "$AGY_ARGS_FILE"
cat > "$AGY_STDIN_FILE"
[ -z "${AGY_STUB_ACTIONS:-}" ] || bash "$AGY_STUB_ACTIONS" "$n"
for i in $(seq 1 100); do printf 'Minor: REVIEW LINE %s src/x.go:1 ok\n' "$i"; done
rc=${AGY_STUB_RC:-0}
if [ -n "${AGY_STUB_RC_ON_CALL:-}" ] && [ "$n" != "$AGY_STUB_RC_ON_CALL" ]; then rc=0; fi
exit "$rc"
STUB
  chmod +x "$TMP/bin/agy"
}

export AGY_STUB_COUNT_FILE="$TMP/cfg-count" AGY_STUB_ACTIONS="$TMP/cfg-actions"
run_cfg_review() {
  echo 0 > "$AGY_STUB_COUNT_FILE"
  : > "$AGY_ARGS_FILE"
  TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$1" > "$TMP/cfg.out" 2> "$TMP/cfg.err"
}
