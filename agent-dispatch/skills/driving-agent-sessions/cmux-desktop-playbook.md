# cmux Playbook — Beginner to Agent-Driven Sessions

> You're brand new to cmux but you live in Claude Code and agents all day.
> This playbook gets you from zero to running observable, takeover-able agent sessions in one sitting.

---

## 1. What cmux Is

cmux is a macOS GUI terminal multiplexer — think iTerm2 split panes, but built from the ground up for
running multiple AI agents at once, with a browser pane baked in, a notification/feed sidebar,
and a control API that Claude can drive programmatically.

**Mental model:** everything nests in four levels.

```
┌─────────────────────────────── Window ──────────────────────────────────┐
│  ┌── Workspace (tab) ──┐  ┌── Workspace (tab) ──┐  ┌── Workspace ───┐  │
│  │                     │  │                     │  │                │  │
│  │  ┌─── Pane ──────┐  │  │ ┌──Pane──┐ ┌─Pane─┐│  │  ┌──Pane────┐  │  │
│  │  │ ┌─ Surface ─┐ │  │  │ │Surface│ │Surface││  │  │ Surface  │  │  │
│  │  │ │ (terminal)│ │  │  │ │(agent)│ │(shell)││  │  │ (browser)│  │  │
│  │  │ └───────────┘ │  │  │ └───────┘ └───────┘│  │  └──────────┘  │  │
│  │  │ ┌─ Surface ─┐ │  │  │                    │  │                │  │
│  │  │ │ (browser) │ │  │  │                    │  │                │  │
│  │  │ └───────────┘ │  │  │                    │  │                │  │
│  │  └───────────────┘  │  └────────────────────┘  └────────────────┘  │
│  └─────────────────────┘                                               │
│  [  Agent Driving  ] [  Multi-Agent  ] [  IDE  ]  ← workspace tabs     │
└─────────────────────────────────────────────────────────────────────────┘
```

| Term | What it is | Analogy |
|---|---|---|
| **Window** | The macOS app window | The whole browser window |
| **Workspace** | A named tab in that window | A browser tab |
| **Pane** | A split region inside a workspace | A split pane in iTerm2 |
| **Surface** | One tab inside a pane — terminal or browser | A tab within a split |

A single Pane can hold multiple Surfaces (tabbed inside it). When you're watching Claude run an agent,
you're looking at a Surface inside a Pane inside a Workspace.

---

## 2. Your First 5 Minutes

### Open the app

Launch cmux from Spotlight (`⌘Space` → "cmux") or your dock. You'll land on a default workspace —
probably one pane with a shell prompt.

### What you're looking at

```
┌──────────────────────────────────────────────────────────────────────┐
│  [cmux]  Agent Driving  +                            [sidebar icon]  │
│  ─────────────────────────────────────────────────────────────────── │
│                                                                      │
│   $                                                                  │
│   (your shell is here — this is a Surface inside a Pane)             │
│                                                                      │
│                                                                      │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
  ↑ workspace tab bar         ↑ pane area               ↑ sidebar toggle
```

- The **tab bar at the top** shows your workspaces. Click the `+` to open a new one.
- The **main area** is your pane/surface canvas.
- The **right sidebar** (toggle with `⌘B`) shows git status, running agents, notifications, ports.

### Open a workspace in a folder

```
1. Press ⌘N          — opens a new workspace
2. cd ~/Projects/my-project    — navigate like a normal terminal
3. claude             — start a Claude Code session right here
```

Or use the Command Palette (more on that below): press `⌘⇧P`, type "new workspace", and pick a folder.

### The four things to try in your first session

```
⌘N          → open a new workspace (new tab)
⌘W          → close a surface (close tab)
⌘⇧P         → Command Palette (search everything)
⌘B          → toggle the right sidebar
```

That's enough to get around. Everything else is below.

---

## 3. A Keyboard Shortcut Set

The bindings below are an example set, grouped by what each group is *for*. Yours may differ —
check your own `cmux.json`; the groups are the point, not the exact keys.

---

### Group 1: Workspace Navigation (the tab bar)
Jump directly to a workspace by its position number, or go to one by name.

| Key | Action |
|---|---|
| `⌘1` through `⌘9` | Jump to workspace #1–9 directly |
| `⌘⌥G` | Go to workspace by name (type to search) |
| `⌘N` | New workspace (opens a fresh tab) |
| `⌘⇧W` | Close current workspace |

**When to use:** You have 4 agents running in 4 workspaces. `⌘3` snaps you to workspace 3 instantly.

---

### Group 2: Surface / Pane-Tab Navigation
Each pane can hold multiple surfaces (tabbed terminals or browsers). These move between them.

| Key | Action |
|---|---|
| `⌘⌥1` through `⌘⌥9` | Jump to surface #1–9 in the current pane |
| `⌘⇧]` | Next surface (cycle forward) |
| `⌘⇧[` | Previous surface (cycle backward) |
| `⌘T` | New surface in current pane |
| `⌘W` | Close current surface |

**When to use:** You've got a terminal and a browser tabbed inside the same pane. `⌘⇧]` flips between them.

---

### Group 3: Pane Splits + Vim-hjkl Focus
Split your workspace and move focus between panes, vim-style.

| Key | Action |
|---|---|
| `⌘⌥V` | Split right (new pane to the right) |
| `⌘⌥S` | Split down (new pane below) |
| `⌘⌥Z` | Zoom/unzoom current pane (full-screen toggle) |
| `⌘⌥=` | Equalize split sizes |
| `⌘⌥H` | Focus pane to the left |
| `⌘⌥J` | Focus pane below |
| `⌘⌥K` | Focus pane above |
| `⌘⌥L` | Focus pane to the right |

**When to use:** You've got a 3-pane layout. `⌘⌥L` jumps focus to the right pane without touching the mouse.
`⌘⌥Z` zooms in on one pane to read it, then unzooms back to the full layout.

```
┌──────────┬──────────┐   ⌘⌥H/L →   ┌──────────┬──────────┐
│          │          │               │ ← focus  │  focus → │
│  pane:1  │  pane:2  │   ⌘⌥J/K ↕    │          │          │
│          │          │               │          │          │
└──────────┴──────────┘               └──────────┴──────────┘
```

---

### Group 4: Agent Triage / Notifications
This is the group you'll use the most as an agent power user.
cmux tracks which workspaces have activity or unread output from running agents.

| Key | Action |
|---|---|
| `⌘J` | Jump to the next workspace with unread agent activity |
| `⌘⇧J` | Mark oldest unread + jump to next (triage mode) |
| `⌘U` | Show the notifications panel |
| `⌘⌥U` | Toggle unread status on current workspace |
| `⌘⇧H` | Trigger a flash on the current surface (visual attention cue) |

**When to use:** You've dispatched 5 agents. `⌘J` bounces you to whoever just finished. `⌘⇧J` lets you
triage them one by one — each press marks one done and jumps you to the next.

---

### Group 5: Right Sidebar

| Key | Action |
|---|---|
| `⌘B` | Toggle the right sidebar open/closed |
| `⌘⇧E` | Focus the right sidebar (navigate it with keyboard) |

**When to use:** The sidebar shows git status, open ports, agent session list, and log tails. Hide it when
you need the full canvas width; `⌘B` brings it back.

---

### Group 6: App Settings

| Key | Action |
|---|---|
| `⌘,` | Open cmux Settings UI |
| `⌘⇧,` | Reload your config file (no restart needed) |

**When to use:** `⌘⇧,` is your "I just edited cmux.json, pick it up now" shortcut. Instant.

---

## 4. The 5 Workspace Layouts

These are pre-built pane arrangements you can launch from the Command Palette (`⌘⇧P`), the `+` button
tab context menu (right-click the `+`), or from the surface tab bar quick-launch buttons.

---

### Layout 1: Agent Driving

```
┌─────────────────────┬───────────────────┐
│                     │                   │
│   Agent terminal    │   Your shell      │
│   (claude / codex)  │   (watch / run    │
│                     │    commands)      │
│                     │                   │
└─────────────────────┴───────────────────┘
         pane:1               pane:2
```

**When:** You want to run one agent and keep a shell nearby to check output, run tests, or inspect files.
The agent is in the left pane; your hands stay in the right.

**Launch:** `⌘⇧P` → type "agent driving" → Enter.

---

### Layout 2: Agent + Monitor

```
┌──────────────────┬─────────────────────┐
│                  │                     │
│  Agent terminal  │   cmux Feed TUI     │
│  (claude)        │   (notifications,   │
│                  │    activity stream) │
│                  ├─────────────────────┤
│                  │   Your shell        │
│                  │                     │
└──────────────────┴─────────────────────┘
      pane:1              pane:2 + pane:3
```

**When:** You're running one agent but want a live feed of everything happening — other agents, git events,
port activity — alongside it. The Feed TUI is a built-in cmux panel (`cmux feed tui`).

**Launch:** `⌘⇧P` → type "agent monitor" → Enter.

---

### Layout 3: Multi-Agent

```
┌──────────────────────┬──────────────────────┐
│                      │                      │
│   Claude Code        │   Codex              │
│   (pane:1)           │   (pane:2)           │
│                      │                      │
│                      │                      │
└──────────────────────┴──────────────────────┘
```

**When:** You want two agents running side by side — Claude on the left, Codex on the right — so you can
watch both at once. Common for parallel work on independent tasks.

**Launch:** `⌘⇧P` → type "multi-agent" → Enter.

---

### Layout 4: IDE

```
┌──────────────────────┬──────────────────────┐
│                      │  lazygit (git UI)    │
│   Agent terminal     ├──────────────────────┤
│   (claude)           │  Shell / commands    │
│                      │                      │
└──────────────────────┴──────────────────────┘
         pane:1               pane:2 + pane:3
```

**When:** You want an IDE-style layout: agent on the left, lazygit for git staging/commit in the top-right,
a plain shell in the bottom-right for running builds and tests. Closest to a full development environment.

**Launch:** `⌘⇧P` → type "ide" → Enter.

---

### Layout 5: Agent + Browser

```
┌──────────────────────┬──────────────────────┐
│                      │                      │
│   Agent terminal     │   Embedded browser   │
│   (claude)           │   (cmux webview)     │
│                      │                      │
│                      │                      │
└──────────────────────┴──────────────────────┘
         pane:1               pane:2
```

**When:** The agent is doing something web-facing — scraping, testing a local server, reviewing docs —
and you want to see the browser alongside the agent in the same workspace. Links clicked in the terminal
automatically open in the right pane.

**Launch:** `⌘⇧P` → type "agent browser" → Enter.

---

## 5. How Claude Drives a Session You Can Watch (watch-me-drive)

This is the part that makes cmux special for agent work.

### The idea

When you ask Claude (me) to run an agent task, instead of just firing it in the background and reporting
back with text, Claude can:

1. **Create a new workspace** in your running cmux app
2. **Start the agent there** (e.g., `claude` in a project directory)
3. **Send the prompt** to that agent programmatically
4. **Post progress updates** to you as the agent works (notifications, status bar, a flash when done)
5. **Leave the workspace open** so you can scroll up, read the output, or jump in and take over anytime

You watch it happen in real time. At any moment you can click into the workspace and just start typing.

### What it looks like from your side

```
┌─────────────────────────────────────────────────────────┐
│  ● Agent Driving  ● claude/my-task  +                   │
│  ──────────────────────────────────────────────────────  │
│                                                          │
│  > claude --resume                                       │
│  Resuming session...                                     │
│  [agent output scrolling here in real time]              │
│                                                          │
│                         ← you can click here + type ──→  │
└─────────────────────────────────────────────────────────┘
  ↑ new workspace Claude created        ↑ live agent output
```

The notification sidebar (`⌘U`) will show a progress indicator. When the agent finishes (or needs input),
you'll see a flash on the workspace and a notification.

### The helper script

`drive-cmux-session.sh` is what Claude uses under the hood:

```bash
# Claude calls something like this on your behalf:
drive-cmux-session.sh claude ~/Projects/my-repo prompt.txt "my-task"
```

It handles:
- Creating the workspace with the right working directory
- Verifying the agent started cleanly before sending the prompt
- Confirming the prompt actually landed (not dropped into a loading screen)
- Sending `notify` / `set-status` / `set-progress` calls so the progress bar updates
- Leaving the workspace open when done (or closing it if you set `DCS_CLOSE=1`)

### The one gotcha you need to know

**Claude can only drive cmux from inside cmux.**

Under the hood, cmux uses a local socket, and that socket only trusts processes that are running *inside*
the live cmux instance. If Claude's session is running in a regular Terminal.app window, a detached tmux,
or an old cmux instance that was quit and relaunched, every `cmux` command will fail with:

```
Failed to write to socket (Broken pipe)
```

This is not a bug — it's a security feature. The fix is simple:

```
1. Make sure you're running Claude Code inside a cmux terminal surface
2. To check: run  cmux ping  in the terminal where Claude is running
3. If it responds  PONG  — you're good, Claude can drive sessions
4. If it says "Broken pipe" — open a new cmux workspace, start Claude there, try again
```

In practice: when you start a `claude` session inside cmux, you're already trusted. The gotcha usually
bites if you're driving Claude from an external tool or a terminal outside cmux.

---

## 6. Agent Hibernation, Fork-to-Tab, and Quit Safety

### Agent hibernation

If you open a bunch of agent workspaces and walk away, cmux can automatically hibernate terminals that
have been idle for a while, keeping only a few live terminals at a time. Hibernated sessions don't
consume resources but their output is still there when you come back — scroll up, press any key, and
they wake up. The relevant config keys (example values):

```
idleSeconds: 1800        # hibernate after 30 idle minutes
maxLiveTerminals: 8      # keep at most 8 terminals live
autoResumeAgentSessions: true
```

Set them once and forget them. Long overnight agent runs won't leave 20 live processes burning CPU
while you sleep.

### Fork-to-new-tab

When you use cmux's "fork conversation" feature (duplicating a workspace to continue from the same
state), you can have the fork open in a **new tab** instead of splitting the current workspace. That
preserves your layout — a carefully arranged Agent Driving or IDE split doesn't get smashed when you
fork.

### Quit safety (dirty-only)

With `confirmQuit: "dirty-only"`:

- **If no agents are running** → `⌘Q` quits cleanly, no dialog.
- **If agents are actively working** → cmux asks "are you sure?" before quitting.

You won't accidentally nuke a running agent by fat-fingering `⌘Q`, and you also won't get pestered with
a quit dialog every single time you close the app when nothing important is running.

---

## 7. Coming back to a workspace (and what closing does)

Closing a workspace does **not** lose your work — Claude always saves the conversation to disk, and cmux tracks the session as restorable. But the friction-free way to "come back later" is to **not close it**. Three cases:

| What you do | What happens | How to get back |
|---|---|---|
| **Switch away** (`⌘1`–`9`, or click another tab) | Workspace stays; after ~30 min idle it *hibernates* (frees resources), session intact | Just switch back — it wakes. Nothing to recover. |
| **Quit / relaunch cmux** (or update / crash) | cmux **auto-restores** your open workspaces *and* their agent sessions (`autoResumeAgentSessions` re-runs `claude --resume <id>`) | Nothing to do — they come back on relaunch |
| **X the tab** (close the workspace) | You get a confirm first (`warnBeforeClosingTab`); the live agent process ends and the tab is gone — **but the conversation persists on disk** | Open a new workspace in the same project folder and run `claude --resume` (pick the session), or check the **Sessions** sidebar (`⌘B` → sessions). This is the *only* case where `claude --resume` is the right tool. |

**Rule of thumb:** to step away and return, **switch tabs — don't X.** It hibernates, waits, and survives a cmux relaunch. X-ing is recoverable too (the transcript is always on disk — resume it with `claude --resume`), just an extra step. And recall from §5: the workspace *name* is the in-cmux handle; claude's native `--resume` picker lists sessions by their conversation summary, not the workspace name.

---

## 8. Editing / Reverting Your Config

### Where the config lives

```
~/.config/cmux/cmux.json
```

This is the single source of truth. Open it in VS Code with `cmux settings cmux-json`, or directly:

```bash
code ~/.config/cmux/cmux.json
```

### Reloading after changes

You **do not need to restart cmux** after editing the config. Just reload:

```bash
cmux reload-config
```

Or press `⌘⇧,` from inside any cmux workspace. Changes take effect immediately — shortcuts, layouts,
notification settings, everything.

### Reverting to the previous config

If a timestamped backup was made when the config was last applied, it sits next to it:

```
~/.config/cmux/cmux.json.YYYYMMDD-HHMMSS.bak
```

To revert:

```bash
# List your backups
ls ~/.config/cmux/*.bak

# Pick the one you want and restore it
cp ~/.config/cmux/cmux.json.YYYYMMDD-HHMMSS.bak ~/.config/cmux/cmux.json
cmux reload-config
```

If something feels broken after a config change, this is the escape hatch. The `.bak` file is yours —
cmux never touches it.

---

## Quick Reference Card

```
WORKSPACE NAVIGATION
  ⌘1–9         Jump to workspace by number
  ⌘⌥G          Go to workspace by name
  ⌘N           New workspace
  ⌘⇧W          Close workspace

SURFACE / PANE-TAB NAVIGATION
  ⌘⌥1–9        Jump to surface by number
  ⌘⇧]  ⌘⇧[    Next / Previous surface
  ⌘T           New surface in pane
  ⌘W           Close surface

PANE SPLITS + FOCUS
  ⌘⌥V          Split right
  ⌘⌥S          Split down
  ⌘⌥Z          Zoom/unzoom pane
  ⌘⌥=          Equalize splits
  ⌘⌥H/J/K/L    Focus left/down/up/right

AGENT TRIAGE
  ⌘J           Jump to next unread agent
  ⌘⇧J          Mark + jump (triage mode)
  ⌘U           Show notifications
  ⌘⌥U          Toggle unread on current
  ⌘⇧H          Flash current surface

SIDEBAR + APP
  ⌘B           Toggle sidebar
  ⌘⇧E          Focus sidebar
  ⌘,           Open settings UI
  ⌘⇧,          Reload config

LAYOUTS (⌘⇧P → type the name)
  Agent Driving      2-pane: agent + shell
  Agent + Monitor    3-pane: agent + feed + shell
  Multi-Agent        2-pane: Claude + Codex
  IDE                3-pane: agent + lazygit + shell
  Agent + Browser    2-pane: agent + browser
```
