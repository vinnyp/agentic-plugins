# Operating rules and troubleshooting

The conventions the exit codes assume you follow, and how to read the failures when they don't.
The per-command exit-code tables live in the [command reference](commands.md).

## Operating rules

These are the rules the exit codes assume you are following. They are not enforced by code.

**The 3-strike rule.** Count consecutive exit-1s from `coding-dispatch.sh` for the same task.
After three, stop delegating it and do it yourself. A fourth attempt on a task the agent has
failed three times is almost always cheaper to write by hand — and the failures are usually the
brief's fault, not the agent's.

**Distinguish blocked from failed.** Exit 5, 6, 7 and 124 are *environment* conditions, not build
failures. Do not count them toward the 3 strikes and do not retry them as builds: fix auth, wait
for the limit to reset, or raise the timeout.

**The dirty-tree rule.** Never dispatch into a shared checkout without `--worktree`. If you are
not certain the tree is clean and will stay clean for the whole dispatch, use `--worktree`. This
is the default posture for any repo more than one session touches.

**Verify commits after `DISPATCH=ok`.** `DISPATCH=ok` means the gates passed, not that the work is
committed — the contract is that the agent does *not* commit and you review the diff. But agents
sometimes commit anyway, and sometimes leave work uncommitted where you expected commits. After a
phase, check `git -C <worktree> log --oneline <base>..HEAD` and `git -C <worktree> status` before
merging. A stray self-commit with no valid marker is unwound automatically to uncommitted changes
for you to review — you will see a `stray commit` note when that happens.

**Set the full ship gate.** `--build-cmd` should be what the repo enforces at ship: lint *and*
tests. `coding-dispatch.sh` prints an advisory when your build command skips a `Makefile` target
named `pr-ready`/`check`/`ci`/`gate`/`lint`/`test`, or a `bin/run-tests.sh`-style runner it finds
in the repo. It will not pick one for you.

**Respect the review pin.** While a review is pinned, dispatches into that repo refuse with exit
9. That is the point — the reviewer is reading a specific HEAD. If a pin is left behind by a
killed review, `review-pin.sh release <workdir>` clears it, and it expires on its own after
`DISPATCH_REVIEW_PIN_TTL_SECS` (4h).

## Troubleshooting

**Start with the doctor.** `agent-dispatch-doctor` checks that every entrypoint is on PATH and
executable, that `lib/` is *not* on PATH, that codex and agy are present, that `agy models` works,
that the default agy model names still exist (if agy renames a model, `--model` fails silently at
dispatch time — this catches it), and that the entrypoints are shellcheck-clean.

**"agy not authenticated" (exit 7) when agy looks signed in.** Auth freshness is probed by a *live
call*, not by reading a token expiry — a token file can look valid while the session is not. Run
`agy` once interactively and sign in.

**agy headless appears to hang.** Headless agy settings must live at
`~/.gemini/antigravity-cli/settings.json`; `~/.gemini/settings.json` is silently ignored, and the
usual symptom is a headless run that never returns. Also check the model: a deep/slow model often
exceeds the default watchdog — raise `CODING_DISPATCH_TIMEOUT` or use a faster model. A wedged agy
may need `pkill -9 -f agy`.

**`DISPATCH=error: working tree not clean`.** The in-place revert net hard-resets to HEAD, so it
refuses to start on a dirty tree. Commit, stash, or use `--worktree`.

**`DISPATCH=refused: review pin active` (exit 9).** A review is pinned to this repo's HEAD. Wait
for it, or `review-pin.sh release <workdir>`. A pin left behind by a SIGKILLed review expires
after 4h, and any `status`/`pin` call removes a stale one.

**`DISPATCH=fail: empty diff`.** The agent changed nothing. Common causes: the brief was
unactionable; the agent planned and stopped (the agy preamble exists to prevent this); or it hit a
usage limit and exited 0 — check for exit 6 from `dispatch-worker`, or run it again and read the
output.

**A build gate fails that passes by hand.** Read the `gate-env: python=… ruff=…` line. The gate
runs with `<workdir>/.venv/bin` prepended when that directory exists; a global tool of a different
version is the usual culprit. `--no-venv` runs the gate with the PATH you launched with.

**`GATE_TREE_UNTRUSTWORTHY` (exit 2 from the gate).** Your build command `cd`'d into a different
repository, so its result says nothing about the one under dispatch.

**Where did my work go?** `git -C <repo> worktree list`. A failed dispatch salvages the diff in
the worktree by default; a removed worktree still leaves the patch under
`<parent-git-dir>/coding-dispatch-fail-patches/<slug>.patch`. See the rc table in each command's
section of the [command reference](commands.md) for which path applies.

**cmux: `Failed to write to socket (Broken pipe)`.** You are running outside the live cmux
instance. cmux grants socket trust only to processes running inside it — open a terminal inside
the running instance and invoke from there.

**A TUI drive reads stale or empty output.** That is render lag, not an empty reply. Both drive
scripts re-capture until the screen stabilises; if you are scripting a TUI yourself, never act on
the first capture after a keystroke, and never send prompt text and Enter in a single call.
