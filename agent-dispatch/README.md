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

Coding dispatch refuses build commands that invoke a detected runner with `--only`
or `--changed` in the same simple command, exiting 2 before agent launch only
when the runner carries the `agent-dispatch-run-tests: partial runs exit 4` signature.
Other runners receive a TTL-deduped advisory for partial flags in the same simple
command. Quoted flags count; shell comments and flags on subsequent commands do
not select a partial gate. Use the full runner as the build gate.

**Review workspaces.** agy reviews use a disposable private clone with mirrored refs,
private global Git config; origin's fetch and push URLs point at a disabled path.
Other remotes and the operator's credential helper remain reachable, so the drift check,
not the clone, detects source changes. Unsuitable repos fall back to the live
workspace with permissions enforced. Every runtime's review checks source state before and after;
critical drift exits 10 and stops the review gate. Inspect and restore the named changes before
committing, then re-run. See [the command reference](docs/commands.md#dispatch-worker).

Comparison rejects malformed snapshot headers and NUL bytes, and reports failed input
feeds as input errors. Repository-state snapshots hash sensitive config values and replace URL userinfo
in config keys with the first 12 hex digits of its SHA-256 digest. Credentialed
keys remain distinct for change detection; change reports omit the userinfo.

Review drift checks hash Git exclude, attributes, and alternates files. Snapshots and change lists stay in dispatcher shell memory; on-disk
tampering cannot replace captured verdict data.

See the drift gate’s [limits](docs/commands.md#limits) for the write boundary it does not provide.

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

Codex preflight now verifies a real shell-tool invocation in a disposable cache
repository before reporting ready. Shell failures and hangs fail closed; see the
[preflight command reference](docs/commands.md#coding-preflightsh) for timeout,
opt-out, and code-mode-host troubleshooting.

So an edit through `coding-dispatch.sh` either leaves reviewable changes in the tree (or a salvaged
diff in `--worktree` mode) or hard-resets to the pre-dispatch commit. Anything through
`dispatch-worker` is bounded and classified, but **never reverted**: a partial or failed edit stays
exactly where the agent left it. See
[What this does NOT protect](docs/safety-and-data-flow.md#what-this-does-not-protect) for what a
git-level revert cannot undo.

On INT/TERM, `coding-dispatch.sh` stops its worker before cleanup and reports
`DISPATCH=fail: interrupted (signal)`. HUP is handled alongside INT/TERM; with timeout
available, cleanup escalates TERM to KILL for the worker process group after about five seconds.
Foreground build gates defer trapped signals until they return. In-place changes are reverted unless
`--keep-on-fail` applies or the worker committed changes; worktree changes and
commits are salvaged with a failure patch. Fresh empty worktrees are removed.

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

Mutation sweeps refuse shell operators during argument parsing, allow a five-second
child-exit grace, and report leftover processes as errors. Missing results take
precedence over errors. See [command details](docs/commands.md#mutation-sweepsh)
for timeout, capture-storage, and isolation limits.

Mutation tree fingerprints use portable permission bits with GNU and BSD stat;
mtime and ownership checks use the same shared stat dialect detection. Special
permission bits are excluded from fingerprints. `mutation-verify.sh` supports
symlinked entrypoints and refuses to run when its required stat helper is missing.

## Documentation

- **[Command reference](docs/commands.md)** — every entrypoint (`coding-dispatch.sh`,
  `coding-build-phase.sh`, `coding-preflight.sh`, `dispatch-worker`, `drive-cold-session.sh`,
  `drive-cmux-session.sh`, `agent-dispatch-doctor`, `run-long-gate.sh`, `gate-run.sh`,
  `mutation-verify.sh`, `mutation-sweep.sh`, `review-pin.sh`, `review-log-status`, `ensure-review-gate.sh`, `review-gate`): synopsis, flags,
  exit codes, environment variables, artifact paths, plus the full requirements table.
  Copy-mode sweeps bound each mutant with `--timeout` and report errors separately
  from inconclusive exits 1/3; exit 0 means every mutant was measured without errors.
- **[Safety and data flow](docs/safety-and-data-flow.md)** — what the revert net covers and what it
  does not, the dirty-tree refusal, and exactly what leaves your machine to which provider.
- **[The peer-review gate](docs/peer-review-gate.md)** — the tiered-review capability: the
  `running-the-peer-review-gate` skill and the `review-gate` CLI (brief / cross-model / log-new),
  and the cross-model egress disclosure. Measurement-shaped changes require a design
  note and resolved design round before building, recorded with `log-new --design-round`.
  Three modes: `build` (a diff, post-build) and `design` (a
  spec/design doc, pre-build) each run to a single completed gate within this skill; `requirements`
  (a PRD/requirements doc) runs exactly **one round per invocation** — the multi-round loop
  (fences, owner adjudication, delta verification, lock) belongs to the caller:
  `operator-agents:writing-prds`, or `operator-agents:writing-agent-prds` for an agent PRD.
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

Each top-level runner checks `ps` availability against its own PATH, including
nested runs. Internal suite wrappers inherit that invocation’s cached result.

Runs every `bin/test-*.sh` and `test/*.sh` suite in parallel by default, then
`shellcheck --severity=warning` over the non-test entrypoints when installed. Use `-j <jobs>`
to set concurrency and `--changed` or `--only <suite>[,<suite>...]` to iterate on a subset.
A passing partial run exits 4 and is never the gate; run the full gate before each review
round and before handing back. Suites allow surviving children 5 seconds to exit
before reporting a process leak. See [run-tests.sh](docs/commands.md#run-testssh) for selection,
timeouts, exit codes, and reporting.

The suites **stub `codex`, `agy` and `claude` on `PATH`** and never launch a real agent — no
network, no tokens, no OAuth prompt. If you add a suite that shells `coding-dispatch.sh`,
`coding-build-phase.sh` or `dispatch-worker`, source `bin/lib/test-env-reset.sh` and call
`reset_dispatch_env` before the body, so an operator's exported `CODING_DISPATCH_TIMEOUT` (or any
other knob) cannot redden your suite; a completeness check fails if a new knob is added without
being registered there.

Passing full and partial runs remove their run directory unless `RUN_TESTS_KEEP_LOGS=1`.
The runner prints sorted per-suite timings, counts, slowest suites, failure logs,
then lifted `SKIP` lines, shellcheck (full only), total wall time, and a final
`GATE PASS:`, `GATE FAIL:`, or `PARTIAL RUN:` line. See the command reference for
`NOT RUN`, `FAIL (no result)`, usage, and the changes from the previous runner.

See [changes from the previous runner](docs/commands.md#changed-from-the-previous-runner)
for the compatibility changes.

Interrupted runs end with `INTERRUPTED: …` then `Total wall:` and no verdict line.
TIMEOUT/KILLED indicate enforced limits; suites leaving children running fail with
`FAIL <suite> (exited N; left processes running)`.

## Contributing

Issues and pull requests are welcome. Keep `bin/run-tests.sh` green, keep shellcheck clean at
`--severity=warning`, and add a test that fails when your change is reverted — the suite's
convention is to assert the observable effect (what the child process saw, what is on disk, what
the exit code was), not that a line of code exists.

agy role defaults live in [`bin/lib/agy-models.sh`](bin/lib/agy-models.sh): coding uses
Flash Medium and review uses Argon High. Preflight and dispatch-worker validate the
effective model against live `agy models`; the doctor checks both pins. On drift,
run `agy models` and edit that file, or use `--model`/`MODEL` on dispatch-worker or
`AGY_MODEL` for coding as a one-off override. Inconclusive auth probes warn and skip
the model check. See [commands](docs/commands.md) for details.

The codex preflight shell probe hashes a nonce in a private cache repository and
reports `CODEX_EXEC_PROBE=ok|inconclusive|skipped`. Its default bound is 75s plus
a 10s kill grace; see [commands](docs/commands.md) for overrides and
[data flow](docs/safety-and-data-flow.md) for provider context and retained artifacts.

The codex shell probe requests the digest tool available on PATH (`shasum -a 256`
or `sha256sum`) and cleans up on HUP, INT, or TERM. If its cache directory has
unsafe permissions, set that directory to mode 700 as shown in the diagnostic.
Model overrides may omit only the final hyphen segment of an offered ID (normally
its tier), e.g. `gemini-4-argon` for `gemini-4-argon-high`. With today's IDs,
`gemini` or `gemini-4` match nothing.

## License

MIT.

The standalone command handles INT, TERM and HUP promptly, removes its temporary state,
and leaves interrupted snapshots unreadable. Completion records must agree with the
bounded child’s exit status; scripts reach the child through a pipe. Compare and
snapshot data stay in memory and return through an unlinked result channel.

Review drift snapshots and the standalone `repo-state-check` are bounded
(`DISPATCH_SNAPSHOT_TIMEOUT_SECS` overrides the limit; default 120 seconds for
`dispatch-worker`, 60 for `repo-state-check`). Normal snapshots return immediately; the bound uses coreutils
`timeout`/`gtimeout` when available and an isolated watchdog otherwise. History metadata changes are critical; concurrent upstream pulls
remain warnings. See [commands and known limits](docs/commands.md#limits).

Review launch-time git setup fails closed with exit 3 before launching a reviewer.
`DISPATCH_CLONE_TIMEOUT_SECS` bounds clone creation (default 600 seconds);
`DISPATCH_SNAPSHOT_TIMEOUT_SECS` bounds the launch probe and state checks.

Review launch refuses when bounded setup or the agy dirty-status probe fails.
Agy authentication refusals retain exit 7 before the dirty-status refusal.
Drift diagnostics retain every change even when the reviewer removes its state
directory, and omit empty change-list lines.
Interrupted runtimes report `skipped(not-checked)` until drift checking completes.
Temporary output reads are bounded even if a runtime replaces their paths with FIFOs.
Edit dispatch refuses when review pin status cannot be determined (exit 3).
