# shellcheck shell=bash
# gate-env.sh — shared helper for agent-dispatch: pins the build/vet gate to the workdir's
# own venv (when one exists) and discloses the resolved python/ruff before the gate runs.
# Sourced, not executed directly (no shebang / not chmod +x on purpose) — mirrors
# lib/test-env-reset.sh's sourcing convention.
#
# PROBLEM: the gate ran with whatever ruff/python3 the launching shell
# had on PATH instead of the repo-pinned <workdir>/.venv (a global ruff 0.16.4 vs. the pin
# 0.15.16) — the mismatch false-redded a clean build and the dispatcher's hard-revert
# discarded it. The dispatcher owns the revert decision, so it owns making the gate's
# environment visible and, by default, correct.
#
# Usage: source this file, then call (in order):
#   gate_env_apply <workdir> <no_venv:0|1>
#     Prepends <workdir>/.venv/bin to PATH for the REST OF THIS PROCESS (and anything it
#     execs/forks) unless no_venv is 1 or DISPATCH_NO_VENV is set in the environment. A
#     missing <workdir>/.venv/bin is a silent no-op — PATH is left exactly as inherited.
#   gate_env_disclose
#     Prints one line to stderr: "gate-env: python=<path> <version> ruff=<path-or-absent>
#     <version>", resolving each tool via `command -v` against the CURRENT PATH — call this
#     AFTER gate_env_apply so the line reflects what the gate will actually run.
#
# DISPATCH_NO_VENV is a real operator-settable knob (agent-dispatch/bin/lib/test-env-reset.sh
# keeps a completeness scan that traps a new one of these being added and forgotten there).

gate_env_apply() {
  local workdir="$1" no_venv="${2:-0}"
  if [ "$no_venv" = "1" ] || [ -n "${DISPATCH_NO_VENV:-}" ]; then
    return 0
  fi
  if [ -d "$workdir/.venv/bin" ]; then
    PATH="$workdir/.venv/bin:$PATH"
    export PATH
  fi
}

# _gate_env_tool_info <tool> — prints "<resolved-path> <version-line>" if <tool> resolves on
# the current PATH, else "absent" (no trailing version). Never fails the caller: a tool whose
# --version exits non-zero (or prints nothing) still discloses its resolved path.
_gate_env_tool_info() {
  local tool="$1" path ver
  path="$(command -v "$tool" 2>/dev/null)" || true
  if [ -z "$path" ]; then
    printf 'absent'
    return 0
  fi
  ver="$("$path" --version 2>&1 | head -1)"
  printf '%s %s' "$path" "$ver"
}

gate_env_disclose() {
  local py_tool="python3" py_info ruff_info
  command -v python3 >/dev/null 2>&1 || py_tool="python"
  py_info="$(_gate_env_tool_info "$py_tool")"
  ruff_info="$(_gate_env_tool_info ruff)"
  printf 'gate-env: python=%s ruff=%s\n' "$py_info" "$ruff_info" >&2
}
