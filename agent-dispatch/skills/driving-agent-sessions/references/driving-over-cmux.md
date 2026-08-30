# Driving Over cmux (The Visible Path)

Part of the driving-agent-sessions skill.

---

cmux is a GUI multiplexer with a **tmux-compatibility layer**, so the tmux mechanics port almost 1:1 — but
the session is a workspace the human can see and take over, and you can push progress to them.

## cmux ⇄ tmux command map

| Action | tmux | cmux |
|---|---|---|
| Create session running `<cmd>` | `tmux new-session -d -s <n> -c <dir> <cmd>` | `cmux workspace create --name <n> --cwd <dir> --command <cmd> --focus true` → returns `OK workspace:N` |
| Send literal text | `tmux send-keys -l '<text>'` | `cmux send --workspace <ref> '<text>'` |
| Submit | `tmux send-keys Enter` | `cmux send-key --workspace <ref> Enter` |
| Multi-line (one block) | `tmux set-buffer` + `paste-buffer -p` | `cmux set-buffer "$(cat f)"` + `cmux paste-buffer --workspace <ref>` |
| Read screen | `tmux capture-pane -p` | `cmux read-screen --workspace <ref>` (`--scrollback` for full history) |
| Topology | `tmux ls` | `cmux tree --all` |
| Close | `tmux kill-session` | `cmux workspace close --workspace <ref>` |

**`<ref>` means the stable `workspace:<N>` ref (or the UUID) — NOT a bare integer.** `--workspace 2` is a positional *index* that shifts as workspaces open/close/reorder, so it silently resolves to the wrong session (or errors "Workspace index not found"). Resolve the target once with `cmux workspace list --id-format both`, grab its `workspace:<N>` / UUID, pass THAT to every command, and confirm with a `read-screen` of the statusline (`sess:` / `📁`) before you `send`. (Scar: `--workspace 2` once read an unrelated pane while relaying to a different session; the ref `workspace:2` read the right one.)

## Re-capture discipline

The first `cmux read-screen` after a `send`/`paste` is often stale — re-read until the new content appears.
Poll completion by `read-screen` stability (hash with `cksum` until stable for N reads), background poll
(foreground `sleep` is blocked in some harnesses).

## Confirm the prompt landed before submitting

A TUI's input can be non-interactive for a beat *after* the screen goes static — its welcome box passes the
stability poll a moment before the input accepts text, so a blind `paste-buffer` **vanishes**. After pasting,
`read-screen` and verify a fragment of the prompt is visible; re-paste if not, then `send-key Enter`. (Scar:
a real claude drive submitted an empty prompt this way until the confirm-landed loop was added.)

## Long prompts: send a file-pointer, not a giant paste

`set-buffer`/`paste-buffer` can **truncate** a large paste — it silently dropped the *middle* of a ~2KB
multi-task brief once, so the driven agent got the start, lost the middle, and never saw the tail (and a
first-line confirm-landed check missed it). For a long prompt, **write it to a file and paste a short pointer**
— `cmux send "Read the instructions in <abs-path> and follow them."` — so the agent reads the full brief with
no paste-size risk. Reserve direct paste for short prompts and for **cold-start "no tools, no file reads"
probes** (which must be pasted verbatim — and are always short). `drive-cmux-session.sh` switches
automatically at ~1000 bytes / 8 lines.

## Watch-me-drive UX

Surface progress to the watching human:

- `cmux notify --workspace <ref> --title … --body …`
- `cmux set-status <key> <val>`
- `cmux set-progress <0..1>`
- `cmux trigger-flash`

Wrap each `|| true` — a notification hiccup must not abort the drive.

## In-instance trust (the cmux gotcha)

**cmux can only be driven from a process running *inside* the live cmux instance.** Under the default
`socketControlMode` (`automation`/`cmuxOnly`), the socket grants peer-credential trust only to in-instance
clients. A driver in a plain terminal, another app, or a session **orphaned from a quit/old cmux instance**
gets `Failed to write to socket (Broken pipe)` on every command. Fix: run (or `claude --resume`) the driving
session in a terminal inside the running cmux. `cmux ping` → `PONG` confirms you're trusted; the helper
hard-checks this at startup.

## Helper script

`drive-cmux-session.sh <agent> <workdir> <prompt-file> [name]` is the cmux sibling of
`drive-cold-session.sh` — same flow + env knobs, plus the in-instance `cmux ping` preflight, the
confirm-landed loop, and the watch-me-drive calls. `DCS_CLOSE=1` closes the workspace after printing.
