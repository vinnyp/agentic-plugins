# Command reference

Every entrypoint agent-dispatch installs, with its synopsis, the flags that matter, exit codes,
environment variables, and artifact paths. For the one-message overview and the safety contract,
start at the [README](../README.md); before pointing any of these at code you did not write, read
[Safety and data flow](safety-and-data-flow.md).

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
| a Go toolchain | `bin/ensure-review-gate.sh`, and so the `review-gate` CLI | optional; nothing else in the plugin needs it. No binary is committed — `ensure-review-gate.sh` compiles `tools/review-gate/` on demand and exits 2 if `go` is absent |

macOS and Linux are both supported. Two portability notes are baked in: `md5` (BSD-only) is
resolved through a portable helper, and every `mktemp` use is template-based rather than relying
on GNU-only flags. `run-long-gate.sh` needs `python3` on both.

## `coding-preflight.sh`

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

## `coding-dispatch.sh`

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

One dispatch with a build gate, in an isolated worktree:

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
(see [Worktree isolation](worktree-isolation.md)).

## `coding-build-phase.sh`

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

## `dispatch-worker`

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

A single briefed review looks like this:

```bash
dispatch-worker --runtime agy --review \
  --brief ~/briefs/security-lens.md \
  --workdir ~/code/myrepo \
  --timeout 20m > review.md
```

The review is on **stdout** — that is the deliverable; capture it. (`REVIEW_OUTFILE=…` on stderr
is a convenience path for a human.) On **this** runtime — agy — an empty, short, or evidence-free
review fails closed with exit 8 rather than passing as a clean bill of health. That gating is
agy-only: `--runtime codex` (the default) and `--runtime claude` return the binary's own exit code,
so judge those reviews yourself. For a whole round of lenses, see
[the peer-review gate](peer-review-gate.md).

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

## `gate-run.sh`

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

## `run-long-gate.sh`

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

## `mutation-verify.sh`

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

## `review-pin.sh`

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

## `ensure-review-gate.sh`

```
bin/ensure-review-gate.sh
```

Builds `tools/review-gate/` into `<plugin>/.bin/review-gate` if that binary is missing or stale.
No compiled artifact is committed, so this needs a **Go toolchain** — it looks for `go` on `PATH`
and then in the usual install locations (`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/local/go/bin`,
`~/go/bin`, `/opt/go/bin`). Idempotent: it keys on a hash of the `.go` sources and exits immediately
when the binary is current, so a skill can call it before every run.

Output lands in `.bin/` rather than `bin/` because `bin/` holds shell entrypoints only — the
doctor's entrypoint registry and the suite's shellcheck sweep both walk it, and a compiled binary
belongs to neither. Everything resolves relative to the script's own location, so it works from a
marketplace install, a git checkout, or a symlink, with no environment set.

Exit codes: `0` the binary is present and current (built if it was not), `2` no Go toolchain,
missing sources, or a failed build.

## `review-gate`

```
review-gate brief       --persona <peer-X-reviewer> --mode <design|build> --for <claude|cross-model>
                        (--range <A..B> | --spec <path>...) [--source <path>]... [--what <text>]
                        [--repo-root <dir>] [--closing-template <path>]
review-gate cross-model [--runtime <agy|codex>] [--timeout <dur>] [--workdir <dir>] --brief <path>...
review-gate log-new     --topic <slug> [--mode <design|build>] [--persona <name>]...
                        [--project <slug>] [--stdout] [--force]
```

The mechanical half of the [peer-review gate](peer-review-gate.md). Built by
`ensure-review-gate.sh`; not installed on `PATH` by the doctor.

**`brief`** assembles one review brief. It emits **paths** — the `--range` or `--spec` under review,
the `--source` contracts to read — plus a `repo root:` line they resolve against, and tells the
reviewer to open them. That is the point: a brief built from pasted excerpts cannot contain what the
truncation removed, so it yields a consistency check on the brief rather than a review of the code.
Pass `--repo-root` when the review targets a worktree other than your cwd — `agy` does not load
worktrees, so a bare relative path can silently resolve against the wrong tree.

Because the brief is a promise that its targets are real, it **fails closed on a target it cannot
resolve**: every `--spec` and `--source` must exist (tried against `--repo-root`, then your cwd),
and when the root is a git repo the `--range` must resolve there. A brief naming a moved spec or a
stale range otherwise renders byte-identically to a correct one, and the only thing left to catch it
is the reviewer's own self-report. The probe is skipped when the root is not a git repo, so a brief
authored outside one is never failed for a check that could not run. `--mode design`
requires `--spec` and forbids `--range`; `--mode build` is the reverse. `--for cross-model` prepends
the full persona body (another runtime cannot auto-load it); `--for claude` omits it. Both append
`templates/review-brief-closing.md`, which carries the "return exactly this structure" instruction
and the file:line requirement — one source for both routes.

**`cross-model`** runs each `--brief` through `dispatch-worker --runtime <agy|codex> --review`,
**serialized, never concurrent** (agy has a wedged-shared-session risk). Each review is printed to
stdout under a `===== review: brief N =====` header, followed by a summary line per brief carrying
its own rc and body length. The process **exits with the worst rc across briefs**, so read the
per-brief rc from the summary rather than `$?`. Pass **`--workdir <dir>`** to override the checkout
`dispatch-worker` reviews for every brief; by default each brief uses its own declared `repo root:`
line, falling back to the current directory only when that line is absent. Beyond
`dispatch-worker`'s own gating it applies a
last-resort backstop: a body under 400 bytes on an otherwise-clean rc is re-reported as `8`, because
a short no-findings sign-off must never count as a review. It never retries — rc 8 means fall back
to a local reviewer for that lens, not run it again.

**`log-new`** scaffolds `docs/agent-reviews/YYYY-MM-DD-<topic>-peer-reviews.md` in the repo you are
in: a header stamped with the resolved persona version, a section per `--persona`, and the empty
verify-the-reviewer disposition table. It refuses to run outside a git repo, writes repo-root-
relative only, and refuses to overwrite an existing dated log without `--force` — prefer a new
`--topic` for a genuinely separate pass. `--topic` must be a single path segment matching
`[A-Za-z0-9._-]+`: the output path is built from it, and this command is driven by agents on slugs
derived from branch names and issue titles, so an unconstrained topic would be an arbitrary file
write. `--project` likewise may not contain a newline, since it is written into YAML frontmatter. It only scaffolds; it never sees findings, so redacting
personal data out of what you paste in is the author's job, not the CLI's. If the target repo is an
Obsidian vault (a `.obsidian/` directory at its root) the scaffold grows a YAML frontmatter block so
it passes a vault's note validation; `--project` adds a project key to it. Inert in any other repo.

Persona bodies are resolved from the installed `peer-reviewer-agents` plugin, in this order:
`REVIEW_GATE_PERSONA_DIR` if set, then relative to `CLAUDE_PLUGIN_ROOT` (which covers the
personas living in a different marketplace than this plugin), then the newest version in
`~/.claude/plugins/cache/<marketplace>/<plugin>/`, then a `~/Projects/<plugin>/agents` checkout as a
last resort. The resolved version is stamped into every brief and log header — `persona-version:
cache/1.0.0` — so a skew between the same-model and different-model routes is visible in the record.
The persona *set* is read by glob, never from a hardcoded list, so a lens added to the plugin is
available without rebuilding this CLI.

| Variable | Effect |
|---|---|
| `REVIEW_GATE_PERSONA_DIR` | an `agents/` directory to use verbatim; highest priority |
| `REVIEW_GATE_PERSONA_MARKETPLACE` | marketplace owning the personas (default `agentic-plugins`) |
| `REVIEW_GATE_PERSONA_PLUGIN` | plugin owning the personas (default `peer-reviewer-agents`) |

Exit codes: `0` ok, `1` a validation failure (unknown persona, wrong flags for the mode, an
unresolvable `--spec`/`--source`/`--range`, a `--topic` that is not a bare slug, an existing log
without `--force`), `2` an I/O or system error, `3` for `log-new` when the log was written but the
persona provenance is `UNRESOLVED`. `cross-model` instead passes through the worst
`dispatch-worker` rc — `5`/`6` codex auth or rate limit (not a build failure), `7` agy not
authenticated, `8` empty/short/evidence-free review, `124` timeout.

## `drive-cold-session.sh`

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

```bash
# headless, over tmux — leaves the session running for you to inspect
drive-cold-session.sh --approve --timeout 300 claude ~/code/myrepo /tmp/prompt.txt my-task
```

## `drive-cmux-session.sh`

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

```bash
# visible, over cmux — creates a workspace a human can watch and take over
drive-cmux-session.sh claude ~/code/myrepo /tmp/prompt.txt my-task
```

Use the drive scripts when you need a *real, persistent, context-loaded* session — validating what
a cold session auto-loads, watching an agent work, steering something interactive. For batch code
you will review from a diff, use the dispatch commands instead.

## `agent-dispatch-doctor`

```
agent-dispatch-doctor              # verify
agent-dispatch-doctor --install    # symlink entrypoints into ~/.local/bin
agent-dispatch-doctor --help
```

`--install` symlinks every entrypoint into `~/.local/bin`. It is idempotent. It refuses to
overwrite a real file, and it refuses to re-point a same-named symlink unless that symlink already
points into an agent-dispatch checkout — so it cannot silently hijack another tool's command.
`--print-entrypoints` lists the installed command names.

Verify prints a per-check report:

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

## Environment variables

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
