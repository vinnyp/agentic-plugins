# shellcheck shell=bash
# test-env-reset.sh — shared test-harness helper for agent-dispatch. Sourced,
# not executed directly (no shebang / not chmod +x on purpose).
#
# PROBLEM: dispatch environment variables an operator has exported in their
# shell (e.g. raising CODING_DISPATCH_TIMEOUT for a slow model, exactly as the
# playbook advises) leak into these test suites when they shell out to
# coding-dispatch.sh / coding-build-phase.sh / dispatch-worker, turning a
# suite red with nothing wrong in the code — and the red shows up in a suite
# unrelated to the reason the operator set the variable.
#
# FIX: source this file and call reset_dispatch_env BEFORE any test body
# runs, in every bin/test-*.sh that shells one of those three entrypoints.
# reset_dispatch_env only unsets — it must NOT be sourced by (or its list
# copied into) coding-dispatch.sh / coding-build-phase.sh / dispatch-worker
# themselves; neutralising the operator's own knobs belongs to the test
# harness, not to the scripts under test.
#
# DISPATCH_ENV_VARS is the single authoritative list — kept in sync with the
# vars those three entrypoints actually read (grep bin/ for CODING_*, DISPATCH_*
# and AGY_MODEL). test-dispatch-env-reset.sh's completeness check asserts every
# such var it finds is covered here (directly or via an explicit opt-out) —
# extend this list first if that check ever fails.
DISPATCH_ENV_VARS=(
  CODING_DISPATCH_TIMEOUT
  CODING_DISPATCH_WORKTREE
  CODING_DISPATCH_RM_ON_FAIL
  CODING_DISPATCH_CHILD_ENV
  CODING_BUILD_CMD
  CODING_COMMIT_SCOPE
  AGY_MODEL
  DISPATCH_GATE_ADVISORY_TTL_SECS
  # Registered 2026-08-27. A real operator knob, not a label: dispatch-worker:340
  # reads ${DISPATCH_LIMIT_NOOP_BYTES:-200} as the byte floor below which a
  # limit-signature stdout counts as a no-op. It was never on this list, so an
  # operator value leaked into every test run.
  DISPATCH_LIMIT_NOOP_BYTES
  # Registered 2026-08-17. These two predate this list and
  # were never on it: #148's completeness scan only matched CODING_* plus two
  # literals, so the whole DISPATCH_* family was invisible to it. Measured, not
  # assumed — DISPATCH_REVIEW_PIN_TTL_SECS=0 reddens test-coding-dispatch.sh
  # (#140's pin guard stops firing), which is exactly the leak #148 set out to
  # close. The scan in test-dispatch-env-reset.sh now matches DISPATCH_[A-Z_]+
  # generically so the next one cannot hide the same way.
  DISPATCH_REVIEW_PIN_TTL_SECS
  DISPATCH_MIN_REVIEW_BYTES
  DISPATCH_REVIEW_REQUIRE_EVIDENCE
  DISPATCH_REVIEW_WT_DIR
  # Registered 2026-08-29. lib/gate-env.sh reads DISPATCH_NO_VENV as the
  # opt-out for prepending <workdir>/.venv/bin to the gate child's PATH.
  DISPATCH_NO_VENV
  # Registered 2026-08-29. --allow-dirty's env twin:
  # dispatch-worker reads ${DISPATCH_ALLOW_DIRTY:-0} to keep the old
  # warn-and-proceed behavior when a brief names an uncommitted/untracked path
  # in a dirty review tree, instead of refusing (exit 2).
  DISPATCH_ALLOW_DIRTY
)

reset_dispatch_env() {
  local var
  for var in "${DISPATCH_ENV_VARS[@]}"; do
    unset "$var"
  done
}
