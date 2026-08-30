# Per-Agent Boot Interstitials (The Traps Are Agent-Specific)

Part of the driving-agent-sessions skill.

---

| Agent | At boot, before you can type | Notes |
|---|---|---|
| **Claude Code** (`claude`) | Ready quickly; just the render-lag discipline. | Loads `CLAUDE.md` + the repo's memory namespace. The cold-start gold standard. |
| **codex** | First run: an **"Update available"** screen (arrow to **Skip** — do *not* run option 1's `npm install -g`) then a **model offer** (pick **Use existing model** to keep the model your config already pins). | Reads `AGENTS.md` natively. If your `~/.codex/config.toml` blanket-`trusted`s a parent directory, repos under it get no per-project trust prompt; a repo outside it will prompt. Never pin `-m`/`-c`. |
| **agy** (Antigravity / Gemini) | A **folder-trust prompt** ("Do you trust the contents of this project?" — Enter confirms **Yes**), then the `>` input. | Reads `AGENTS.md` natively (no `GEMINI.md` needed). `agy --print` is **unreliable** (hangs) — drive the interactive TUI. Kill leftover `[a]gy` procs if calls stall. |
