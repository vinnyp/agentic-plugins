# Evals — driving-agent-sessions

**Type:** decision/application evals (`evals.json`, no fixtures) + trigger evals (`trigger-evals.json`).

**Why this shape:** the skill is a technique for driving a *real* interactive agent TUI (claude/codex/agy)
over tmux — a how-to whose value is in the hard-won mechanics and one sharp boundary. The harness can't run
live tmux, so each eval is a self-contained scenario and the agent's *approach* is graded from the
transcript against `expectations`. The discriminators are exactly the things a capable baseline gets wrong:

- **Re-capture before acting** — the TUI redraws on a lag, so the first `capture-pane` after a keystroke is
  stale. Baselines treat the TUI like a request/response API (evals 1, 2).
- **The dispatch-vs-interactive-drive boundary** — a ~200-line refactor is *fire-and-forget coding* (the
  deterministic dispatch scripts with git-revert + marker), NOT a case for hand-driving a TUI. A baseline happily
  drives the TUI because it was asked to (eval 3). This is the skill's single most load-bearing decision.
- **codex boot interstitials** — Skip the update (don't run the npm global install), keep the model the
  config already pins, and know that a blanket-trusted parent directory suppresses the trust prompt (eval 4).
- **agy `--print` unreliability + folder-trust** — `--print` hangs / a stale shared session swallows calls;
  drive the TUI; bound any headless call with an *external* `timeout -k` (eval 5).
- **Multi-line via bracketed paste + screen-stability polling** — each Enter submits, so raw `send-keys`
  fires early; paste the block then one Enter; detect done by stability, with a background poll because a
  foreground `sleep` is blocked in some harnesses (eval 6).

**Trigger evals:** 6 should-trigger (verify-cold-load / drive-codex / type-into-agy / probe-auto-load /
stale-tmux-output / steer-interactive) + 6 near-misses that pin the boundary — fire-and-forget codex
dispatch, agy-write-a-function, generic tmux pane setup, AGENTS.md content coverage
(that is a bootstrap-authoring question, not a session-driving one), `claude --print` one-shot,
and CLI installation.

**How to run:** output evals are a with-skill vs baseline benchmark on leak-safe prompts, graded against
each scenario's `expectations`; trigger evals check the description fires on the should-trigger queries and
stays quiet on the near-misses.

**The helper script (`drive-cold-session.sh`) is validated separately** — end-to-end against a fake
TUI agent (create → boot-settle → bracketed-paste → submit → screen-stability settle → capture), confirming
the polling/paste/capture mechanics work independent of the decision evals.

**cmux additions (2026-06-01).** When the skill grew a cmux surface, evals 7-10 were added: surface choice
(pick cmux when a human should watch/co-drive), the in-instance "broken pipe" trust gotcha, the
confirm-landed vanished-paste timing bug, and the cmux command mapping. Re-benchmarked the full 10-eval
suite: **42/42 with-skill vs 9/42 baseline**, with the four cmux evals at **16/16 vs 0/16** — the baseline
reaches for tmux on a watch scenario, misdiagnoses the broken pipe as a stale socket, fixes the vanished
paste with sleep+grep instead of the confirm-landed loop, and gets the cmux command syntax wrong; every cmux
fact is skill-carried. The with-skill executor read SKILL.md **plus its `references/`** (progressive
disclosure) — the lean-SKILL + reference split cost zero points. `drive-cmux-session.sh` was
validated end-to-end against a real `claude` session inside cmux (it replied `CMUX-DRIVE-OK`), which is what
surfaced the confirm-landed bug now baked into the helper. Trigger-evals add 2 cmux should-trigger
(drive-in-cmux-to-watch, cmux broken-pipe) + 2 near-misses (cmux layout/shortcut setup, which is cmux
configuration; and `claude-teams`, which is native multi-agent orchestration, not single-session
interactive driving).
