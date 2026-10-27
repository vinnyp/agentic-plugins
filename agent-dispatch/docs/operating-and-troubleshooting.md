# Operating rules and troubleshooting

The conventions the exit codes assume you follow, and how to read the failures when they don't.
The per-command exit-code tables live in the [command reference](commands.md).

A HUP, INT, or TERM to `coding-dispatch.sh` stops the worker before reverting or
salvaging changes and exits 143. With timeout available, escalation kills the worker's
process group after about five seconds. Without timeout, only the worker PID is signalled.
Both in-place and worktree modes defer a trapped signal during a foreground build gate
until that gate returns. A supervisor that escalates to SIGKILL during a long gate kills
the script without cleanup; the next in-place run then fails closed on the dirty tree.

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
at `bin/run-tests.sh`, `run-tests.sh`, or `scripts/test.sh` in the workdir.
Refusal applies only to runner files containing the exact signature line
`# agent-dispatch-run-tests: partial runs exit 4`. A simple command (split on
`&&`, `||`, `;`, or `|`) must invoke that runner and contain a whole `--only`
or `--changed` token (including `--only=…`). Nested paths such as
`agent-dispatch/bin/run-tests.sh` are checked relative to the workdir too.
The refusal exits 2 before agent launch and is never deduplicated. Other
runners receive a non-blocking, TTL-deduped `gate-target advisory` when their
command selects a partial gate. Quoted flag tokens are also recognized.
Whitespace-preceded shell comments are ignored. Flags on other commands do not
trigger refusal or a partial-gate advisory.
Use the full runner as the build gate.
It will not pick a gate for you.

**Respect the review pin.** While a review is pinned, dispatches into that repo refuse with exit
9. That is the point — the reviewer is reading a specific HEAD. If a pin is left behind by a
killed review, `review-pin.sh release <workdir>` clears it, and it expires on its own after
`DISPATCH_REVIEW_PIN_TTL_SECS` (4h).

## Troubleshooting

**Start with the doctor.** `agent-dispatch-doctor` checks that every entrypoint is on PATH and
executable, that `lib/` is *not* on PATH, that codex and agy are present, that `agy models` works,
that both pinned agy role models still exist (missing models fail loudly), and that the
entrypoints are shellcheck-clean. If preflight, dispatch-worker or the doctor reports a
missing model, run `agy models` and update `bin/lib/agy-models.sh`. Use `--model`/`MODEL`
on dispatch-worker or `AGY_MODEL` for coding as a validated one-off override.

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
unactionable, or the agent planned and stopped (the agy preamble exists to prevent this).
A capacity or limit failure now reports `DISPATCH=fail: agent unavailable` with exit 6,
including when the agent exits 0 without producing changes.

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

**codex empty diff / code-mode host timeout.** If even shell commands fail with
`timed out negotiating with the code-mode host`, codex may still exit zero and leave
an empty diff. Preflight now tests a real shell command and fails closed on this error,
including when a fallback writes the expected file. Run `codex-code-mode-host --help`
once to warm the helper, and check macOS quarantine/Gatekeeper on the codex cask
binaries. A recent reinstall may be involved, but quarantine is an unconfirmed cause.
`CODEX_EXEC_PROBE_TIMEOUT` raises the default `75s` bound for slow environments;
`CODING_PREFLIGHT_CODEX_PROBE=0` skips the probe for repeated scripted preflights.

Exit 9 is binary-specific: `dispatch-worker` means the agy model is not offered
(fix `bin/lib/agy-models.sh` or pass `--model`, then re-run);
`coding-dispatch.sh` and `coding-build-phase.sh` mean review-pin refusal.
An unparseable model list warns and skips validation. Model names are matched
case-insensitively; tierless IDs warn that agy chooses the tier.

**dispatch-worker broken install (exit 3).** Every runtime exits 3 when
`lib/repo-state.sh` or `lib/review-clone.sh` is missing. Run `agent-dispatch-doctor`
and repair the installation before retrying.

## Exit 10: the source repo changed during a review

Stop before committing. Read the named `config`, `hooks`, `commit`, `ref`, `worktree` and
`tree` change lines and the `DISPATCH_REVIEW_STATE` stderr line. Critical changes override
the runtime result; attribution to the reviewer or a concurrent session is not assumed.
A compare that cannot complete is also critical (rc 10).
Discard the review body unless every change is known concurrent work, restore unexpected
changes, and re-run. Values may be redacted, so compare with your known intended settings.

A `branch.*.remote` change is benign only when it names a remote present before the
review, or is `.` (the local repository). Known residual: a review run can still execute a planted `filter.*.clean`
during the after-snapshot's `git status`.

Known false-positive sources include `submodule.*` keys from a concurrent
`git submodule update --init`, `core.repositoryformatversion`/`extensions.*` writes,
a global write by `gh auth setup-git`, `gh pr checkout` of a fork PR (which writes a URL
into `branch.*.remote`), and a branch fetched directly from a URL or
fork PR (`gh pr checkout`) whose commits have another committer. Known blind spots
are commits pushed to a remote during the window and commits on a detached HEAD
in a source worktree.

For an accidental local key, use `git -C <repo> config --local --unset <key>` if it did not
previously exist, or `git -C <repo> config --local --replace-all <key> <intended-value>` to
restore it. Select the scope and origin named in the change line; restore all intended values
for multivalued keys. Inspect hooks separately and restore only known unintended edits.
After correcting identity, repair affected **unpushed** commits, from a clean feature branch:

```bash
git -C <repo> rebase --exec 'git commit --amend --no-edit --reset-author' <base>
```

This rewrites authors and commit IDs; identify the affected range and coordinate before
rewriting any shared history. Verify the resulting author and committer identities.

The clone reaper removes stale `dispatch-review-wt.*` clones older than six hours under the
resolved parent. The default `<repo-parent>/.worktrees` parent is shared by sibling repos,
so their stale clones may be removed too. Legacy linked worktrees are removed only through
the source repo's worktree command and left alone if that fails.
