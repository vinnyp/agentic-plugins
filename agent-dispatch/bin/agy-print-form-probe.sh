#!/usr/bin/env bash
# Source-able agy prompt-form version-drift probe. Defines agy_print_form_probe only.
#
# agy 1.1.22 rejects both `agy exec - < prompt` and
# `agy - < prompt`. The validated headless form is now bare stdin:
# `agy < prompt`. This probe checks that exact form against the installed binary
# so version drift is caught before dispatch-worker relies on it.
#
# Every attempt is bounded by a short external timeout: the positional form
# historically hung (#32); no longer reproduces on agy 1.1.15 as of 2026-08-19 —
# the </dev/null + timeout guards stay as cheap hardening against a future
# regression, so an unbounded attempt here could still wedge preflight itself,
# which is exactly the failure this probe exists to prevent.

agy_print_form_probe() {
  local agy_bin="${AGY_BIN:-agy}"
  # Default calibrated from live agy 1.1.15 single-turn latency (~12-18s observed);
  # 30s is ~2x the worst observed round trip. env override (AGY_FORM_PROBE_TIMEOUT)
  # stays available for a slower environment or a future model. An earlier 10s
  # default was itself the bug — both invocation forms round-trip correctly on
  # agy 1.1.15, they just take longer than 10s to answer.
  local probe_timeout="${AGY_FORM_PROBE_TIMEOUT:-30s}"
  local sentinel="AGY_FORM_PROBE_$$_${RANDOM:-0}"
  local prompt="Reply with exactly this token and nothing else: $sentinel"
  local timeout_bin=""

  if ! command -v "$agy_bin" >/dev/null 2>&1; then
    printf '%s\n' "agy prompt-form probe: '$agy_bin' not on PATH — cannot probe" >&2
    return 2
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout_bin="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin="gtimeout"
  else
    printf '%s\n' "agy prompt-form probe: no timeout/gtimeout on PATH — SKIPPING (cannot bound the live prompt-form probe; install coreutils)" >&2
    return 2
  fi

  # BARE STDIN FORM — `agy < prompt` (validated against agy 1.1.22).
  local stdin_out stdin_rc stdin_ok=0
  stdin_out="$(printf '%s\n' "$prompt" | "$timeout_bin" "$probe_timeout" "$agy_bin" 2>&1)"
  stdin_rc=$?
  case "$stdin_out" in *"$sentinel"*) stdin_ok=1 ;; esac
  if [ "$stdin_ok" -eq 1 ]; then
    printf '%s\n' "agy prompt-form probe: bare-stdin form round-trips the sentinel — OK" >&2
    return 0
  else
    printf '%s\n' "agy prompt-form probe: bare-stdin form did NOT round-trip the sentinel (rc=$stdin_rc)" >&2
  fi

  printf '%s\n' "agy prompt-form probe: FAIL CLOSED — bare stdin did not round-trip the sentinel. agy may be broken, misconfigured, or a new version changed the invocation form; do not trust an agy dispatch until this is resolved." >&2
  return 1
}
