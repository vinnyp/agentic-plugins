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
#                  e.g. --model "Gemini 3.8 Flash (Low)".
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
#   DCS_DEBUG=0         set 1 to print alternate-screen state after boot
#   DCS_COLS=200        tmux pane width  (a detached session otherwise defaults to 80x24)
#   DCS_ROWS=200        tmux pane height
# Exit codes: 0 complete transcript; 1 unexpected error; 2 usage/prerequisite;
#   3 did not settle (stdout holds the transcript so far); 4 boot interstitial needs a human;
#   5 agent exited; 6 alternate-screen transcript completeness cannot be verified.
#
# NOTE on interstitials: codex (daemon/update/model/folder-trust), claude
# (folder-trust/bypass-permissions), and
# agy (folder-trust) may sit on a prompt at boot. codex and claude prompts are
# manual. agy is launched with
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
    launch+=(--no-alt-screen)
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
pane_cols="${DCS_COLS:-200}"
pane_rows="${DCS_ROWS:-200}"
[[ "$pane_cols" =~ ^[1-9][0-9]*$ ]] || die "DCS_COLS must be a positive integer (usage: DCS_COLS=N drive-cold-session.sh ...)"
[[ "$pane_rows" =~ ^[1-9][0-9]*$ ]] || die "DCS_ROWS must be a positive integer (usage: DCS_ROWS=N drive-cold-session.sh ...)"
buffer="dcs_prompt_${sess}"
dead_session=0
session_created=0
launched=0
buffer_created=0
cleanup() {
  local pane_dead
  if [[ "$buffer_created" == "1" ]]; then
    tmux delete-buffer -b "$buffer" 2>/dev/null || true
  fi
  [[ "$session_created" == "1" ]] || return 0
  pane_dead="$(tmux display-message -p -t "=$sess:" '#{pane_dead}' 2>/dev/null)" || pane_dead=""
  if [[ "$launched" != "1" || "$kill_after" == "1" || "$dead_session" == "1" || "$pane_dead" == "1" ]]; then
    tmux kill-session -t "=$sess" 2>/dev/null || true
  fi
}
trap cleanup EXIT

session_disappeared() { printf 'drive-cold-session: tmux session %s disappeared\n' "$sess" >&2; exit 1; }
capture_text() { tmux capture-pane -p -J -t "=$sess:" 2>/dev/null || session_disappeared; }
full_transcript() { tmux capture-pane -p -J -t "=$sess:" -S - 2>/dev/null || session_disappeared; }
print_transcript() {
  local transcript
  transcript="$(full_transcript)"
  printf '\n===== TRANSCRIPT (session %s) =====\n' "$sess"
  printf '%s\n' "$transcript"
  printf '===== END TRANSCRIPT =====\n'
}
snapshot() {
  local screen
  screen="$(capture_text)" || return 1
  printf '%s\n' "$screen" | cksum | awk '{print $1}'
}
check_agent_alive() {
  local dead status phase="${1:-pre}"
  dead="$(tmux display-message -p -t "=$sess:" '#{pane_dead}' 2>/dev/null)" || session_disappeared
  if [[ "$dead" == "1" ]]; then
    status="$(tmux display-message -p -t "=$sess:" '#{pane_dead_status}' 2>/dev/null)" || session_disappeared
    # tmux marks a pane dead when its pty closes but records the exit status only
    # once it reaps the child, so an immediate read can be empty (seen on tmux 3.4).
    local tries=0
    while [[ -z "$status" ]] && (( tries < 20 )); do
      sleep 0.1
      status="$(tmux display-message -p -t "=$sess:" '#{pane_dead_status}' 2>/dev/null)" || session_disappeared
      (( tries += 1 ))
    done
    [[ -n "$status" ]] || status="unknown"
    dead_session=1
    if [[ "$phase" == "post" ]]; then
      print_transcript
      printf 'drive-cold-session: agent exited after the prompt was submitted (status %s)\n' "$status" >&2
    else
      printf 'drive-cold-session: last screen before agent exited:\n' >&2
      capture_text >&2
      printf 'drive-cold-session: agent exited (status %s) before replying\n' "$status" >&2
    fi
    exit 5
  fi
}

agy_accept_folder_trust() {
  local max="$1" text elapsed=0
  while (( elapsed < max )); do
    text="$(capture_text)"
    if grep -Eiq 'do you trust|trust the contents|folder[- ]trust|workspace.*trust|project.*trust' <<<"$text"; then
      printf 'drive-cold-session: accepting agy folder-trust prompt with Enter (--approve).\n' >&2
      tmux send-keys -t "=$sess:" Enter
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
  local max="$1" phase="${2:-pre}" last="" cur count=0 elapsed=0
  while (( elapsed < max )); do
    check_agent_alive "$phase"
    cur="$(snapshot)" || exit 1
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
# Older tmux applies history-limit only to panes created after it is set. Create
# the session with a disposable window, raise the limit, then create the agent pane.
placeholder_window="$(tmux new-session -d -P -F '#{window_id}' -x "$pane_cols" -y "$pane_rows" \
  -s "$sess" -c "$workdir" 'cat')"
session_created=1
history_limit="$(tmux show-option -v -t "=$sess:" history-limit)"
if (( history_limit < 50000 )); then
  tmux set-option -t "=$sess:" history-limit 50000
fi
agent_pane="$(tmux new-window -P -F '#{pane_id}' -t "=$sess:" -c "$workdir" \
  -e 'CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1' 'cat')"
if [[ "${DCS_TEST_FAIL_LAUNCH:-0}" == "1" ]]; then
  printf 'drive-cold-session: simulated mid-launch failure\n' >&2
  exit 1
fi
tmux set-option -w -t "$agent_pane" remain-on-exit on
tmux respawn-pane -k -t "$agent_pane" -e 'CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1' "$launch_cmd"
tmux kill-window -t "$placeholder_window"
launched=1

if [[ "$agent" == "agy" ]] && (( approve )); then
  agy_accept_folder_trust "$boot_max" || true
fi

printf 'drive-cold-session: waiting for boot to settle (max %ss)...\n' "$boot_max" >&2
if ! settle "$boot_max"; then
  print_transcript
  printf 'drive-cold-session: boot did not settle within %ss; session left up for inspection\n' "$boot_max" >&2
  exit 3
fi
if [[ "${DCS_DEBUG:-0}" == "1" ]]; then
  boot_alternate="$(tmux display-message -p -t "=$sess:" '#{alternate_on}' 2>/dev/null)" || session_disappeared
  printf 'drive-cold-session: boot alternate_on=%s\n' "$boot_alternate" >&2
fi

# Claude's folder-trust dialog defaults to exiting. Trust must be granted by a human
# because accepting it writes to the user's Claude configuration.
if [[ "$agent" == "claude" ]]; then
  boot_screen="$(capture_text)"
  if grep -Eiq 'Bypass Permissions mode' <<<"$boot_screen"; then
    printf 'drive-cold-session: claude bypass-permissions boot interstitial; accept it once interactively in session %s. No prompt sent.\n' "$sess" >&2
    exit 4
  elif grep -Eiq 'Is this a project you created or one you trust|Do you trust the files in this folder' <<<"$boot_screen"; then
    if [[ "$kill_after" == "1" ]]; then
      printf 'drive-cold-session: claude folder-trust boot interstitial; trust the folder or run Claude once interactively. Session %s killed (DCS_KILL=1). No prompt sent.\n' "$sess" >&2
    else
      printf 'drive-cold-session: claude folder-trust boot interstitial; trust the folder or run Claude once interactively in session %s. No prompt sent.\n' "$sess" >&2
    fi
    exit 4
  fi
fi

# codex "Background server has incompatible feature settings" defaults to Cancel: the
# paste + Enter below would quit codex and leave no transcript. Stop and say so instead
# (answer it by hand with "Run without daemon this time"; never the daemon restart).
if [[ "$agent" == "codex" ]]; then
  boot_screen="$(capture_text)"
  screen=""
  if grep -Eiq 'Run without daemon this time|incompatible feature settings|Cannot use the background server' <<<"$boot_screen"; then
    screen="daemon-settings"
  elif grep -Eiq 'Update now' <<<"$boot_screen" && grep -Eiq 'Skip' <<<"$boot_screen"; then
    screen="update"
  elif grep -Eiq 'Use existing model' <<<"$boot_screen"; then
    screen="model-offer"
  elif grep -Eiq 'Trust this folder\?|Trust and continue|Do you trust the contents of this directory' <<<"$boot_screen"; then
    screen="folder-trust"
  fi
  if [[ -n "$screen" ]]; then
    if [[ "$kill_after" == "1" ]]; then
      printf 'drive-cold-session: codex %s boot interstitial; session %s killed (DCS_KILL=1). No prompt sent.\n' "$screen" "$sess" >&2
    else
      printf 'drive-cold-session: codex %s boot interstitial; session %s left up for a human to answer. No prompt sent.\n' "$screen" "$sess" >&2
    fi
    exit 4
  fi
fi

# Bracketed paste so multi-line prompts land as text (each newline would otherwise submit).
tmux set-buffer -b "$buffer" -- "$(cat "$prompt_file")"
buffer_created=1
tmux paste-buffer -p -b "$buffer" -t "=$sess:"

# Let the paste render before submitting; re-capture discipline.
sleep "$interval"
check_agent_alive
tmux send-keys -t "=$sess:" Enter

printf 'drive-cold-session: prompt submitted, waiting for reply to settle (max %ss)...\n' "$settle_max" >&2
reply_rc=0
if settle "$settle_max" post; then
  printf 'drive-cold-session: settled.\n' >&2
else
  printf 'drive-cold-session: reply did not settle within %ss; transcript is partial.\n' "$settle_max" >&2
  reply_rc=3
fi

check_agent_alive post
print_transcript
alternate_on="$(tmux display-message -p -t "=$sess:" '#{alternate_on}' 2>/dev/null)" || session_disappeared
if [[ "$alternate_on" == "1" ]]; then
  printf 'drive-cold-session: transcript completeness cannot be verified: agent is in alternate-screen mode\n' >&2
  if [[ "$reply_rc" == "0" ]]; then reply_rc=6; fi
fi

if [[ "$kill_after" == "1" ]]; then
  printf 'drive-cold-session: session %s killed.\n' "$sess" >&2
else
  printf 'drive-cold-session: session %s left running (attach: tmux attach -t =%s).\n' "$sess" "$sess" >&2
fi
exit "$reply_rc"
