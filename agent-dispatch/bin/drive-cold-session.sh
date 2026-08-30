#!/usr/bin/env bash
# drive-cold-session.sh — drive a cold agent TUI over tmux and capture its reply.
#
# Bundles the hard-won mechanics from the driving-agent-sessions skill:
#   create (detached, in <workdir>) -> boot-settle -> bracketed-paste prompt ->
#   submit (Enter) -> settle-poll (screen stability) -> print transcript.
# Leaves the session RUNNING so you can inspect or continue it.
#
# Usage:
#   drive-cold-session.sh [--model M] [--approve] [--timeout S] <agent> <workdir> <prompt-file> [session-name]
#
#   --model M      model to launch the agent with (claude/agy: --model M; codex: -m M).
#                  Multi-word names with spaces/parens are kept intact as one arg,
#                  e.g. --model "Gemini 3.5 Flash (Low)".
#   --approve      auto-approve tool calls so an unattended tool-using session does not
#                  stall on permission prompts (claude/agy: --dangerously-skip-permissions;
#                  codex: --dangerously-bypass-approvals-and-sandbox).
#   --timeout S    reply-settle timeout in seconds (overrides DCS_SETTLE_MAX).
#   <agent>        claude | codex | agy   (command to launch; must be on PATH)
#   <workdir>      directory to start the session in (this sets the loaded context)
#   <prompt-file>  file whose entire contents are pasted as ONE prompt
#   [session-name] tmux session name (default: drive-<agent>-<pid>)
#
# Env knobs (all optional):
#   DCS_BOOT_MAX=60     max seconds to wait for the TUI to settle after launch
#   DCS_SETTLE_MAX=240  max seconds to wait for the agent's reply to settle
#   DCS_STABLE=3        consecutive stable captures that count as "settled"
#   DCS_INTERVAL=2      seconds between captures
#   DCS_KILL=0          set 1 to kill the session after printing (default: leave up)
#
# NOTE on interstitials: codex (update/model offers) and agy (folder-trust) may sit
# on a prompt at boot. codex prompts are still manual. agy is launched with
# --add-dir <workdir> so the TUI scopes the repo as a workspace; when --approve is
# set, this script also best-effort accepts agy's folder-trust interstitial by
# sending the documented Enter keystroke. Without --approve, trust remains manual.
set -euo pipefail

die() { printf 'drive-cold-session: %s\n' "$*" >&2; exit 2; }

# Parse optional dispatch-worker-style flags BEFORE the positionals, so the legacy
# "<agent> <workdir> <prompt-file> [name]" form keeps working unchanged.
model=""; approve=0; timeout_override=""
positionals=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)     [[ $# -ge 2 ]] || die "--model needs a value"; model="$2"; shift 2 ;;
    --model=*)   model="${1#*=}"; shift ;;
    --approve)   approve=1; shift ;;
    --timeout)   [[ $# -ge 2 ]] || die "--timeout needs a value"; timeout_override="$2"; shift 2 ;;
    --timeout=*) timeout_override="${1#*=}"; shift ;;
    --)          shift; while [[ $# -gt 0 ]]; do positionals+=("$1"); shift; done ;;
    --*)         die "unknown flag: $1" ;;
    *)           positionals+=("$1"); shift ;;
  esac
done
set -- "${positionals[@]}"

[[ $# -ge 3 ]] || die "usage: drive-cold-session.sh [--model M] [--approve] [--timeout S] <agent> <workdir> <prompt-file> [session-name]"
agent="$1"; workdir="$2"; prompt_file="$3"
sess="${4:-drive-${agent}-$$}"

command -v tmux >/dev/null || die "tmux not found on PATH"
command -v "$agent" >/dev/null || die "agent command '$agent' not found on PATH"
[[ -d "$workdir" ]] || die "workdir not a directory: $workdir"
[[ -f "$prompt_file" ]] || die "prompt file not found: $prompt_file"

# Build the agent launch command with optional --model + auto-approve, per agent. The
# model may contain spaces/parens, so each token is shell-quoted into the command string
# tmux runs (tmux new-session execs its command argument through the shell).
launch=("$agent")
case "$agent" in
  claude)
    [[ -n "$model" ]] && launch+=(--model "$model")
    (( approve )) && launch+=(--dangerously-skip-permissions) ;;
  agy)
    [[ -n "$model" ]] && launch+=(--model "$model")
    (( approve )) && launch+=(--dangerously-skip-permissions)
    launch+=(--add-dir "$workdir") ;;
  codex)
    [[ -n "$model" ]] && launch+=(-m "$model")
    (( approve )) && launch+=(--dangerously-bypass-approvals-and-sandbox) ;;
  *)
    { [[ -n "$model" ]] || (( approve )); } && die "--model/--approve not supported for agent '$agent'" ;;
esac
launch_cmd=""
for a in "${launch[@]}"; do launch_cmd+=" $(printf '%q' "$a")"; done

boot_max="${DCS_BOOT_MAX:-60}"
settle_max="${timeout_override:-${DCS_SETTLE_MAX:-240}}"
stable_needed="${DCS_STABLE:-3}"
interval="${DCS_INTERVAL:-2}"
kill_after="${DCS_KILL:-0}"

snapshot() { tmux capture-pane -p -t "$sess" 2>/dev/null | cksum | awk '{print $1}'; }
capture_text() { tmux capture-pane -p -t "$sess" 2>/dev/null || true; }

agy_accept_folder_trust() {
  local max="$1" text elapsed=0
  while (( elapsed < max )); do
    text="$(capture_text)"
    if grep -Eiq 'do you trust|trust the contents|folder[- ]trust|workspace.*trust|project.*trust' <<<"$text"; then
      printf 'drive-cold-session: accepting agy folder-trust prompt with Enter (--approve).\n' >&2
      tmux send-keys -t "$sess" Enter
      return 0
    fi
    if grep -Eq '(^|[[:space:]])>[[:space:]]*$' <<<"$text"; then
      return 1
    fi
    sleep "$interval"; (( elapsed += interval ))
  done
  return 1
}

# Wait until the visible pane stops changing for $stable_needed consecutive reads,
# or until $1 seconds elapse. Returns 0 if it settled, 1 if it timed out (still moving).
settle() {
  local max="$1" last="" cur count=0 elapsed=0
  while (( elapsed < max )); do
    cur="$(snapshot || true)"
    if [[ -n "$cur" && "$cur" == "$last" ]]; then
      (( count++ )); (( count >= stable_needed )) && return 0
    else
      count=0; last="$cur"
    fi
    sleep "$interval"; (( elapsed += interval ))
  done
  return 1
}

printf 'drive-cold-session: launching%s in %s (session %s)\n' "$launch_cmd" "$workdir" "$sess" >&2
tmux new-session -d -s "$sess" -c "$workdir" "$launch_cmd"

if [[ "$agent" == "agy" ]] && (( approve )); then
  agy_accept_folder_trust "$boot_max" || true
fi

printf 'drive-cold-session: waiting for boot to settle (max %ss)...\n' "$boot_max" >&2
settle "$boot_max" || printf 'drive-cold-session: WARNING boot still moving after %ss (interstitial? check transcript)\n' "$boot_max" >&2

# Bracketed paste so multi-line prompts land as text (each newline would otherwise submit).
tmux set-buffer -b dcs_prompt -- "$(cat "$prompt_file")"
tmux paste-buffer -p -b dcs_prompt -t "$sess"
tmux delete-buffer -b dcs_prompt 2>/dev/null || true

# Let the paste render before submitting; re-capture discipline.
sleep "$interval"
tmux send-keys -t "$sess" Enter

printf 'drive-cold-session: prompt submitted, waiting for reply to settle (max %ss)...\n' "$settle_max" >&2
if settle "$settle_max"; then
  printf 'drive-cold-session: settled.\n' >&2
else
  printf 'drive-cold-session: WARNING reply still moving after %ss; printing current screen.\n' "$settle_max" >&2
fi

printf '\n===== TRANSCRIPT (session %s) =====\n' "$sess"
tmux capture-pane -p -t "$sess" -S -
printf '===== END TRANSCRIPT =====\n'

if [[ "$kill_after" == "1" ]]; then
  tmux kill-session -t "$sess" 2>/dev/null || true
  printf 'drive-cold-session: session %s killed.\n' "$sess" >&2
else
  printf 'drive-cold-session: session %s left running (attach: tmux attach -t %s).\n' "$sess" "$sess" >&2
fi
