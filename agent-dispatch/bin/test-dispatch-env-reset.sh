#!/usr/bin/env bash
# test-dispatch-env-reset.sh — regression + completeness guard for the
# dispatch-env-leak fix: operator-exported dispatch vars
# (CODING_DISPATCH_TIMEOUT, AGY_MODEL, etc. — see the playbook's advice to
# raise CODING_DISPATCH_TIMEOUT for a slow model) must not leak into these
# test suites and turn them red with nothing wrong in the code. The reset
# itself lives in bin/lib/test-env-reset.sh and is sourced by every
# bin/test-*.sh that shells coding-dispatch.sh / coding-build-phase.sh /
# dispatch-worker; this file only PROVES the reset does its job and stays
# complete as new knobs are added.
set -uo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck disable=SC1091
. "$BIN_DIR/lib/test-env-reset.sh"
reset_dispatch_env

FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "PASS: $*"; }

# ---------------------------------------------------------------------------
# 1. REGRESSION — a suite that merely passes today proves nothing on its own,
# so assert POSITIVELY: run the real test-coding-dispatch.sh suite as a
# genuine subprocess with the dispatch env deliberately set to non-default
# values, and assert it still passes end to end.
#
# Both values below are independently verified against the original defect to
# break test-coding-dispatch.sh TODAY when a test body doesn't reset first:
#   - CODING_DISPATCH_TIMEOUT=15m fails test #20 ("agy default timeout should
#     be 25m") because an inherited operator value is indistinguishable from
#     an explicit per-command override.
#   - AGY_MODEL=zzz fails the same test #20 because the non-default model
#     name reaches the stubbed agy invocation the assertion inspects.
# Using 1s/zzz here (rather than 15m/a real model name) makes the failure
# mode unmistakable if the reset regresses: a 1s external timeout racing a
# fake agy binary is about as far from a real dispatch config as it gets.
# ---------------------------------------------------------------------------
DISPATCH_SUITE="$BIN_DIR/test-coding-dispatch.sh"
if [ ! -f "$DISPATCH_SUITE" ]; then
  fail "regression: $DISPATCH_SUITE not found"
else
  out="$(CODING_DISPATCH_TIMEOUT=1s AGY_MODEL=zzz bash "$DISPATCH_SUITE" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "regression: test-coding-dispatch.sh is green under CODING_DISPATCH_TIMEOUT=1s AGY_MODEL=zzz"
  else
    echo "$out" | tail -20
    fail "regression: test-coding-dispatch.sh exited $rc under a perturbed operator env — the reset in bin/lib/test-env-reset.sh is missing, not sourced, or not called before the suite body runs"
  fi
fi

# ---------------------------------------------------------------------------
# 2. COMPLETENESS — enumerate the dispatch-shaped names the real (non-test)
# entrypoints under bin/ actually reference, and assert every one is covered
# by DISPATCH_ENV_VARS (the reset list) or an explicit, commented opt-out
# below. This turns "someone remembered to update the reset list" into a
# failing test the moment a new knob is added and forgotten.
#
# A plain name-shaped grep also catches non-env-var false hits — e.g.
# coding-preflight.sh echoes diagnostic labels like "CODING_AGENT=codex" as
# human-readable report text, never reads them as ${CODING_AGENT}. Rather
# than trying to regex-distinguish "read as a var" from "mentioned in text"
# (fragile either way), those get a permanent, commented opt-out below — so
# a genuinely NEW var can't silently hide behind the same exemption; it has
# to be named explicitly, with a reason, by whoever adds it.
# ---------------------------------------------------------------------------
KNOWN_FALSE_HITS=(
  CODING_AGENT   # coding-preflight.sh: echoed diagnostic label, never read as ${CODING_AGENT}
  CODING_BIN     # coding-preflight.sh: echoed diagnostic label, never read as ${CODING_BIN}
  CODING_MODEL   # coding-preflight.sh: echoed diagnostic label, never read as ${CODING_MODEL}
  CODING_INVOKE  # coding-preflight.sh: echoed diagnostic label, never read as ${CODING_INVOKE}
  DISPATCH_BASE  # coding-dispatch.sh: emitted freshness stamp label, not an operator env var
  DISPATCH_BASE_TRACKING # coding-dispatch.sh: emitted freshness stamp label, not an operator env var
  DISPATCH_BASE_STALE    # coding-dispatch.sh: emitted freshness stamp label, not an operator env var (renamed from DISPATCH_BASE_WARNING by #62)
)

contains() {
  local needle="$1"; shift
  local item
  for item in "$@"; do [ "$item" = "$needle" ] && return 0; done
  return 1
}

scan_targets=()
# bin/ AND bin/lib/ — the top-level-only walk was a structural blind spot: a helper
# under bin/lib/ that read a dispatch knob would have been invisible to this scan,
# which is the same class of gap #157 was filed for one level up.
for candidate in "$BIN_DIR"/* "$BIN_DIR"/lib/*; do
  [ -f "$candidate" ] || continue
  case "$(basename "$candidate")" in
    test-*.sh) continue ;;
  esac
  scan_targets+=("$candidate")
done

if [ "${#scan_targets[@]}" -eq 0 ]; then
  fail "completeness: found zero non-test entrypoints under $BIN_DIR — the scan itself is broken"
else
  found_names=()
  while IFS= read -r name || [ -n "$name" ]; do
    [ -n "$name" ] || continue
    found_names+=("$name")
  done < <(grep -rhoE '\bCODING_[A-Z_]+\b|\bDISPATCH_[A-Z_]+\b|\bAGY_MODEL\b' "${scan_targets[@]}" 2>/dev/null | sort -u)

  if [ "${#found_names[@]}" -eq 0 ]; then
    fail "completeness: grep found zero CODING_*/DISPATCH_*/AGY_MODEL hits across ${#scan_targets[@]} entrypoints — that's suspicious (the scan is probably broken), not a real all-clear"
  else
    uncovered=()
    for name in "${found_names[@]}"; do
      if ! contains "$name" "${DISPATCH_ENV_VARS[@]}" && ! contains "$name" "${KNOWN_FALSE_HITS[@]}"; then
        uncovered+=("$name")
      fi
    done
    if [ "${#uncovered[@]}" -eq 0 ]; then
      pass "completeness: all ${#found_names[@]} matched name(s) are covered by DISPATCH_ENV_VARS or a commented opt-out (${found_names[*]})"
    else
      fail "completeness: dispatch-shaped var(s) not covered by DISPATCH_ENV_VARS (bin/lib/test-env-reset.sh) or KNOWN_FALSE_HITS (this file): ${uncovered[*]} — add each to the reset list if it's a real operator-settable knob, or to KNOWN_FALSE_HITS with a comment explaining why not"
    fi
  fi
fi

if [ "$FAILS" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
fi
exit 1
