#!/usr/bin/env bash
# coding-preflight.sh — deterministic readiness check for a coding-dispatch agent.
#
# Usage: coding-preflight.sh <codex|agy>
# Emits KEY=VALUE contract lines on stdout; human notes on stderr.
# Exit 0 = ready (last line is PREFLIGHT=ok); non-zero = not ready (reason given).
#
# Run ONCE when the user opts into a coding agent ("use codex for coding" /
# "use agy for coding"), before delegating any task. Deterministic on purpose, and
# kept out of token-heavy inline prompt blocks.
set -uo pipefail

# Resolve through symlinks so a ~/.local/bin symlink still finds sibling helpers
# in the real checkout bin/ (BASH_SOURCE is the symlink path otherwise).
_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  case "$_src" in /*) ;; *) _src="$_dir/$_src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
agent="${1:-}"
note() { printf '%s\n' "$*" >&2; }
fail() { printf 'PREFLIGHT=error: %s\n' "$1"; note "✗ ${agent:-?} preflight: $1"; exit 1; }

case "$agent" in
  codex)
    bin="$(command -v codex || true)"
    [ -z "$bin" ] && [ -x "$HOME/.local/bin/codex" ] && bin="$HOME/.local/bin/codex"
    [ -z "$bin" ] && fail "codex binary not found (PATH or ~/.local/bin)"
    # Nesting guard: never delegate to codex from inside a codex sandbox.
    if [ -n "${CODEX_SANDBOX:-}" ] || [ -n "${CODEX_SESSION_ID:-}" ]; then
      fail "already inside a codex sandbox — do not nest; finish locally"
    fi
    ver="$("$bin" --version 2>/dev/null | head -1)"
    auth="$("$bin" login status 2>&1 | head -1)"
    case "$auth" in *"Logged in"*) : ;; *) fail "codex not logged in ($auth) — run: codex login" ;; esac
    # Model + reasoning effort inherit from ~/.codex/config.toml; never pin -m / -c.
    model="$(grep -E '^[[:space:]]*model[[:space:]]*=' "$HOME/.codex/config.toml" 2>/dev/null | head -1 | sed -E 's/.*=[[:space:]]*"?([^"]+)"?.*/\1/')"
    [ -z "$model" ] && model="codex default"
    echo "CODING_AGENT=codex"
    echo "CODING_BIN=$bin"
    echo "CODING_MODEL=$model"
    echo "CODING_INVOKE=codex exec --dangerously-bypass-approvals-and-sandbox -C <dir> -   (prompt on stdin)"
    echo "PREFLIGHT=ok"
    note "✓ codex ready — $ver, model: $model, $auth"
    ;;
  agy)
    bin="$(command -v agy || true)"
    [ -z "$bin" ] && [ -x "$HOME/.local/bin/agy" ] && bin="$HOME/.local/bin/agy"
    [ -z "$bin" ] && fail "agy binary not found (PATH or ~/.local/bin)"
    # Best-effort nesting guard (agy session markers, if present).
    if [ -n "${ANTIGRAVITY_SESSION:-}" ] || [ -n "${AGY_SESSION_ID:-}" ]; then
      fail "already inside an agy session — do not nest; finish locally"
    fi
    # shellcheck disable=SC1091  # dynamic source path ($SCRIPT_DIR); resolved at runtime
    . "$SCRIPT_DIR/agy-auth-probe.sh"
    AGY_BIN="$bin" agy_auth_probe
    auth_rc=$?
    case "$auth_rc" in
      0) : ;;
      2) note "⚠ agy auth probe inconclusive — proceeding" ;;
      7) fail "agy not signed in — run: agy (launch once to sign in)" ;;
      *) fail "agy auth probe failed unexpectedly (rc=$auth_rc)" ;;
    esac
    # Prompt-form version-drift probe: agy 1.1.22
    # validates bare stdin as the working headless form. Re-check that exact form
    # against the installed binary before trusting a dispatch.
    # shellcheck disable=SC1091  # dynamic source path ($SCRIPT_DIR); resolved at runtime
    . "$SCRIPT_DIR/agy-print-form-probe.sh"
    AGY_BIN="$bin" agy_print_form_probe
    form_rc=$?
    case "$form_rc" in
      0) : ;;
      2) note "⚠ agy prompt-form probe could not run — proceeding" ;;
      *) fail "agy prompt-form probe failed — bare stdin did not round-trip the sentinel (agy may be broken or the invocation form drifted)" ;;
    esac
    echo "CODING_AGENT=agy"
    echo "CODING_BIN=$bin"
    echo "CODING_MODEL=agy default (Antigravity)"
    echo "CODING_INVOKE=agy < brief   (prompt on bare stdin; the _coding-result.json marker is the success signal, NOT stdout)"
    echo "PREFLIGHT=ok"
    note "✓ agy ready + authed — $bin"
    ;;
  *)
    printf 'PREFLIGHT=error: unknown agent %q (use: codex|agy)\n' "${agent:-}"
    note "usage: coding-preflight.sh <codex|agy>"
    exit 2
    ;;
esac
