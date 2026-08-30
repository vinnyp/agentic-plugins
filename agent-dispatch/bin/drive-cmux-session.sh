#!/usr/bin/env bash
# drive-cmux-session.sh — drive a cold agent TUI over cmux and capture its reply.
#
# Cmux sibling of drive-cold-session.sh (the tmux path). Same mechanics,
# same flow contract; differs only in surface layer: cmux workspaces instead of
# tmux sessions, cmux notify/set-status for watch-me-drive UX, and the in-instance
# trust constraint (see GOTCHA below).
#
# Bundles the hard-won mechanics from the driving-agent-sessions skill:
#   create workspace (cmux, in <workdir>, focused) -> boot-settle ->
#   bracketed-paste prompt (set-buffer + paste-buffer) ->
#   submit (send-key Enter) -> settle-poll (read-screen stability) ->
#   print transcript -> leave workspace open (default).
#
# GOTCHA — in-instance trust: cmux operates under socketControlMode 'automation',
# which grants peer-credential trust only to processes running INSIDE the live cmux
# instance. If you see "Failed to write to socket (Broken pipe)", you're running this
# script from outside that instance (e.g., a plain terminal or a stale session).
# Fix: open a terminal inside the running cmux instance and invoke from there.
#
# Usage:
#   drive-cmux-session.sh <agent> <workdir> <prompt-file> [workspace-name]
#
#   <agent>           claude | codex | agy   (command to launch; must be on PATH)
#   <workdir>         directory to start the workspace in (this sets loaded context)
#   <prompt-file>     file whose entire contents are pasted as ONE prompt
#   [workspace-name]  cmux workspace name (default: drive-<agent>-<pid>)
#
# Env knobs (all optional):
#   DCS_BOOT_MAX=60     max seconds to wait for the TUI to settle after launch
#   DCS_SETTLE_MAX=240  max seconds to wait for the agent's reply to settle
#   DCS_STABLE=3        consecutive stable captures that count as "settled"
#   DCS_INTERVAL=2      seconds between captures
#   DCS_CLOSE=0         set 1 to close the workspace after printing (default: leave open)
#
# NOTE on interstitials: codex (update/model offers) and agy (folder-trust) may sit
# on a prompt at boot. This script's boot-settle waits them out but does NOT auto-
# answer them — if the transcript shows the launcher still on an interstitial, send
# the documented keystroke yourself (see the per-agent table in SKILL.md) and re-run
# the paste/submit, or drive the rest by hand. Best-effort, not magic.
set -euo pipefail

die() { printf 'drive-cmux-session: %s\n' "$*" >&2; exit 2; }

[[ $# -ge 3 ]] || die "usage: drive-cmux-session.sh <agent> <workdir> <prompt-file> [workspace-name]"
agent="$1"; workdir="$2"; prompt_file="$3"
ws_name="${4:-drive-${agent}-$$}"

command -v cmux  >/dev/null || die "cmux not found on PATH"
command -v "$agent" >/dev/null || die "agent command '$agent' not found on PATH"
[[ -d "$workdir" ]]     || die "workdir not a directory: $workdir"
[[ -f "$prompt_file" ]] || die "prompt file not found: $prompt_file"

# Verify we can reach the running cmux instance before we do anything else.
# A "Broken pipe" here is the in-instance GOTCHA — run this script from inside cmux.
cmux ping >/dev/null 2>&1 || die "cmux ping failed — are you running inside a live cmux instance? (see GOTCHA in header)"

boot_max="${DCS_BOOT_MAX:-60}"
settle_max="${DCS_SETTLE_MAX:-240}"
stable_needed="${DCS_STABLE:-3}"
interval="${DCS_INTERVAL:-2}"
close_after="${DCS_CLOSE:-0}"

# ws_ref is set once we have the workspace ref from cmux workspace create output.
ws_ref=""

# snapshot: hash the current visible screen for the given workspace ref.
# Re-capture discipline: the first read after a keystroke is often stale (render lag);
# the settle loop calls this repeatedly until the hash stabilizes.
snapshot() {
  cmux read-screen --workspace "$ws_ref" 2>/dev/null | cksum | awk '{print $1}'
}

# settle: poll until the visible pane stops changing for $stable_needed consecutive
# reads, or until $1 seconds elapse. Returns 0 if settled, 1 if timed out.
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

# ── Create workspace ────────────────────────────────────────────────────────
printf 'drive-cmux-session: creating workspace "%s" running %s in %s\n' \
  "$ws_name" "$agent" "$workdir" >&2

create_out="$(cmux workspace create \
  --name "$ws_name" \
  --cwd  "$workdir" \
  --command "$agent" \
  --focus true)"

# Output looks like: "OK workspace:N"
# Extract the workspace ref (everything from "workspace:" onward).
ws_ref="$(printf '%s' "$create_out" | grep -o 'workspace:[0-9]*' | head -1)"
[[ -n "$ws_ref" ]] || die "could not parse workspace ref from cmux output: $create_out"

printf 'drive-cmux-session: workspace ref = %s\n' "$ws_ref" >&2

# Watch-me-drive: notify the human + mark progress at 0%.
cmux notify \
  --workspace "$ws_ref" \
  --title "drive-cmux-session" \
  --body "Launched $agent in $ws_name — waiting for boot." 2>/dev/null || true
cmux set-status  "agent"  "$agent"    --workspace "$ws_ref" 2>/dev/null || true
cmux set-status  "phase"  "booting"   --workspace "$ws_ref" 2>/dev/null || true
cmux set-progress 0.1 --workspace "$ws_ref" 2>/dev/null || true

# ── Boot-settle ─────────────────────────────────────────────────────────────
printf 'drive-cmux-session: waiting for boot to settle (max %ss)...\n' "$boot_max" >&2
if ! settle "$boot_max"; then
  printf 'drive-cmux-session: WARNING boot still moving after %ss (interstitial? check transcript)\n' \
    "$boot_max" >&2
fi

cmux set-status  "phase"  "prompting" --workspace "$ws_ref" 2>/dev/null || true
cmux set-progress 0.4 --workspace "$ws_ref" 2>/dev/null || true

# ── Bracketed paste + confirm-it-landed ──────────────────────────────────────
# set-buffer + paste-buffer delivers multi-line content as one block so newlines
# land as text rather than submissions. Then one explicit send-key Enter submits.
# (Typing multi-line with sequential send calls fires Enter on every newline.)
#
# CRITICAL (learned the hard way): boot-settle can report "ready" while a TUI's
# input is still warming up — its welcome screen goes static (passing the
# stability poll) a beat before the prompt actually accepts input, so a blind
# paste vanishes. So: paste, then VERIFY a fragment of the prompt is visible on
# screen (re-capture discipline applied to the paste itself); re-paste until it
# lands. We only re-paste when NOTHING landed, so this can't double the input.
# Choose the paste payload: cmux's set-buffer/paste-buffer can TRUNCATE a large
# paste — it silently dropped the MIDDLE of a ~2KB multi-task brief once, so the
# driven agent never saw the tail (and the first-line confirm-landed missed it).
# So: short prompts (including cold-start "no tools, no file reads" probes, which
# MUST be pasted verbatim) paste directly; LONG prompts are delivered as a short
# pointer the agent reads from the file — no paste-size risk. (~1000 bytes / 8 lines.)
prompt_bytes="$(wc -c < "$prompt_file" | tr -d ' ')"
prompt_lines="$(wc -l < "$prompt_file" | tr -d ' ')"
abs_prompt="$(cd "$(dirname "$prompt_file")" && pwd)/$(basename "$prompt_file")"
if (( prompt_bytes > 1000 || prompt_lines > 8 )); then
  paste_text="Read the instructions in $abs_prompt and follow them, then print a summary."
  probe="Read the instructions in"
  printf 'drive-cmux-session: long prompt (%s bytes) — sending a file-pointer to dodge paste truncation.\n' "$prompt_bytes" >&2
else
  paste_text="$(cat "$prompt_file")"
  probe="$(head -1 "$prompt_file" | cut -c1-16)"
fi

landed=0
for attempt in 1 2 3 4 5; do
  cmux set-buffer "$paste_text"
  cmux paste-buffer --workspace "$ws_ref"
  # ride out render lag: check a few times before concluding the paste vanished
  for _chk in 1 2 3; do
    sleep "$interval"
    if [[ -z "$probe" ]] || cmux read-screen --workspace "$ws_ref" 2>/dev/null | grep -qF -- "$probe"; then
      landed=1; break
    fi
  done
  [[ "$landed" == 1 ]] && break
  printf 'drive-cmux-session: prompt not visible after paste (attempt %s) — input may not be ready; re-pasting...\n' "$attempt" >&2
done
[[ "$landed" == 1 ]] || printf 'drive-cmux-session: WARNING prompt fragment never confirmed on screen; submitting anyway.\n' >&2

cmux send-key --workspace "$ws_ref" Enter

cmux set-status  "phase"  "waiting"   --workspace "$ws_ref" 2>/dev/null || true
cmux set-progress 0.5 --workspace "$ws_ref" 2>/dev/null || true

# ── Reply-settle ─────────────────────────────────────────────────────────────
printf 'drive-cmux-session: prompt submitted, waiting for reply to settle (max %ss)...\n' \
  "$settle_max" >&2

if settle "$settle_max"; then
  printf 'drive-cmux-session: settled.\n' >&2
  cmux set-status "phase" "done" --workspace "$ws_ref" 2>/dev/null || true
else
  printf 'drive-cmux-session: WARNING reply still moving after %ss; printing current screen.\n' \
    "$settle_max" >&2
  cmux set-status "phase" "timeout" --workspace "$ws_ref" 2>/dev/null || true
fi

cmux set-progress 0.9 --workspace "$ws_ref" 2>/dev/null || true
cmux trigger-flash --workspace "$ws_ref" 2>/dev/null || true

# ── Print transcript ─────────────────────────────────────────────────────────
printf '\n===== TRANSCRIPT (workspace %s / %s) =====\n' "$ws_ref" "$ws_name"
cmux read-screen --workspace "$ws_ref" --scrollback
printf '===== END TRANSCRIPT =====\n'

# ── Watch-me-drive: final notification ──────────────────────────────────────
cmux notify \
  --workspace "$ws_ref" \
  --title "drive-cmux-session" \
  --body "Done — workspace $ws_name ($ws_ref) left open." 2>/dev/null || true
cmux set-progress 1.0 --workspace "$ws_ref" 2>/dev/null || true

# ── Close or leave ───────────────────────────────────────────────────────────
if [[ "$close_after" == "1" ]]; then
  cmux workspace close --workspace "$ws_ref" 2>/dev/null || true
  printf 'drive-cmux-session: workspace %s closed.\n' "$ws_ref" >&2
else
  printf 'drive-cmux-session: workspace %s left open (select: cmux workspace select --workspace %s).\n' \
    "$ws_ref" "$ws_ref" >&2
fi
