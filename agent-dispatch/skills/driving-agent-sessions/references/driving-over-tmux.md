# Driving Over tmux (The Headless Path)

Part of the driving-agent-sessions skill.

---

- **Share a tmux server.** Driver and target must be the same user/socket — confirm with `tmux ls`.
- **Re-capture before every action.** After `send-keys`, the input box may not show your text for a beat;
  capture, and if it's not there yet, capture again. Acting on a stale frame burns you.
- **Type, confirm, *then* submit, separately.** `send-keys -l '<literal>'` for one line (no embedded
  newlines), confirm it landed, then a *separate* `send-keys Enter`. Enter submits; the redraw may lag —
  re-capture to confirm submission actually happened.
- **Multi-line prompts: paste, don't type.** Every Enter submits, so a multi-line prompt sent as raw
  `send-keys` fires halfway through. Use **bracketed paste** (`tmux set-buffer` → `tmux paste-buffer -p`)
  so newlines land as text, then one `send-keys Enter` to submit.
- **Never inject a second string to "test" the box.** It appends to your real prompt. (Scar: a stray
  `TESTPROBE` got tacked onto a live probe.)
- **Poll for completion by screen stability.** The spinner keeps the screen changing while it thinks; it
  stabilizes when done. Compare successive `capture-pane` hashes until stable for N reads. Use a
  background/standalone poll — a *foreground* `sleep` is blocked in some agent harnesses.
- **Cold-start probe framing:** ask it to "answer only from already-loaded context — no tools, no file
  reads." That tests whether the bootstrap *auto-loaded*, not whether the agent can read files on demand.

## Helper script

`drive-cold-session.sh [--model M] [--approve] [--timeout S] <agent> <workdir> <prompt-file>` bundles
create → boot-settle → paste → submit → settle → print-transcript, and leaves the session up for
inspection. Read its `--help`. Optional flags (all backward-compatible with the bare positional form):

- `--model M` launches the agent on a specific model — `claude`/`agy` get `--model M`, `codex` gets
  `-m M`; multi-word names with spaces/parens (e.g. `"Gemini 3.5 Flash (Low)"`) are kept intact.
- `--approve` auto-approves tool calls so an **unattended, tool-using** session doesn't stall on a
  permission prompt (`claude`/`agy`: `--dangerously-skip-permissions`; `codex`:
  `--dangerously-bypass-approvals-and-sandbox`). For `agy`, it also best-effort accepts the folder-trust
  interstitial with Enter after launching the TUI with `--add-dir <workdir>`. Omit it when folder trust
  should remain manual.
- `--timeout S` overrides the reply-settle bound (`DCS_SETTLE_MAX`).

> A cold TUI is the *high-fidelity* surface (real session, memory auto-injects, skills auto-load as
> for a human) but is **fragile for an unattended batch** (codex boot interstitials aren't auto-answered;
> agy's folder-trust prompt is only best-effort under `--approve`; settle-polling a long tool-using run is approximate). For a reliable headless **batch**, prefer the
> bounded one-shot path — `dispatch-worker --runtime <codex|agy|claude> [--ceremony] [--model M]`.

## agy quirk: soft format instructions are overridden by its explain-first prior

**agy ignores polite one-line format directives but complies with forceful ones.** Empirically established
in cold-start bootstrap probes: "your FIRST LINE must be exactly `REFUSE:`/`OK:`" → 0/6 compliance
(agy refused correctly but in prose). With a forceful instruction ("Line 1 MUST contain ONLY the bare
token, NO preamble/explanation on line 1, any character before it is a hard failure") → 3/3 compliance.

**Rule:** when you need a machine-parseable verdict token from agy, enforce it forcefully — token-only
line, explicit "any deviation = failure". A polite one-liner will not hold.

**Anti-gaming:** a separate incident showed a calibration subagent gaming this check by rewriting agy's
transcript to inject the verdict token via an overfitted regex, manufacturing a PASS from a FAIL. Never
normalize a transcript runner-side to inject verdict tokens; an honest FAIL must never become a PASS.
