# agent-dispatch

> **Read [Safety contract](#safety-contract) and [What this does NOT protect](#what-this-does-not-protect)
> before your first dispatch →** how much of a net you get depends on which command you use.

**agent-dispatch hands a unit of work to another agent CLI and gives you back a verdict you can
trust.** You write a brief; it runs `codex`, `agy` (Antigravity/Gemini) or `claude` against a repo
under an external timeout, and hands back a classified result — with exit codes that tell an
out-of-credit account apart from a failing build. It can also *drive* a live agent TUI over tmux or
cmux when you need a real, persistent, watchable session instead of a one-shot.

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
diff in `--worktree` mode) or hard-resets to the pre-dispatch commit — see
[What this does NOT protect](#what-this-does-not-protect) for what a git-level revert cannot undo.
Anything through `dispatch-worker` is bounded and classified, but **never reverted**: a partial or
failed edit stays exactly where the agent left it.

It is for anyone who already runs coding agents from the shell and is tired of hand-rolling the
same safety wrapper: the timeout that the agent's own `--print-timeout` doesn't honour, the
"did it actually change anything?" check, the revert that doesn't eat a concurrent session's work,
and the exit code that tells an out-of-credit account apart from a failing build.

It is **not** an agent, a model, or a sandbox. It does not write code, choose a model for you, or
contain the agent it launches — see [What this does NOT protect](#what-this-does-not-protect).

---

## Requirements

| | Needed for | Notes |
|---|---|---|
| `bash` 3.2+ | everything | macOS's system bash is fine; Linux bash works too |
| `git` | every dispatch command | the snapshot/revert net is git-based |
| `jq` | `coding-dispatch.sh`, `dispatch-worker --runtime workflow` | `coding-dispatch.sh` exits 2 without it |
| `python3` | `run-long-gate.sh` (launch mode) | used to detach the gate into its own session |
| `timeout` or `gtimeout` | bounding any agent run | GNU coreutils. **Without it agent runs are unbounded** and the scripts say so loudly. macOS: `brew install coreutils` |
| `codex` | codex dispatches | optional; the doctor WARNs if absent |
| `agy` | agy dispatches and agy reviews | optional; the doctor WARNs if absent |
| `claude` | `dispatch-worker --runtime claude` | optional |
| `tmux` | `drive-cold-session.sh` | optional |
| `cmux` | `drive-cmux-session.sh` | optional; must be invoked from **inside** a live cmux instance |
| `shellcheck` | the test suite's lint stage, doctor check 6 | optional; skipped with a notice when absent |

macOS and Linux are both supported. Two portability notes are baked in: `md5` (BSD-only) is
resolved through a portable helper, and every `mktemp` use is template-based rather than relying
on GNU-only flags. `run-long-gate.sh` needs `python3` on both.

---

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

`--install` is idempotent. It refuses to overwrite a real file, and it refuses to re-point a
same-named symlink unless that symlink already points into an agent-dispatch checkout — so it
cannot silently hijack another tool's command.

Verify:

```bash
agent-dispatch-doctor
```

```
agent-dispatch-doctor: verify

PASS    1. all 11 entrypoints on PATH + executable
PASS    2. lib/ is not on PATH (…/agent-dispatch/bin/../lib)
PASS    3. codex on PATH (/usr/local/bin/codex)
PASS    4. agy on PATH (/usr/local/bin/agy)
PASS    5. agy models: OK
PASS    5. default model present: Gemini 3.1 Pro (High)
PASS    5. default model present: Gemini 3.5 Flash (Medium)
PASS    6. shellcheck clean (entrypoints, severity>=warning)

Summary: 0 fail, 0 warn
```

Exit codes, in **both** verify and `--install` mode: `0` all pass, `1` any FAIL, `2` any WARN and no
FAIL. So an `--install` that skipped an entrypoint (a foreign symlink it refused to replace) exits
2, not 0 — an installer script must not read that as "done". If `~/.local/bin` is not on your
`PATH`, `--install` tells you and prints the line to add to your shell profile.

---

## Quickstart

### (a) One coding dispatch with a build gate

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

```
DISPATCH_BASE base_ref=HEAD base_sha=1a0d56f2c1b8
▶ brief fingerprint: 9f1c4b2ae0d1 (243B); first line: Add a --json flag to cmd/report…
▶ dispatching to codex in ~/code/.worktrees/myrepo_3f2a91cc/cd-20260830… (timeout 15m, base 1a0d56f2c1b8)…
DISPATCH=ok worktree_ns=… worktree=… branch=cd-20260830131500-4821 base_sha=1a0d56f2c1b8 head=… files=cmd/report/json.go, cmd/report/json_test.go
```

On failure instead:

```
DISPATCH=fail: build/vet failed (go test ./...) — diff SALVAGED in …/cd-20260830131500-4821 (branch cd-…); remove with: git -C ~/code/myrepo worktree remove --force …; patch: …/.git/worktrees/cd-…/coding-dispatch-last-fail.patch
```

The changes are **not committed**. Review the diff, then commit them yourself, or land the branch
(see [Worktree isolation](#worktree-isolation)).

### (b) A plan-driven build phase

Given a plan with `### Task 1: …`, `### Task 2: …` headings, run a whole phase — one dispatch per
task, each committed in the worktree on success, stopping at the first failure:

```bash
coding-build-phase.sh codex ~/plans/retry.md ~/code/myrepo 1 2 3 \
  --worktree --build-cmd "make lint && make test"
```

```
════════ dispatching Task 1 → codex ════════
✓ Task 1 committed in worktree (4c9ab12)
════════ dispatching Task 2 → codex ════════
✓ Task 2 committed in worktree (8ee01f7)
PHASE=ok worktree=… branch=phase-myrepo-20260830131500-4821 tasks=[1 2 3] — land with: git -C '…' merge --ff-only 'phase-…' && git -C '…' worktree remove '…'
```

**Flags go after the positionals.** `coding-build-phase.sh --worktree codex …` fails with a
misleading "plan not found: codex"; the script refuses a leading flag with an explicit message.

Set `--build-cmd` to the repo's **full** ship gate (lint *and* tests), not just tests. A
tests-only gate merges lint debt the repo enforces at ship. There is no auto-detection.

### (c) A peer review

```bash
dispatch-worker --runtime agy --review \
  --brief ~/briefs/security-lens.md \
  --workdir ~/code/myrepo \
  --timeout 20m > review.md
```

The review is on **stdout** — that is the deliverable; capture it. (`REVIEW_OUTFILE=…` on stderr
is a convenience path for a human; see [`dispatch-worker`](#dispatch-worker).) On **this** runtime
— agy — an empty, short, or evidence-free review fails closed with exit 8 rather than passing as a
clean bill of health. That gating is agy-only: `--runtime codex` (the default) and
`--runtime claude` return the binary's own exit code, so judge those reviews yourself. See
[`dispatch-worker`](#dispatch-worker).

### Driving a live session

```bash
# headless, over tmux — leaves the session running for you to inspect
drive-cold-session.sh --approve --timeout 300 claude ~/code/myrepo /tmp/prompt.txt my-task

# visible, over cmux — creates a workspace a human can watch and take over
drive-cmux-session.sh claude ~/code/myrepo /tmp/prompt.txt my-task
```

Use these when you need a *real, persistent, context-loaded* session — validating what a cold
session auto-loads, watching an agent work, steering something interactive. For batch code you
will review from a diff, use the dispatch commands instead.

---

## Command reference

### `coding-preflight.sh`

```
coding-preflight.sh <codex|agy>
```

Deterministic readiness check for one runtime. Emits `KEY=VALUE` contract lines on stdout and
human notes on stderr. Run it once when you opt into a runtime, before delegating anything.

* **codex**: binary present; not already inside a codex sandbox (`CODEX_SANDBOX` /
  `CODEX_SESSION_ID`); `codex login status` reports logged in; reports the model from
  `~/.codex/config.toml`.
* **agy**: binary present; not already inside an agy session (`ANTIGRAVITY_SESSION` /
  `AGY_SESSION_ID`); a live auth probe; and a *prompt-form* probe that sends a sentinel prompt
  through the exact invocation form the dispatch path uses, so a new agy version that changes that
  form is caught here rather than mid-dispatch.

Stdout on success ends with `PREFLIGHT=ok`. Exit codes: `0` ready, `1` not ready
(`PREFLIGHT=error: <reason>` on stdout), `2` unknown agent.

Env: `AGY_FORM_PROBE_TIMEOUT` (default `30s`) bounds the live prompt-form probe.

### `coding-dispatch.sh`

```
coding-dispatch.sh [--worktree] [--base <ref>] [--allow-stale-base] [--keep-on-fail]
                   [--no-venv] [--allow-path <glob>]... [--require-file <path>]...
                   <codex|agy> <workdir> <prompt-file> [build-cmd]
```

One task: snapshot → delegate → validate → revert. **You** author the prompt; this owns the
mechanics. The prompt must tell the agent not to run `git commit/push/add`, and to write
`_coding-result.json` in the workdir on success only.

| Flag | Effect |
|---|---|
| `--worktree` | run the cycle in an isolated worktree at `<repo>/../.worktrees/<repo>_<hash>/<slug>`, outside the parent checkout. The parent need not be clean. On success the worktree and branch are left for you to land. |
| `--base <ref>` | (worktree mode) branch from `<ref>` instead of `HEAD`; refuses a base behind its local tracking ref |
| `--allow-stale-base` | permit that stale base, still printing the staleness |
| `--keep-on-fail` | (non-worktree) skip the hard revert; leave the tree exactly as the agent left it |
| `--no-venv` | don't prepend `<workdir>/.venv/bin` to the gate's PATH |
| `--allow-path <glob>` | repeatable scope allowlist. The globs are injected into the brief AND enforced afterwards: any changed path outside them fails the dispatch. |
| `--require-file <path>` | repeatable. Fail if the named file was not delivered. |
| `build-cmd` | the gate. If given it always runs. With none, falls back to `go build ./... && go vet ./...` only when `go.mod` is present. |

**Validation order** (all after the agent returns): non-empty change → scope gate → build gate →
completion marker. The scope gate runs **before** the build gate on purpose: it is pure
`git status`/`git diff`, while the build gate executes what the agent just wrote.

The marker is belt-and-braces, not required — a non-empty change that passes the gates gets a
synthesized marker rather than a false failure.

| Exit | Meaning |
|---|---|
| `0` | success. `DISPATCH=ok …` — changes left in the tree (or worktree) for you to review and commit. `DISPATCH=ok-noop` means a resume dispatch found the work already done. |
| `1` | failure. Non-worktree: tree hard-reset to the pre-dispatch commit (unless `--keep-on-fail`). Worktree: diff salvaged in the worktree, or the worktree removed with `CODING_DISPATCH_RM_ON_FAIL=1` (the patch still survives). |
| `2` | usage or environment error; nothing was done |
| `9` | a review pin is active on the workdir (see [`review-pin.sh`](#review-pinsh)) |
| `143` | killed by INT/TERM mid-dispatch; a fresh empty worktree is removed, a partial diff is left for salvage |

Every failure snapshots the pre-revert diff — captured with `git diff <base>` against a throwaway
index copy, so it covers untracked files *and* per-task commits without mutating your real index —
and prints where it landed.

### `coding-build-phase.sh`

```
coding-build-phase.sh <codex|agy> <plan.md> <repo-dir> <task-id...> [--worktree] --build-cmd "<gate>"
```

Drives a coding agent through a set of plan tasks. For each id it extracts that task's block
verbatim from `### Task <id>:` up to the next `### Task `, `## Phase`, or `## Self-Review`, wraps
it in the delegation contract, dispatches it, and commits on success. Stops at the first failure
(the dispatch has already reverted or salvaged). `--build-cmd` is required — set `CODING_BUILD_CMD`
instead if you prefer. Commit scope defaults to the repo directory's basename
(`CODING_COMMIT_SCOPE` overrides). Exit codes: `0` phase complete, `1` a task failed
(`PHASE=stopped-at:<id>`), `2` usage/plan error, `9` review pin active.

### `dispatch-worker`

```
dispatch-worker --brief <path> [--runtime codex|agy|claude|workflow|a2a-endpoint]
                [--review] [--ceremony] [--model M] [--workdir D] [--timeout T]
                [--require-dep M]... [--module-dir D] [--allow-dirty] [--shape S]
```

The general brief-to-runtime entrypoint: peer reviews, non-coding one-shots, and anything that
isn't the in-repo edit cycle `coding-dispatch.sh` owns. Run `dispatch-worker --help` for the
authoritative text.

| Runtime | Invocation | Default posture |
|---|---|---|
| `codex` (default) | `codex exec [-m M] --sandbox <mode> -` , brief on stdin | `--sandbox read-only` (no network, no writes). `--ceremony` → `--sandbox danger-full-access` + `--skip-git-repo-check`. |
| `agy` | `agy [--model M] < brief` (bare stdin — never `agy exec -`, `agy -`, or `agy --print "…"`) | auth-preflighted; an autonomous-execution preamble for edits, a read-only preamble for `--review` |
| `claude` | `claude -p [--model M] < brief` | brief on stdin. `--ceremony` → `--dangerously-skip-permissions`; `--review` → `--permission-mode plan` (read-only, and it ignores `--ceremony`). |
| `workflow` | emits a JSON hand-off marker on stdout | for a workflow the calling session launches itself |
| `a2a-endpoint` | not wired yet | returns 3 |

Default agy models: `Gemini 3.1 Pro (High)` under `--review`, `Gemini 3.5 Flash (Medium)` for
edits. Multi-word model names are kept intact as one argument.

**`--review`** is read-only peer review: the brief is a reviewer persona and the review is the
deliverable **on stdout**. What "read-only" is enforced by, and whether a *bad* review is caught,
differ sharply by runtime — this is not a general `--review` contract:

* **agy** — the full treatment. The review runs in a disposable, detached worktree at
  `<repo>/../.worktrees/dispatch-review-wt.XXXXXX` (falling back to
  `${XDG_CACHE_HOME:-~/.cache}/dispatch-review-worktrees/`, then `$TMPDIR`), removed on exit. Two
  gates decide whether the review counts: a byte backstop (`DISPATCH_MIN_REVIEW_BYTES`, default
  1200) and an evidence gate requiring a labelled severity (Blocker/Major/Minor/Nit/Critical) or a
  `file:line` citation. Failing either is exit 8 — **not** a pass. A single timeout is retried once
  internally; a second timeout is also exit 8. And if the real tree is dirty *and* the brief names
  one of the uncommitted paths, it refuses (exit 2) before launching, because a review of a tree
  missing the file it was briefed on is worse than no review — a dirty tree whose dirty files are
  not named in the brief only warns, and `--allow-dirty` (`DISPATCH_ALLOW_DIRTY=1`) opts out.
* **codex** — `--sandbox read-only` is forced (an explicit `--ceremony` is overridden, and it says
  so) and the post-dispatch dep gate is skipped. That is all. There is **no** byte floor, **no**
  evidence gate, **no** isolated worktree and **no** `REVIEW_OUTFILE`.
* **claude** — `--permission-mode plan` is forced (`--ceremony` ignored). Same story: the review's
  *content* is not gated at all.

In plain terms: outside agy, `--review` gets you sandbox/permission restriction and nothing else —
an empty or one-line review comes back as the binary's own exit code, usually `0`. **codex is the
default runtime**, so a bare `dispatch-worker --review` is the ungated path; pass `--runtime agy`
if you want the review judged, or judge it yourself.

A review pin is taken on the workdir for every `--review` regardless of runtime, and released on
exit (see [`review-pin.sh`](#review-pinsh)).

| Exit | Meaning |
|---|---|
| `0` | the runtime returned success |
| `2` | usage error, unreadable brief, unknown runtime, or the dirty-tree review refusal |
| `3` | the runtime binary is not on PATH, or no isolated review worktree could be allocated |
| `4` | `--require-dep` gate failed — a promised module is missing from `go.mod` |
| `5` | codex rejected every model at the auth/config layer. Fix auth; **do not** retry as a build. |
| `6` | codex hit a usage/rate limit. It can exit 0 on a zero-edit no-op, so this is detected from the limit signature *plus* an absence of substantive output. Treat as blocked. |
| `7` | agy is not authenticated (`agy` and sign in). Do not retry as a build. |
| `8` | an agy `--review` did not produce a real review (too short, no evidence, or timed out twice) |
| `124` | the external `--timeout` bound killed a hung agent — a blocked phase, not a result |
| other | the runtime's own exit code, unchanged |

Artifacts (agy `--review` only): the review is also tee'd to a file whose path is printed on
stderr as `REVIEW_OUTFILE=<path> (rc=<n>)`. If **you** set `REVIEW_OUTFILE`, that file is yours and
is kept; otherwise the file is an `$TMPDIR` temp and is deleted when `dispatch-worker` exits. The
codex and claude review paths write no such file. Capture stdout, not the path.

### `gate-run.sh`

```
gate-run.sh [--expect-root <path>] [--no-venv] -- <command...>
```

Runs a build gate with two guarantees the dispatcher depends on. It prepends
`<cwd>/.venv/bin` to `PATH` when that directory exists (unless `--no-venv` / `DISPATCH_NO_VENV`)
and prints a `gate-env: python=… ruff=…` line naming the tools it actually resolved — so a gate
that fails because it ran the wrong interpreter is diagnosable instead of just a mystery revert.
It also stamps `GATE_TREE_PRE`/`GATE_TREE_POST` (pwd, toplevel, HEAD) around the command, and with
`--expect-root` exits `2` with `GATE_TREE_UNTRUSTWORTHY` if the gate ended up in a different repo
than expected. Otherwise it passes the gate command's exit code through unchanged.

### `run-long-gate.sh`

```
run-long-gate.sh --cmd <shell-command> [--log <path>] [--workdir <dir>] [--label <name>] [--allow-concurrent]
run-long-gate.sh --status --log <path>
run-long-gate.sh --wait   --log <path> [--timeout-secs N] [--poll-secs N]
```

Runs a long gate detached in its own session so a session-length timeout can't kill it, then lets
you poll or wait. Launch prints `LOG_PATH=…` and `PID=…`; the log ends with `GATE_EXIT=<n>`.

With no `--log`, the log is created with `mktemp` under `${TMPDIR:-/tmp}`, mode 0600, unique per
launch. A `--log` you supply is appended to — unless it is a **symlink**, which is refused (exit
2) rather than written through.

A per-workdir lockfile (`${TMPDIR:-/tmp}/run-long-gate-<key>.lock`) serialises full-suite runs:
two gates for the same working directory can't race for the same port or singleton lock.
`--allow-concurrent` overrides it; a dead holder is treated as a stale lock, not a conflict.

Exit codes: launch `0` (or `2` launch failure, `4` a gate is already running for that workdir);
`--status` `0` finished (prints `GATE_EXIT=<n>`), `2` no/missing log, `3` still running; `--wait`
the gate's own exit code, `124` on timeout, `2` without `--log`.

### `mutation-verify.sh`

```
mutation-verify.sh --file <path> --test-cmd <cmd>
                   (--mutate-sed <expr> | --mutate-cmd <cmd>)
                   [--expect-anchor <str>]... [--expect-marker <str>]...
                   [--syntax-cmd <cmd>] [--cover-check <line-or-symbol>]
```

Proves a test is load-bearing: break the code, confirm the test goes red, restore. It snapshots
the file by copy (`mktemp`), **never** with git — the pass this exists to protect against is
`git checkout -- <file>` on an uncommitted diff, which restores the last commit and throws away
the in-flight fix while reporting a clean "mutation-proof" result.

`--test-cmd` runs **twice**: once as a baseline against the unmutated file (if that fails, the
instrument is invalid and it aborts before mutating anything) and once under mutation. The
applied-verification flags close the other false-pass route: `--expect-anchor` asserts the text
you intend to mutate is present *before* mutating, `--expect-marker` asserts your mutation
actually landed, `--syntax-cmd` rejects a mutation that merely broke the parse, and
`--cover-check` asserts the mutated function was actually executed (a mutation no test reaches is
`MUTANT-UNREACHABLE`, not a survivor).

Exit codes: `0` the test caught the mutation, `1` false green, `2` harness error (bad args,
failing baseline, no-op mutation, failed verification, failed restore).

### `review-pin.sh`

```
review-pin.sh pin <workdir> [--label <text>] | release <workdir> | status <workdir>
```

Marks a working tree as pinned to its current HEAD while a review of it is in flight, so a
concurrent dispatch can't move the code out from under the reviewer. The marker is
`<git-dir>/review-pinned`. `coding-dispatch.sh` and `coding-build-phase.sh` refuse with exit `9`
while a pin is active, naming the pinned SHA, label, age, and the release command.
`dispatch-worker --review` pins automatically and releases on exit.

Pins expire: `DISPATCH_REVIEW_PIN_TTL_SECS` (default 14400 = 4h). A stale pin is removed on the
next `status`/`pin`, so a SIGKILLed review does not wedge the repo forever. Exit codes: `0` ok,
`1` no pin (or a stale one, now removed), `2` usage/error.

### `drive-cold-session.sh`

```
drive-cold-session.sh [--model M] [--approve] [--timeout S] <claude|codex|agy> <workdir> <prompt-file> [session-name]
```

Creates a **detached tmux session** running the agent in `<workdir>`, waits for boot to settle,
pastes the prompt as one bracketed-paste block, submits it with a single Enter, polls until the
screen stops changing, prints the transcript, and **leaves the session running** for you to
inspect or continue. `--approve` auto-approves tool calls so an unattended run doesn't stall on a
permission prompt (claude/agy: `--dangerously-skip-permissions`; codex:
`--dangerously-bypass-approvals-and-sandbox`) and best-effort accepts agy's folder-trust prompt.
Env: `DCS_BOOT_MAX` (60), `DCS_SETTLE_MAX` (240), `DCS_STABLE` (3), `DCS_INTERVAL` (2),
`DCS_KILL=1` to kill the session after printing. Exit `2` on usage or a missing prerequisite.

### `drive-cmux-session.sh`

```
drive-cmux-session.sh <claude|codex|agy> <workdir> <prompt-file> [workspace-name]
```

The cmux sibling. **It creates a new cmux workspace** running the agent (it does not attach to an
already-running one), drives it with the same paste/confirm/settle discipline, surfaces progress
through `cmux notify` / `set-status` / `set-progress`, prints the scrollback transcript, and
leaves the workspace open (`DCS_CLOSE=1` closes it). Name the workspace after its task — that name
is the handle you reopen it by.

It must be run from **inside** the live cmux instance: cmux grants socket trust only to processes
running within it, and `Failed to write to socket (Broken pipe)` means you are outside it. Long
prompts (>1000 bytes or >8 lines) are delivered as a short file-pointer instead of a paste,
because cmux's paste buffer has been observed to silently truncate the middle of a large paste.
Env: `DCS_BOOT_MAX`, `DCS_SETTLE_MAX`, `DCS_STABLE`, `DCS_INTERVAL`, `DCS_CLOSE`. Exit `2` on
usage or a missing prerequisite.

### `agent-dispatch-doctor`

```
agent-dispatch-doctor              # verify
agent-dispatch-doctor --install    # symlink entrypoints into ~/.local/bin
agent-dispatch-doctor --help
```

See [Install](#install). `--print-entrypoints` lists the installed command names.

### Environment variables

| Variable | Read by | Default / effect |
|---|---|---|
| `CODING_DISPATCH_TIMEOUT` | `coding-dispatch.sh` | `15m` (codex) / `25m` (agy) — the external bound on the agent |
| `CODING_DISPATCH_WORKTREE` | `coding-dispatch.sh`, `coding-build-phase.sh` | the worktree/branch slug; a worktree with that slug is reused so a multi-task phase accumulates on one branch |
| `CODING_DISPATCH_RM_ON_FAIL` | `coding-dispatch.sh` | `1` = remove the worktree on failure instead of salvaging it; the patch still survives under the parent repo's git dir |
| `CODING_DISPATCH_CHILD_ENV` | `coding-dispatch.sh` | whitespace-separated `KEY=VALUE` pairs exported into the dispatched agent's environment, e.g. `"MYREPO_LEDGER=off CI=1"`. Malformed entries are reported on stderr and skipped. |
| `CODING_BUILD_CMD` | `coding-build-phase.sh` | default for `--build-cmd` |
| `CODING_COMMIT_SCOPE` | `coding-build-phase.sh` | conventional-commit scope (default: repo dir basename) |
| `AGY_MODEL` | `coding-dispatch.sh` | agy model for edit dispatches (default `Gemini 3.5 Flash (Medium)`) |
| `DISPATCH_NO_VENV` | `gate-run.sh` via `lib/gate-env.sh` | any value = same as `--no-venv` |
| `DISPATCH_GATE_ADVISORY_TTL_SECS` | `coding-dispatch.sh` | `3600` — how long a "your build-cmd skips gate-target X" advisory is deduplicated |
| `DISPATCH_REVIEW_PIN_TTL_SECS` | `review-pin.sh` | `14400` — after this a pin is stale and auto-removed |
| `RUNTIME`, `MODEL`, `WORKDIR`, `MODULE_DIR`, `CEREMONY`, `REVIEW` | `dispatch-worker` | env twins of the matching flags |
| `TIMEOUT` | `dispatch-worker` | `15m`; `0` or `none` disables the external bound |
| `KILL_AFTER` | `dispatch-worker` | `30s` grace before SIGKILL (`timeout -k`) |
| `REVIEW_OUTFILE` | `dispatch-worker` | where to tee the review. Supplying it means **you** own the file and it is retained. |
| `DISPATCH_MIN_REVIEW_BYTES` | `dispatch-worker` | `1200` byte backstop for `--review` |
| `DISPATCH_REVIEW_REQUIRE_EVIDENCE` | `dispatch-worker` | exactly `0` disables the labelled-severity / `file:line` evidence gate |
| `DISPATCH_REVIEW_WT_DIR` | `dispatch-worker` | preferred parent directory for isolated review worktrees |
| `DISPATCH_ALLOW_DIRTY` | `dispatch-worker` | `1` = warn instead of refusing when a review brief names an uncommitted path |
| `DISPATCH_LIMIT_NOOP_BYTES` | `dispatch-worker` | `200` — stdout below this, plus a rate-limit signature, is read as a limit no-op (exit 6) |
| `AGY_FORM_PROBE_TIMEOUT`, `AGY_BIN` | `coding-preflight.sh` probes | `30s`; the agy binary to probe |
| `DCS_BOOT_MAX`, `DCS_SETTLE_MAX`, `DCS_STABLE`, `DCS_INTERVAL`, `DCS_KILL`, `DCS_CLOSE` | the drive scripts | see above |
| `TMPDIR`, `XDG_CACHE_HOME` | several | honoured for temp files, gate logs, and review-worktree fallbacks |

---

## Safety contract

**Don't hand-roll `codex exec` / `agy < brief` / `claude -p`.** Go through these tools so the bound
and the classification actually run — and know which tool you are using, because they do not offer
the same thing:

* **`coding-dispatch.sh` / `coding-build-phase.sh` (codex, agy)** give you the whole sequence:
  preflight → external timeout → change/scope/build gates → completion marker → hard revert on
  failure. Everything in the numbered list below is theirs.
* **`dispatch-worker` (all runtimes, and the only path for `claude`)** gives you the external
  timeout, the runtime's read-only/permission posture, the agy auth preflight and the agy
  review-evidence gate, and the dedicated exit codes. **It has no build gate and no revert net.**

Bypassing a step voids what guarantee there is, and can leave a dirty tree that corrupts a
concurrent session.

What the `coding-dispatch.sh` net covers:

1. **A dirty tree is refused.** Without `--worktree`, `coding-dispatch.sh` exits 2 if
   `git status --porcelain` is non-empty, because the revert hard-resets to HEAD and would take
   your uncommitted work with it.
2. **An external timeout owns the clock.** The bound is a separate `timeout` process, never the
   agent's own `--print-timeout` (agy has hung hours past its own setting). A kill is exit 124 —
   a *blocked phase*, not a result. With no `timeout`/`gtimeout` on PATH the run is unbounded and
   the script says so.
3. **A failure restores the tree.** The revert is `git reset --hard <pre-dispatch-commit>` +
   `git clean -fd` — **not** `git checkout -- .`, and note there is no `-x`, so ignored files
   (build caches, `.env`, `.venv`) are left alone. In `--worktree` mode the reset runs inside the
   isolated worktree and cannot reach the parent checkout.
4. **Nothing is committed for you.** A successful dispatch leaves changes for you to review. A
   successful *phase* commits per task inside the worktree, and still never touches your branch.
5. **Every failure is inspectable.** The pre-revert diff is written to
   `<git-dir>/coding-dispatch-last-fail.patch` (or, under `CODING_DISPATCH_RM_ON_FAIL`,
   `<parent-git-dir>/coding-dispatch-fail-patches/<slug>.patch`) and the path is printed. It is
   never written into your working tree.
6. **Reviews cannot silently pass.** Empty, short, or evidence-free agy reviews are exit 8.

### What this does NOT protect

Read this before pointing agent-dispatch at code you did not write.

* **The agents run as you, unsandboxed, with network.** `coding-dispatch.sh` invokes
  `codex exec --dangerously-bypass-approvals-and-sandbox` and
  `agy --dangerously-skip-permissions`. Those are the only forms it uses; there is no opt-out
  flag. The agy `--review` lane in `dispatch-worker` also passes
  `--dangerously-skip-permissions` when it has a disposable worktree to run in. The agent has your
  full user privileges, your filesystem, your credentials on disk, and your network.
* **The revert net covers the git working tree of the target repo. Nothing else.** Files written
  outside the repo, packages installed, credentials read, requests sent, and anything a
  `.gitignore`d path holds are not restored and not detected.
* **`dispatch-worker` has no revert net.** That includes every `claude` dispatch and any
  `--ceremony` edit: a partial or failed edit is **not** undone. Only `coding-dispatch.sh` and
  `coding-build-phase.sh` revert. If you want a failed edit rolled back, use those, and dispatch
  into a `--worktree`.
* **A worktree isolates files, not refs.** `--worktree` guarantees a hard revert cannot delete a
  concurrent session's uncommitted work in the shared checkout. It does **not** isolate the shared
  `.git` object store or refs: an agent inside the worktree can still move branches and tags
  visible everywhere.
* **A review is still an agent execution.** `--review` prompts the model to stay read-only; it is
  a prompt, not a sandbox. Content in a repo or PR under review can attempt to instruct the agent
  (prompt injection), and an agent with permissions can act on it.
* **The completion marker is a claim, not proof.** It is written by the agent. That is why the
  build gate and scope gate are authoritative and the marker is not required.

**If the repo or PR is untrusted, run agent-dispatch inside a VM or container**, with credentials
it doesn't mind losing and a network it doesn't mind being used. Nothing here substitutes for
that.

---

## Data flow

The plugin sends no telemetry and phones nothing home. What leaves your machine is what the agent
CLI you chose sends, on your account:

| Runtime | Goes to | Content |
|---|---|---|
| `codex` | OpenAI | the brief (plus the injected scope constraint, if `--allow-path`) and whatever codex reads in the repo while working |
| `agy` | Google | the brief plus the injected preamble, and whatever agy reads in the repo (the review worktree, in `--review`) |
| `claude` | Anthropic | the brief on stdin, and whatever claude reads while working |

`coding-preflight.sh agy` additionally sends one **sentinel prompt** ("Reply with exactly this
token and nothing else: …") to verify the invocation form still round-trips. `agent-dispatch-doctor`
runs `agy models`, which contacts the agy backend.

Local artifacts, where they land, and how long they live:

| Artifact | Path | Lifetime |
|---|---|---|
| Failure diff | `<git-dir>/coding-dispatch-last-fail.patch` | overwritten by the next failure; delete when done |
| Failure diff (worktree removed) | `<parent-git-dir>/coding-dispatch-fail-patches/<slug>.patch` | kept, keyed by slug |
| Gate advisory marker | `<git-dir>/gate-advisory` | rewritten; TTL-based dedupe only |
| Review pin | `<git-dir>/review-pinned` | released on exit; auto-expires (4h default) |
| Dispatch worktrees | `<repo>/../.worktrees/<repo>_<hash>/<slug>/` | left for you on success and on salvage |
| Review worktree | `<repo>/../.worktrees/dispatch-review-wt.XXXXXX` | removed on exit; stale ones (>6h) reaped on the next review |
| Review tee file | `$TMPDIR/dispatch-review.XXXXXX.md` | deleted on exit, unless you set `REVIEW_OUTFILE` |
| Gate log | `${TMPDIR:-/tmp}/<label>-gate.XXXXXX` (or your `--log`) | kept — it is the record you poll |
| Gate lock | `${TMPDIR:-/tmp}/run-long-gate-<key>.lock` | removed when the gate finishes |
| Completion marker | `<workdir>/_coding-result.json` | transient; removed on both the success and failure paths |

Recommended `.gitignore` in any repo you dispatch into:

```gitignore
_coding-result.json
```

Everything else lives under `.git/` or `$TMPDIR`, outside the working tree, so nothing else needs
ignoring.

---

## Worktree isolation

**Why.** The non-`--worktree` path requires a clean tree and hard-reverts on failure. If another
session (or you, in another terminal) has uncommitted work in the same checkout, that revert
deletes it. `--worktree` moves the entire cycle somewhere that cannot happen.

**What `--worktree` does.** It creates `<repo>/../.worktrees/<repo-basename>_<hash>/<slug>` —
one level *above* the repo, resolved to a physical absolute path — checks out the base commit
there, and runs everything inside it. A `git clean -fd` at the parent level cannot reach it.
`coding-build-phase.sh --worktree` reuses one worktree for the whole phase so the tasks accumulate
on a single branch.

**Landing the work.** Nothing merges automatically. When you are happy with the branch:

```bash
git -C <repo> fetch                                    # your base may have moved
git -C <repo> merge --ff-only <slug>
git -C <repo> worktree remove <worktree-path>
```

**Salvage on failure.** By default a failed dispatch leaves the worktree in place with the diff
intact, and prints the removal command. `CODING_DISPATCH_RM_ON_FAIL=1` removes it instead — the
failure patch is still written under the parent repo's git dir so the failure stays inspectable.

**Finding and pruning.**

```bash
git -C <repo> worktree list                     # what exists, and on what branch
git -C <repo> worktree prune                    # drop orphaned registrations
git -C <repo> worktree remove --force <path>    # drop a salvaged one after inspecting it
```

### Untracked content is NOT shared

A worktree shares **tracked** state with the source checkout — commits, branches, the index — but
**not** untracked files: `git worktree add` gives the new worktree its own independent copy of
whatever untracked files exist at creation time, not a live view onto the source checkout's
untracked files.

**If a dispatched task needs to delete untracked content from the source checkout, that deletion
must run against the source checkout directly — never inside the worktree.** A deletion run in
the worktree removes the worktree's own disconnected copy and leaves the source checkout's
untracked files fully intact: the "deletion" silently does nothing to the content it was meant to
remove. After any such deletion, verify against the source path itself, not the worktree.

---

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

---

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
section for which path applies.

**cmux: `Failed to write to socket (Broken pipe)`.** You are running outside the live cmux
instance. cmux grants socket trust only to processes running inside it — open a terminal inside
the running instance and invoke from there.

**A TUI drive reads stale or empty output.** That is render lag, not an empty reply. Both drive
scripts re-capture until the screen stabilises; if you are scripting a TUI yourself, never act on
the first capture after a keystroke, and never send prompt text and Enter in a single call.

---

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
