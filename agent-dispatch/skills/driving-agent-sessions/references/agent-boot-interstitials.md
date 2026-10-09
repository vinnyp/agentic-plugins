# Per-Agent Boot Interstitials (The Traps Are Agent-Specific)

Part of the driving-agent-sessions skill.

---

| Agent | At boot, before you can type | Notes |
|---|---|---|
| **Claude Code** (`claude`) | In an untrusted folder, a dialog asks **"Is this a project you created or one you trust?"** or **"Do you trust the files in this folder?"** Its default choice exits Claude. `drive-cold-session.sh` exits 4 before sending the prompt; trust the folder manually or run Claude once interactively. `DCS_KILL=1` removes the session. Never auto-accept: doing so writes to the user's Claude configuration. | Loads `CLAUDE.md` + the repo's memory namespace. |
| **codex** | First run: an **"Update available"** screen (arrow to **Skip** — do *not* run option 1's `npm install -g`) then a **model offer** (pick **Use existing model** to keep the model your config already pins). When a background codex daemon is already running with different features, a **"Background server has incompatible feature settings"** or **"Cannot use the background server"** screen appears, and its default choice may be **Cancel**, so a blind Enter quits codex. Pick **Run without daemon this time**, never the option that restarts the shared daemon. `drive-cold-session.sh` exits 4 on daemon, update-choice (`Update now` and `Skip`), and model-offer screens before pasting, leaving the session up for a human unless `DCS_KILL=1`. A bare update banner does not stop the driver. | Reads `AGENTS.md` natively. If your `~/.codex/config.toml` blanket-`trusted`s a parent directory, repos under it get no per-project trust prompt; a repo outside it will prompt. Never pin `-m`/`-c`. |
| **agy** (Antigravity / Gemini) | A **folder-trust prompt** ("Do you trust the contents of this project?" — Enter confirms **Yes**), then the `>` input. | Reads `AGENTS.md` natively (no `GEMINI.md` needed). `agy --print` is **unreliable** (hangs) — drive the interactive TUI. Kill leftover `[a]gy` procs if calls stall. |
