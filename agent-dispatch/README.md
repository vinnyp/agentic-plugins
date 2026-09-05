# agent-dispatch

**agent-dispatch hands a unit of work to another agent CLI and gives you back a verdict you can
trust.** You write a brief; it runs `codex`, `agy` (Antigravity/Gemini) or `claude` against a repo
under an external timeout, and hands back a classified result — with exit codes that tell an
out-of-credit account apart from a failing build. On the codex/agy coding path it wraps every run
in a preflight → timeout → completion-marker → **hard revert** safety net that hand-rolling
`codex exec` / `agy < brief` / `claude -p` does not give you. It can also *drive* a live agent TUI
over tmux or cmux when you need a real, persistent, watchable session instead of a one-shot.

It is for anyone who already runs coding agents from the shell and is tired of hand-rolling the
same safety wrapper: the timeout that the agent's own `--print-timeout` doesn't honour, the
"did it actually change anything?" check, the revert that doesn't eat a concurrent session's work,
and the exit code that tells an out-of-credit account apart from a failing build.

Installed Antigravity personas are reachable through
`dispatch-worker --runtime agy --agent NAME`. The wrapper validates `NAME` against `agy agent`
before launch, so a typo fails loudly instead of silently using the general assistant.

> ⚠️ **Read this before your first dispatch.** Dispatched agents run **as you — unsandboxed, with
> your filesystem, your on-disk credentials, and your network**. The coding path invokes
> `codex exec --dangerously-bypass-approvals-and-sandbox` / `agy --dangerously-skip-permissions`;
> there is no opt-out flag. The revert net covers the **git working tree of the target repo and
> nothing else** — files written outside it, packages installed, and requests sent are neither
> undone nor detected, and `dispatch-worker` (every `claude` dispatch) has no revert net at all.
> **If the repo is untrusted, run agent-dispatch inside a VM or container.** Full contract:
> [Safety and data flow](docs/safety-and-data-flow.md).

**How much net you get depends on the command.** This is the most important thing to know before
your first run:

| | `coding-dispatch.sh` / `coding-build-phase.sh`<br>(codex, agy) | `dispatch-worker`<br>(reviews, one-shots, `--ceremony` edits, **every** `claude` dispatch) |
|---|---|---|
| Runtime preflight | yes — `coding-preflight.sh` (codex and agy only; there is no claude branch) | agy only (an inline auth probe); none for codex or claude |
| External timeout | yes | yes |
| Build gate on the result | yes (`build-cmd`) | no |
| Completion marker checked | yes | no — the agy edit preamble asks the agent for one, but nothing reads it back |
| Scope gate (`--allow-path`) | yes | no |
| Hard revert on failure | yes | **no** |

So an edit through `coding-dispatch.sh` either leaves reviewable changes in the tree (or a salvaged
diff in `--worktree` mode) or hard-resets to the pre-dispatch commit. Anything through
`dispatch-worker` is bounded and classified, but **never reverted**: a partial or failed edit stays
exactly where the agent left it. See
[What this does NOT protect](docs/safety-and-data-flow.md#what-this-does-not-protect) for what a
git-level revert cannot undo.

It is **not** an agent, a model, or a sandbox. It does not write code, choose a model for you, or
contain the agent it launches.

## Requirements

`bash` 3.2+, `git`, and `jq` are needed for the core dispatch commands; `timeout`/`gtimeout` (GNU
coreutils — `brew install coreutils` on macOS) bounds every agent run, and **without it runs are
unbounded**. The agent CLIs (`codex`, `agy`, `claude`), `tmux`/`cmux` for the drive scripts,
`python3` for `run-long-gate.sh`, `shellcheck`, and a Go toolchain (for the `review-gate` CLI) are
each optional and needed only for their own feature. macOS and Linux are both supported. Full
per-command table: [Command reference → Requirements](docs/commands.md#requirements).

## Install

```bash
claude plugin marketplace add vinnyp/agentic-plugins
claude plugin install agent-dispatch@agentic-plugins
```

Then put the entrypoints on your `PATH` — they are ordinary shell scripts and are meant to be
callable by bare name from any project:

```bash
agent-dispatch-doctor --install     # symlinks every entrypoint into ~/.local/bin
```

`--install` is idempotent: it refuses to overwrite a real file or hijack another tool's command.
Verify with `agent-dispatch-doctor` (exit `0` all pass, `1` any FAIL, `2` any WARN). See
[`agent-dispatch-doctor`](docs/commands.md#agent-dispatch-doctor) for the full report and exit-code
contract.

## Quickstart

The single most common flow — one coding dispatch with a build gate, run in an isolated worktree:

```bash
coding-preflight.sh codex          # once per session, when you opt into a runtime

cat > /tmp/task.md <<'EOF'
Add a --json flag to cmd/report that prints the same summary as JSON.
Write the test first. Do NOT run git commit / git push / git add.
On success ONLY, write _coding-result.json in the repo root:
  {"status":"complete","files_written":["..."],"timestamp":"<ISO8601Z>"}
EOF

coding-dispatch.sh --worktree codex ~/code/myrepo /tmp/task.md "go test ./..."
```

On success you get `DISPATCH=ok …` and the changes are left **uncommitted** in the worktree for you
to review and land; on failure the diff is salvaged (or the tree hard-reset) and the pre-revert
patch path is printed. The other flows — a plan-driven build phase, a briefed peer review, and
driving a live tmux/cmux session — are documented per command in the
[command reference](docs/commands.md).

## Documentation

- **[Command reference](docs/commands.md)** — every entrypoint (`coding-dispatch.sh`,
  `coding-build-phase.sh`, `coding-preflight.sh`, `dispatch-worker`, `drive-cold-session.sh`,
  `drive-cmux-session.sh`, `agent-dispatch-doctor`, `run-long-gate.sh`, `gate-run.sh`,
  `mutation-verify.sh`, `review-pin.sh`, `ensure-review-gate.sh`, `review-gate`): synopsis, flags,
  exit codes, environment variables, artifact paths, plus the full requirements table.
- **[Safety and data flow](docs/safety-and-data-flow.md)** — what the revert net covers and what it
  does not, the dirty-tree refusal, and exactly what leaves your machine to which provider.
- **[The peer-review gate](docs/peer-review-gate.md)** — the tiered-review capability: the
  `running-the-peer-review-gate` skill and the `review-gate` CLI (brief / cross-model / log-new),
  and the cross-model egress disclosure.
- **[Worktree isolation](docs/worktree-isolation.md)** — why `--worktree`, where worktrees land,
  landing the work, salvage on failure, and pruning.
- **[Operating rules and troubleshooting](docs/operating-and-troubleshooting.md)** — the 3-strike
  rule, the dirty-tree rule, verifying commits after `DISPATCH=ok`, the review pin, and the failure
  playbook.

### Skills

- **`dispatching-into-a-worktree`** — isolate a coding dispatch's hard-revert from a shared checkout.
- **`validating-agent-bootstrap`** — verify a repo's cold-start context is actually sufficient.
- **`stubbing-external-agents-in-tests`** — stub `agy`/`codex`/`claude` so tests never spawn a real agent.

## Testing

```bash
bash bin/run-tests.sh
```

Runs every `bin/test-*.sh` suite in sorted order, then `shellcheck --severity=warning` over the
non-test entrypoints when shellcheck is installed. It fails fast on the first failing suite.

The suites **stub `codex`, `agy` and `claude` on `PATH`** and never launch a real agent — no
network, no tokens, no OAuth prompt. If you add a suite that shells `coding-dispatch.sh`,
`coding-build-phase.sh` or `dispatch-worker`, source `bin/lib/test-env-reset.sh` and call
`reset_dispatch_env` before the body, so an operator's exported `CODING_DISPATCH_TIMEOUT` (or any
other knob) cannot redden your suite; a completeness check fails if a new knob is added without
being registered there.

## Contributing

Issues and pull requests are welcome. Keep `bin/run-tests.sh` green, keep shellcheck clean at
`--severity=warning`, and add a test that fails when your change is reverted — the suite's
convention is to assert the observable effect (what the child process saw, what is on disk, what
the exit code was), not that a line of code exists.

## License

MIT.
