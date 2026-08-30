---
name: driving-agent-sessions
description: "Use when you need to drive a real, interactive agent session (Claude Code, codex, or agy/Gemini) — typing into its live TUI and reading its output — not a headless one-shot. Two surfaces: cmux when you want a session the human can watch / take over / co-drive (GUI), tmux for headless/unattended/CI. Triggers include validating what a fresh cold session auto-loads, observing or steering a peer agent live, when send-keys / cmux send to a TUI returns stale or empty output, or a \"broken pipe\" driving cmux. NOT for fire-and-forget coding dispatch or programmatic one-shots."
---

# Driving Agent Sessions

## Overview

Some things can only be learned from a **real, persistent agent session** — one loaded exactly as a human's
cold session would be, with its memory namespace auto-injected and its boot interstitials in your way. You
drive it by typing into its TUI and reading what it does — over **cmux** (`cmux send` / `cmux read-screen`,
when you want it visible and co-drivable) or **tmux** (`send-keys` / `capture-pane`, headless). See
*Choosing your surface* below.

## When to use

- **Validate a cold-start bootstrap for real.** You want to trust a fresh session instead of babysitting one
  that only holds context. This is the live-test *engine* for that: deciding **what** to probe is a separate
  job; this decides **how** to drive the session while you probe it.
- **Observe a peer agent's actual behavior** — reproduce something interactively, watch codex/agy work a
  task, steer a session that needs back-and-forth.
- **Any case needing the persistent, human-like session** — memory auto-injects, interstitials appear,
  state survives across turns — which headless modes don't give you.

## When NOT to use (the boundary that matters)

- **Fire-and-forget coding dispatch** → use this plugin's `coding-preflight.sh` + `coding-dispatch.sh`
  (deterministic, git snapshot → validate → hard-revert, marker-file done-signal, external `timeout`).
  Don't hand-drive a TUI for code you're going to review from a diff anyway.
- **Programmatic / headless one-shot (incl. a non-coding skill-run)** → `dispatch-worker --runtime
  <codex|agy|claude> [--ceremony] [--model M]`. It owns the bound (external timeout — never trust a
  runtime's own `--print-timeout`; agy has hung hours past it), runs the agy auth-preflight, and uses
  the validated stdin form (raw `agy --print "<prompt>"` HANGS — `--print` eats the next token). Don't
  hand-roll `claude/codex --print` / `codex exec` with your own `timeout -k`; that's what this wraps.
- This skill is for **interactive, persistent, human-in-the-loop** sessions only. It is deliberately *not*
  the path to programmatic peer dispatch (that direction is A2A/ACP, not a hand-rolled TUI wrapper).

## Choosing your surface

Same mechanics, different surface — pick by whether a human should see it:

| | **cmux** (visible) | **tmux** (headless) |
|---|---|---|
| **Use when** | cmux is running and you want a session the human can **see, take over, or co-drive** — watch-me-drive, parallel co-work, hands-on steering | headless / unattended / CI / no-GUI, or cmux isn't running |
| **Drive / read** | `cmux send` / `cmux send-key` / `cmux read-screen` | `tmux send-keys` / `tmux capture-pane` |
| **Multi-line** | `cmux set-buffer` + `cmux paste-buffer` | `tmux set-buffer` + `tmux paste-buffer -p` |
| **Progress UX** | `cmux notify` / `set-status` / `set-progress` / `trigger-flash` surface progress to the watcher | none — watch the pane yourself |
| **Constraint** | must run **inside** the cmux instance (see *In-instance trust* in `references/driving-over-cmux.md`) | share a tmux server (`tmux ls`) |

Rule of thumb: about to type `tmux new-session` and cmux is in front of you? Use cmux — the human gets a
visible, steerable session and you get the watch-me-drive UX for free.

## The discipline (both surfaces)

1. **A TUI is not an API** — re-capture before acting; the first frame after any keystroke is stale.
2. **Type/paste, CONFIRM it landed, THEN submit separately** — never blind-submit; input can warm up a beat after the screen goes static.
3. **Multi-line prompts: ONE block via bracketed paste** (`set-buffer` → `paste-buffer [-p]`); every bare Enter submits.
4. **Poll completion by screen-stability** — hash successive captures until stable for N reads; background poll (foreground `sleep` is blocked in some harnesses).
5. **Cold-start probe framing:** "answer only from already-loaded context — no tools, no file reads."

## Reference docs

**For driving (agent-facing):**
- `references/driving-over-tmux.md` — tmux command mechanics + `drive-cold-session.sh`
- `references/driving-over-cmux.md` — cmux command map, watch-me-drive UX, **naming workspaces by task** (resume-friendly), in-instance-trust gotcha + `drive-cmux-session.sh`
- `references/agent-boot-interstitials.md` — per-agent boot traps (claude/codex/agy)

**For the human (the cmux desktop app):**
- `cmux-desktop-playbook.md` — beginner guide to the cmux app: the window/workspace/pane/surface model, the configured shortcuts + layouts, watch-me-drive, and config edit/revert. Open it in the cmux viewer with `cmux markdown open <this-skill-dir>/cmux-desktop-playbook.md` (or, in cmux, ⌘⇧P → "Open cmux playbook").

**Naming convention (watch-me-drive) + how resume actually works.** Name a driven cmux workspace after its *task* (e.g. `api-retry-fix`); `drive-cmux-session.sh` (on PATH, provided by the agent-dispatch plugin) takes the name as its 4th arg — pass a task name, not the default `drive-<agent>-<pid>`. The workspace name is the resume handle **within cmux**: reopen that workspace and cmux's `autoResumeAgentSessions` restores the claude session bound to it (cmux keeps its own workspace→session mapping), and the name makes the session easy to spot in the tab bar + sessions sidebar. **Caveat (don't overstate this):** cmux does **not** rename the claude session itself — Claude Code has no session-title field — so claude's *native* `claude --resume` picker shows the conversation's auto-summary (first message), **not** the workspace name. So resume a cmux-born session by **reopening its workspace**; use `claude --resume` only for sessions started *outside* cmux (e.g. migrating one in from tmux).

## Common mistakes

| Mistake | Fix |
|---|---|
| Reading the first `capture-pane` after a keystroke and acting on it | Re-capture until the screen reflects your action; the TUI lags |
| Sending prompt text and Enter in one `send-keys` | Separate them; confirm the text landed before submitting |
| Multi-line prompt typed with `send-keys` (submits early) | Bracketed paste (`set-buffer`/`paste-buffer -p`), then one Enter |
| Foreground `sleep` to wait for the answer | Background/standalone poll on screen-stability (foreground sleep is blocked in some harnesses) |
| Using `--print`/`exec` and expecting a persistent, context-loaded session | Those are headless one-shots; drive the real TUI for cold-start / interactive work |
| Driving a TUI for batch code you'll review from a diff | That's dispatch — use the coding-dispatch scripts instead |
| (cmux) Blind `paste-buffer` then `send-key Enter` right after boot | Confirm a prompt fragment is on screen first — a TUI's input warms up a beat after the screen goes static, so the paste can vanish |
| (cmux) `Failed to write to socket (Broken pipe)` | You're outside the live cmux instance — run/resume the driver inside it (see `references/driving-over-cmux.md`) |
| (cmux) Targeting a session with a bare `--workspace <N>` integer | That's a positional **index** that shifts as workspaces open/close/reorder — it silently hits the WRONG session (or errors "index not found"). Resolve once with `cmux workspace list --id-format both`, then pass the stable **`workspace:<N>` ref** (or UUID); confirm via `read-screen` of the statusline before `send`. |

## Real-world basis

Proven 2026-06-01 driving cold `claude`, `codex`, and `agy` sessions to validate that `AGENTS.md` is the
universal front-door (codex + agy read it natively; only Claude needs `CLAUDE.md`→`@AGENTS.md`), and to
confirm a repo's bootstrap auto-loads at ~4% context. Every mechanic above is a scar from that run.

The **cmux path** was added + validated 2026-06-01 by driving a real `claude` (Opus 4.8) session *inside*
cmux end-to-end — paste a multi-line prompt as one block, submit, read `CMUX-DRIVE-OK` back — after the
**confirm-landed loop** fixed a vanished-paste-into-a-not-yet-ready-input bug that the first drive surfaced
(the boot-settle reported ready while claude's input was still warming up). The in-instance-trust gotcha is
also a scar: a session orphaned from a quit cmux instance could not drive the new one until resumed inside it.
