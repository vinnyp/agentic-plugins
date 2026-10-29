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
  `~/.codex/config.toml`. A one-turn exec probe verifies that its shell tool hashes a
  nonce in a disposable git repository before reporting ready. Shell failures and timeouts
  fail closed; unavailable probe prerequisites are inconclusive and proceed with a note.
* **agy**: binary present; not already inside an agy session (`ANTIGRAVITY_SESSION` /
  `AGY_SESSION_ID`); a live auth probe; and a *prompt-form* probe that sends a sentinel prompt
  through the exact invocation form the dispatch path uses, so a new agy version that changes that
  form is caught here rather than mid-dispatch.

Stdout on success ends with `PREFLIGHT=ok`. Exit codes: `0` ready, `1` not ready
(`PREFLIGHT=error: <reason>` on stdout), `2` unknown agent.

Env: `AGY_FORM_PROBE_TIMEOUT` (default `30s`) bounds the live prompt-form probe.
`CODEX_EXEC_PROBE_TIMEOUT` (default `75s`, with a `10s` kill grace) bounds the codex probe.
The probe usually takes tens of seconds. Allow at least 120s in the calling agent's
tool timeout; when raising the probe bound, also allow its 10s kill grace and preflight overhead.
The bound must match `^[1-9][0-9]*[smh]?$`; invalid values (including zero)
fall back to 75s with a stderr note. Stdout reports
`CODEX_EXEC_PROBE=ok|inconclusive|skipped`.
Only `CODING_PREFLIGHT_CODEX_PROBE=0` skips it, for repeated scripted preflights.
If the probe reports a code-mode host error, run `codex-code-mode-host --help` once
and check macOS quarantine/Gatekeeper on the codex cask binaries.

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
| `6` | agent unavailable (capacity/rate limit); no work attempted |
| `9` | a review pin is active on the workdir (see [`review-pin.sh`](#review-pinsh)) |
| `143` | killed by INT/TERM mid-dispatch; a fresh empty worktree is removed, a partial diff is left for salvage |

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
it in the delegation contract, dispatches it, and commits on success. Every task prompt also
carries the plan's preamble (everything above the first `### Task ` heading: goal, spec path,
global constraints) under a `PLAN CONTEXT` banner ahead of the task spec, so plan-wide rules
reach the worker without being restated per task. The superpowers `> **For agentic workers:**`
banner has only orchestrator boilerplate removed; spec references and other worker guidance
are kept. Leading YAML frontmatter is dropped, and whitespace-only preambles produce no
context block. The block is capped at `CODING_BUILD_PLAN_CONTEXT_MAX` characters, with a
truncation note naming the absolute plan path and one stdout warning per phase. The prompt
clarifies that orchestrator instructions are not for the worker and requires it to stop and
report conflicts between plan context and task spec instead of guessing or claiming success. Stops at the first failure
(the dispatch has already reverted or salvaged). `--build-cmd` is required — set `CODING_BUILD_CMD`
instead if you prefer. Commit scope defaults to the repo directory's basename
(`CODING_COMMIT_SCOPE` overrides). Exit codes: `0` phase complete, `1` a task failed
(`PHASE=stopped-at:<id>`), `2` usage/plan error, `6` agent unavailable
(`PHASE=blocked-unavailable:<id>`), `9` review pin active.

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
                [--review] [--ceremony] [--model M] [--agent NAME] [--workdir D] [--timeout T]
                [--require-dep M]... [--module-dir D] [--allow-dirty] [--shape S]
```

The general brief-to-runtime entrypoint: peer reviews, non-coding one-shots, and anything that
isn't the in-repo edit cycle `coding-dispatch.sh` owns. Run `dispatch-worker --help` for the
authoritative text.

| Runtime | Invocation | Default posture |
|---|---|---|
| `codex` (default) | `codex exec [-m M] [-C D] --sandbox <mode> -` , brief on stdin | `--sandbox read-only` (no network, no writes). `--workdir` is passed as `-C` when it names an existing directory. `--ceremony` → `--sandbox danger-full-access` + `--skip-git-repo-check`. |
| `agy` | `agy [--model M] [--agent=NAME] < brief` (bare stdin — never `agy exec -`, `agy -`, or `agy --print "…"`) | auth-preflighted; `--agent NAME` is checked against `agy agent` before dispatch; an autonomous-execution preamble for edits, a read-only preamble for `--review` |
| `claude` | `claude -p [--model M] < brief` | brief on stdin. `--ceremony` → `--dangerously-skip-permissions`; `--review` → `--permission-mode plan` (read-only, and it ignores `--ceremony`). |
| `workflow` | emits a JSON hand-off marker on stdout | for a workflow the calling session launches itself |
| `a2a-endpoint` | not wired yet | returns 3 |

Default agy models are defined by role in `bin/lib/agy-models.sh`: review under `--review`, coding for
edits. Multi-word overrides stay one argument.
Preflight validates the effective coding model; dispatch-worker validates its effective
role model (exit 9 if missing); the doctor fails if either pinned default is missing.
If any gate reports drift, run `agy models` and edit `bin/lib/agy-models.sh`, or use
`--model`/`MODEL` (dispatch-worker) or `AGY_MODEL` (coding) for a one-off override.
Inconclusive auth probes and unparseable lists skip model validation with a warning.
Agy preflight emits `AGY_MODEL_CHECK=ok` or `AGY_MODEL_CHECK=skipped:<reason>`;
its `CODING_INVOKE` includes the effective `--model`. Matching ignores case; tierless
IDs warn that agy chooses a tier. Missing-model remedies name the absolute pin file.
`--agent NAME` is agy-only and rejects an unknown or unavailable persona roster with exit 2 before
the brief is dispatched. The selected persona is retained on the one permitted review-timeout retry.

**`--review`** is read-only peer review: the brief is a reviewer persona and the review is the
deliverable **on stdout**. What "read-only" is enforced by, and whether a *bad* review is caught,
differ sharply by runtime — this is not a general `--review` contract:

* **agy** — the full treatment. The review runs in a disposable private clone, detached at the pinned HEAD, at
  `<repo>/../.worktrees/dispatch-review-wt.XXXXXX` (falling back to
  `${XDG_CACHE_HOME:-~/.cache}/dispatch-review-worktrees/`, then `$TMPDIR`), removed on exit. Two
  gates decide whether the review counts: a byte backstop (`DISPATCH_MIN_REVIEW_BYTES`, default
  1200) and an evidence gate requiring a case-insensitive severity label
  (Blocker/Major/Minor/Nit/Critical/High/Medium/Low/Info) or a `file:line` citation. Severity labels
  must start a line or table cell, optionally after heading,
  numbered/list, bold or bracket prefixes, and end with `:`, `]`, `**`, `|`, `)`, or a spaced
  dash (` — ` / ` - `). Explicit `Severity:` fields (including `**Severity:**`) may also end
  at the line boundary; prose such as “Low risk overall” does not count. Failing either is
  exit 8 — **not** a pass. A single timeout is retried once internally; a second timeout is exit 124.
  And if the real tree is dirty *and* the brief names
  one of the uncommitted paths, it refuses (exit 2) before launching, because a review of a tree
  missing the file it was briefed on is worse than no review — a dirty tree whose dirty files are
  not named in the brief only warns, and `--allow-dirty` (`DISPATCH_ALLOW_DIRTY=1`) opts out.
* **codex** — `--sandbox read-only` is forced (an explicit `--ceremony` is overridden, and it says
  so) and the post-dispatch dep gate is skipped. There is **no** byte floor, **no**
  evidence gate, **no** isolated clone and **no** `REVIEW_OUTFILE`.
* **claude** — `--permission-mode plan` is forced (`--ceremony` ignored). Same story: the review's
  *content* is not gated at all.

In plain terms: outside agy, `--review` gets you sandbox/permission restriction and the source-state check —
an empty or one-line review comes back as the binary's own exit code, usually `0`. **codex is the
default runtime**, so a bare `dispatch-worker --review` is the ungated path; pass `--runtime agy`
if you want the review judged, or judge it yourself.

The clone mirrors the source's local branches, remote-tracking refs and tags at dispatch time.
Origin's fetch and push URLs point at a disabled path; fetch or rebase in the source before dispatching.

Other remotes and the operator's credential helper remain reachable, so the drift check,
not the clone, detects source changes. Git config,
refs and branches are private, and the reviewer gets a mode-0600 flattened copy of global Git
config via `GIT_CONFIG_GLOBAL`. Unsuitable repos (partial clones, filters, LFS or an invalid
HEAD) fall back to the live workspace, naming the reason and enforcing permissions instead of
passing `--dangerously-skip-permissions`. Allocation refusal remains exit 3.
`GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR`, `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY` and
`GIT_PREFIX` are cleared for repository operations and the review child.

Snapshots live separately from reviewer configuration, with no snapshot path in the
reviewer environment or brief. SHA-256 pins detect missing or modified baselines
and interim snapshots; tampering exits 10. The drift check also detects changes
to `info/exclude`, `info/attributes`, and `objects/info/alternates`.

Every runtime's `--review`, including fallback, snapshots source state before and after.
Unexpected config changes, hook changes, foreign committers on new local commits, or an
unreadable after-snapshot exit 10, overriding every post-launch result. A compare that
cannot complete is also critical (rc 10). Exclude and attributes changes warn; alternates and replace-ref changes are critical.
Other ref, worktree and working-tree movement warns unless new branch commits
have a foreign identity. Commits reachable from baseline refs or the after snapshot's `refs/remotes/*`
are exempt.
Changing a branch remote to `.` together with its merge target is critical. stderr reports
`DISPATCH_REVIEW_STATE=clean|warn(<n>)|critical(<n>)|skipped(<reason>) original_rc=<n>`:
clean means no drift; `<n>` in both `warn(<n>)` and `critical(<n>)` counts all change lines.
The closed skipped-reason set is `not-launched`, `not-a-git-repo`, `snapshot-failed`,
and `not-checked`. `original_rc` is the runtime
result before state classification; a runtime's native 10 is remapped to 1.

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
| `3` | the runtime binary is not on PATH, or no isolated review workspace could be allocated |
| `4` | `--require-dep` gate failed — a promised module is missing from `go.mod` |
| `5` | codex rejected every model at the auth/config layer. Fix auth; **do not** retry as a build. |
| `6` | codex hit a usage/rate limit. It can exit 0 on a zero-edit no-op, so this is detected from the limit signature *plus* an absence of substantive output. Treat as blocked. |
| `7` | agy is not authenticated (`agy` and sign in). Do not retry as a build. |
| `8` | review ran but output is below the byte floor or lacks evidence |
| `9` | effective agy model missing from live `agy models`; update `bin/lib/agy-models.sh` or the override |
| `10` | source repo changed during the review window or compare could not complete; inspect and restore named changes before committing, discard the body unless every change is known concurrent work, then re-run. Known residual: a review run can still execute a planted `filter.*.clean` during the after-snapshot's `git status`. |
| `124` | blocked (timeout; after one internal retry for agy `--review`) |
| other | the runtime's own exit code; native 10 is remapped to 1 during review |

Artifacts (agy `--review` only): the review is also tee'd to a file whose path is printed on
stderr as `REVIEW_OUTFILE=<path> (rc=<n>)`. If **you** set `REVIEW_OUTFILE`, that file is yours and
is kept; otherwise the file is an `$TMPDIR` temp and is deleted when `dispatch-worker` exits. The
codex and claude review paths write no such file. Capture stdout, not the path.

### Limits

The drift gate is detective. Under a same-user reviewer, these known limits are
not detected as critical:

- commits made with the operator's own identity;
- a commit exempted by a forged `refs/remotes/*` ref (warning, because concurrent pulls must not exit 10);
- foreign commits only on a detached HEAD or a tag (warning);
- untracked files hidden by an `info/exclude` change (an opaque warning);
- a pre-existing `branch.X.remote=.` combined with a `merge` change (warning);
- writes to ignored paths;
- a detached process acting after the final snapshot.

The remedy for all of these is OS-level containment: a sandbox profile, a
separate user, or a container that does not mount the source repository writable.
This boundary is not provided. Do not rely on the gate to block concurrent
integration; a concurrent pull or rebase during a review is reported as a warning.

Every review snapshot, and every `repo-state-check` snapshot or compare, has a
wall-clock bound, overridden with `DISPATCH_SNAPSHOT_TIMEOUT_SECS` (1-86400 decimal
seconds; anything else uses the default with a warning). The default is 120 seconds
for the dispatcher and 60 for `repo-state-check`. The dispatcher uses
`timeout -k` or `gtimeout -k`, with a watchdog fallback when neither is installed.
Snapshot timeouts are unreadable state and critical (exit 10), with the diagnostic
`drift snapshot timed out (possible hostile file such as a FIFO in the git dir)`.
The metadata sweep runs before bounded Git reads using directories resolved before review.
Nonregular metadata paths remain listed even when the snapshot times out. Nonregular
metadata present before launch is also critical (exit `10`).
The compare runs under the same bound; a compare timeout is critical. While an
interim or after snapshot or the compare is running, the exit status line reads
`DISPATCH_REVIEW_STATE=critical(incomplete)`, so a run killed in that window never
reports `skipped`.

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

## `wrap-merge-body.sh`

```
wrap-merge-body.sh --subject <subject> --body-file <file|-> [--out <file>]
                   [--config <commitlint.config.cjs>] [--wrap-only]
```

Wraps and lints a merge body **before** it becomes a squash commit. A squash merge composes the
landing commit from the PR title and body, which no per-commit lint has seen — so a violation
surfaces only on the push run after it has landed, where the message can no longer be rewritten.

The body arrives by file or stdin and is **never** a command-line word: `gh` reads a body whose
first line begins with `-` as options, and one carrying `-R owner/repo` would retarget the merge.
For the same reason this command accepts no repository or PR selector at all. Feed `--out` to
`gh pr merge --squash --body-file "$OUT" -- <pr>`, never `--body "$(…)"`.

Rules come from the committed `commitlint.config.cjs` — `--config`, else the invoking
repository's, else the copy shipped with this plugin. It never carries its own copy of the limit,
so what it wraps to and what the gate enforces cannot drift.

Trailers (`Refs:`, `Co-Authored-By:`, `Claude-Session:`, `Signed-off-by:` and friends) pass
through unfolded, because folding one breaks the `^Refs:( <repo>#N)+$` parse that closure tooling
depends on. An over-long trailer is reported with its remedy — split it across several trailer
lines — and still fails the lint rather than being quietly corrupted. A single token longer than
the limit (a bare URL) is refused rather than emitted as an over-long line.

Exit codes: `0` wrapped and clean; `1` a commitlint violation or an unwrappable token; `2` a
usage error, or commitlint/its config unavailable — an absent linter is a refusal, never a pass.

`--wrap-only` wraps and exits without linting, for the environments where commitlint is not
installed; it never claims a lint it did not perform.

## `mutation-verify.sh`

```
mutation-verify.sh [--copy-root <dir>] --file <path> --test-cmd <cmd>
                   (--mutate-sed <expr> | --mutate-cmd <cmd>)
                   [--expect-anchor <str>]... [--expect-marker <str>]...
                   [--syntax-cmd <cmd>] [--cover-check <line-or-symbol>]
                   [--expect-fail-output <str>]...
                   [--knockout-cmd <cmd> (--knockout-expect-output <str>... | --knockout-delta-line <prefix>)]
                   [(--control-sed <expr> | --control-cmd <cmd>)
                    --control-expect-fail-output <str>...
                    [--control-anchor <str>]... [--control-marker <str>]...]
```

Proves a test is load-bearing: break the code, confirm the test goes red, restore. It is
snapshot-backed: mutates the real file in place and restores it from a `mktemp` snapshot;
never run two in-place mutants concurrently in one tree — use `--copy-root` /
`mutation-sweep.sh` for parallel mutants. It **never** invokes git — the pass this exists to protect against is
`git checkout -- <file>` on an uncommitted diff, which restores the last commit and throws away
the in-flight fix while reporting a clean "mutation-proof" result.

A restore refreshes the file's mtime, forcing one rebuild of dependents. After a mutation,
it waits up to ~1s for the clock to pass the restore's start second before touching the file
(with a bounded wait and warning if the clock does not advance). This assumes 1-second mtime
granularity; 2-second FAT/exFAT timestamps are not covered.

`--test-cmd` runs **twice**: once as a baseline against the unmutated file (if that fails, the
instrument is invalid and it aborts before mutating anything) and once under mutation. The
applied-verification flags close the other false-pass route: `--expect-anchor` asserts the text
you intend to mutate is present *before* mutating, `--expect-marker` asserts your mutation
actually landed, `--syntax-cmd` rejects a mutation that merely broke the parse, and
`--cover-check` asserts the mutated function was actually executed (a mutation no test reaches is
`MUTANT-UNREACHABLE`, not a survivor).

`--expect-fail-output` checks the cause of a red run: the mutated run's combined output must
contain each given text, or the run failed for an unrelated reason, such as a changed error
message, and it exits `3` instead of reporting a catch. Treat exit `3` as a surviving mutant (a
test gap). Fix the text before the run. Replacing it after an exit `3` is legitimate only when
that run's output shows the hazard test itself failing at its own call site (not a shared
helper's line) (pytest's `>`
marker or `<file>.py:<line>` on the hazard assertion's line; Go's `<file>_test.go:<line>` of
that assertion), so only the rendering of the text was wrong. Then cite that location and both
runs in the review log. Otherwise the exit `3` stands as a survivor: a text copied from a red
run's output passes a rerun of the same deterministic mutant by construction.

Choosing the text: it must identify the hazard assertion uniquely and as it fails.
- **Unique at run time:** only the hazard test can make the text appear. A message literal that
  appears once in the test sources (`grep -rF '<message>' <test dirs>`) is not enough when it sits
  in a shared helper, a loop, or a parametrized test that other tests or cases reach: one literal,
  many places that fire it. A message several assertions share ("command failed") passes every
  other guard. Then the text must name the hazard test or its call site: pytest's short-summary
  line `FAILED <file>::<test>[<param>] - <rendered message>` (pytest cuts it at the terminal width,
  80 columns without a terminal, so keep the message short or set `COLUMNS`), or the caller's
  `<file>.py:<line>:` traceback line; in Go, the helper must call `t.Helper()` so the printed
  `<file>_test.go:<line>:` is the caller's line. A message built at run time (an f-string) has
  no literal to grep, so the same rule applies to its rendered form.
- **As it fails:** use the line the runner renders for a failure, not the bare literal, which is
  also in the test source; pytest's traceback prints the failing test function's source,
  including the message of a passing assertion above the failing one. The rendering depends on
  the assertion type: pytest shows a bare `assert x, msg` as `AssertionError: msg`, a
  unittest-style assert as `AssertionError: <detail> : msg`, and `pytest.fail` as `Failed: msg`.
  Go prints `<file>_test.go:<line>: msg` for `t.Fatal`.
- **Not:** runner-wide failure text alone (`FAILED`, `AssertionError`, `panicked`, `not ok`), the
  product's error text, or a test name alone; a failing run prints them for any cause. It is a presence check over all output, so it cannot
separate causes inside one snapshot or diff assertion. Empty, whitespace-only or multi-line text is
refused, and so is text the passing baseline already prints (exit `2`; with `--cover-check`, the
baseline runs with `-coverprofile` too). A caught verdict names the matched text, so the review
log can quote it. With the flag, each run's stdout and stderr are captured to a file and printed
together on stdout once the run finishes. Without the flag, a caught verdict says its cause was
not checked.

**Knock-out.** `--knockout-cmd` (only with `--expect-fail-output`) is the same test command with
only the hazard test deselected, plus a required scope proof: `--knockout-expect-output` (the
runner's deselection count) and/or `--knockout-delta-line` (a per-test line prefix). The deselect
must match exactly one test, and the default forms do not (pytest `--deselect` matches a node-id
prefix, cargo `--skip` a substring, go `-skip` an unanchored regex): a sibling with a common name
prefix is the very test the knock-out exists to keep. The knock-out is supported for three runners
only, in these exact forms:

| Runner | `--test-cmd` | append to make `--knockout-cmd` | scope proof |
|---|---|---|---|
| cargo | `cargo test -q`, no positional filter and no `--` section | `-- --exact --skip <path::name>` | `--knockout-expect-output '1 filtered out'` |
| go | `go test -v -count=1 <one package>` | `-skip '^TestName$'`, or `-skip '^TestName$/^row$'` for one table row | `--knockout-delta-line '=== RUN '` |
| pytest | `pytest -q <path>` | `--deselect <full node id, including any [param] id>` | `--knockout-expect-output '1 deselected'` |

The tool enforces these shapes: the part of `--knockout-cmd` after `--test-cmd` must be exactly
one of `-- --exact --skip <path::name>`, `-skip '^Name$'` / `-skip '^Name$/^row$'` (names of
letters, digits and `_`), or `--deselect <path::id>` (optionally single-quoted; the id may use only
letters, digits, `_ . / = , + @ - [ ]` and `::`), with nothing before or after it. For the cargo
shape, `--test-cmd` must not contain its own `--` section (such as `-- --nocapture`): the appended
`-- --exact --skip` would become a second `--`, and libtest would read every word after it as a name
filter that runs only the hazard test. An extra runner flag (`--lib`, `--ignore`), an
unanchored or unquoted go pattern, a cargo `--skip` without `--exact`, or anything chained after the
deselect is refused (exit `2`) before any test runs.

How the tool checks the scope proof, on the unmutated file and again on the mutant:
- `--knockout-expect-output '<n><rest>'` must start with its number, and `<n>` must be `1` (the
  knock-out removes only the hazard test; `0` would prove nothing). The tool sums the number in
  front of every `<rest>` in the output (the whole digit run, so `11 filtered out` counts as 11, and
  a digit right after `<rest>` disqualifies it). The full run's sum must be 0; the knock-out's sum
  must equal `<n>`. So two cargo test binaries that each print `1 filtered out` (a lib test and an
  integration test sharing a path, or two workspace members) sum to 2 and are refused.
- `--knockout-delta-line` must be exactly `'=== RUN '` (the go `-v` per-test line); it counts
  lines starting with that prefix: the knock-out must
  have exactly one fewer than the full run. For go `-v`, every test and subtest prints one
  `=== RUN ` line, so a name defined in both the internal and the external test package, a whole
  table skipped by its parent name, or a skip that reaches several packages all remove more than
  one line and are refused.
- cargo: `--exact` applies to any positional filter as well, and the count adds to tests the
  command already filters out, so keep `--test-cmd` free of positional filters (a full run that
  already prints a count is refused) and of a `--` section (refused).
- go: `-skip` applies in every package the command runs; name one package, never `./...`. To
  isolate one table row, skip the row, not the table.
- pytest: `-q` keeps the count to the one summary line (without it pytest prints `deselected` in
  the header too, and the sum is refused). `--deselect` is a prefix match (`test_x[1]` also removes
  `test_x[10]`); the summed count is what shows exactly one test went.

For any other runner (node included) there is no verified exact form: record the mutant as
UNPROVEN, never CAUGHT, until one exists.

Refusals, all exit `2`: an empty command; one that does not start with `--test-cmd` (the same
command plus a deselect) or is identical to it; a suffix that is not one documented deselect; a
cargo `--test-cmd` with its own `--` section; no
scope proof; a count line that does not start with its number, declares a count other than `1`, or
is empty or multi-line; a delta line other than `'=== RUN '`; one that is red on the unmutated file (a bad flag or
runner error would otherwise "confirm" by printing nothing); one whose baseline prints an expected
text, prints nothing, or prints exactly what the full baseline printed (a weak check: runners that
print timings never trip it); a scope proof that fails on the unmutated file or on the mutant (a
knock-out that crashes on the mutant cannot show its scope). It runs on the same mutated file only
when the main run would be CAUGHT (a RED run without the expected text stays exit `3`; a GREEN one
stays exit `1`). If its output still contains any expected text, another test prints it, or the
deselect missed the hazard test (unknown ids are often silently ignored): the run is refused (exit
`2`, naming the text). Only when the text disappears does CAUGHT stand; the verdict names the
command, its exit code on the mutant and the scope proof, and attributes the text to the test(s)
that command deselects. Without a knock-out it says "knock-out NOT run".

What it shows: with that command's one test removed and everything else the same, this mutant no
longer produces the text. What it does not show: which test was removed (a wrong but valid id that
removes exactly one other test passes; check the id against the hazard test); that the hazard test
failed for the reason its message names; or anything beyond one run. A sibling that prints the text
only sometimes (flaky), or only because of state the hazard test leaves behind (order dependence),
can vanish without the hazard test having printed it. Use a deterministic order, and prefer a
run-all command: a fail-fast run stops at the first failure, so the knock-out can stop before a
later test that would print the text (the verdict shows the knock-out's exit code on the mutant
for that reason); never combine fail-fast with a randomized order (`pytest -p randomly -x`,
`go test -shuffle=on -failfast`). The review gate requires the knock-out; a CAUGHT whose deselect
is not one of the forms above is UNPROVEN.

**Control mutant (recommended, not required).** `--control-sed` / `--control-cmd` (only with `--expect-fail-output`, and
always with `--control-expect-fail-output`, the line the control's own test prints when it fails)
uses the real file restored from the snapshot, then the control mutation, with the same no-op and
`--syntax-cmd` checks; `--control-anchor` / `--control-marker` verify it the way
`--expect-anchor` / `--expect-marker` verify the main mutation. It must edit only `--file`
(changes to other files are not restored). Its output is captured the same way. The control runs
only when the main run would be CAUGHT: a RED main run without the expected text stays exit `3`
and a GREEN one stays exit `1`, whatever the control is. Refusals, all exit `2`:
- the control's text already appears in the main run (the two failures cannot be told apart);
- the control leaves the test green (inert);
- the control's red run lacks its own text (a build break, crash or import error is not a control);
- the control's red run prints ANY expected text (with several texts, drop the generic one).

Otherwise the verdict says the control "went RED for its own reason without the expected text",
flagged `[UNVERIFIED CONTROL]` unless `--syntax-cmd` checked the control-mutated file (a marker proves
the edit landed, not that the file is valid). The main mutant keeps its older rule: a marker or a
`--syntax-cmd` clears `[UNVERIFIED APPLICATION]`, because a broken main mutant shows up as a RED
run the expected text then has to explain, while a broken control would pass its check by
crashing. Without a control, a caught verdict says the control did not run. Without any
control flag, behavior is otherwise unchanged.

What one passing control shows, and what it does not: it shows that this one other failure does
not print the expected text. It does not show that the text in the main run came from the hazard
test rather than another test that shares its helper, loop or parametrization. A control that
breaks such a sibling, with a `--control-expect-fail-output` that names that sibling's test, rules
out that one sibling only (its text in the main run is refused); other siblings stay unexcluded.
The knock-out is the direct check. A control red for a value-bearing message (`6 != 5` vs `4 != 5`)
passes by construction, so expected texts must not embed mutant-specific values. A refusal is
evidence that the text is not specific, not a bad pick: it stands, unless the refused run's output
shows the hazard test itself failing at its own call site. Record every control you tried, with
its verdict, in the disposition row.

Picking a control: a mutation that breaks a **different** behavior a test checks, preferably one
whose test shares the hazard test's helper, loop or parametrization, since that is the sibling
whose failure could otherwise print the same text. Flip a neighbouring condition, change another
return value, or drop a different guard that the sibling test asserts. A scoped single-test
`--test-cmd` makes every different-behavior control inert; use the whole suite or file the hazard
test lives in. The review gate requires `--expect-fail-output` and `--knockout-cmd` for every
mutation check it relies on and recommends a control; when the runner cannot deselect the single
hazard test, or no hazard-specific text exists, or a refusal stands, the mutant is UNPROVEN, never
CAUGHT. Every CAUGHT row in a review log quotes `matched:` and the knock-out and control clauses.

Exit codes: `0` the test caught the mutation, `1` false green, `2` harness error (bad args,
failing baseline, no-op mutation, failed verification, failed restore, an
`--expect-fail-output` or `--control-expect-fail-output` text that is empty, multi-line or printed
by the passing baseline, a refused knock-out, or a refused control), `3` a
red run without the `--expect-fail-output` text (the hazard assertion is not shown to have caught
the mutant).

### Copy mode

In copy mode (`--copy-root`) a control is required, which runs first as a canary; a copy-mode or parallel exit 1 or 3 is INCONCLUSIVE until a serial in-place run confirms it. In place, a control remains recommended, not required.

`--copy-root <dir>` canonicalises the root and subject's parent directory with
physical paths, accepting `--copy-root .` and roots reached through symlinked
paths. The subject must be under the root; a symlink subject is refused. A
`TMPDIR` inside the root is refused to prevent recursive copying. Copy failures
abort with exit `2` and clean up partial copies. `--cover-check` is refused in
copy mode. A control and its own expected failure text are required.

One pristine snapshot excludes the root's `.git` entry. Three independent phase
copies come from that snapshot: baseline (shared with the baseline knock-out),
then the control as a canary, then the main mutant (shared with the mutant knock-out).
Commands run with the caller's cwd mirrored into each copy; a caller cwd outside
`--copy-root` is refused with exit `2`. The real subject is
never written or restored by the tool.

Write subject paths relative to the cwd or as `'$MUTATION_VERIFY_FILE'`.
A command that names the root literally aborts (including canonical `/var` and
`/private/var` spellings); other escapes (aliases, env, PATH) are caught by the canary.
Single-quote commands at the calling shell so variables expand inside the copy.
`MUTATION_VERIFY_COPY_ROOT` and `MUTATION_VERIFY_FILE` are output-only variables
provided to commands, naming the current phase root and absolute copied subject;
caller values are never read as inputs.

A green canary exits `2` with:

```text
mutation-verify.sh: CONTROL STAYED GREEN IN THE COPY — the test did not read the copy, or the control is inert; run the control in place to tell which tree=<h>
```

A red control without its own expected text exits `2` with
`CONTROL RED FOR AN UNRELATED REASON`. A CAUGHT verdict retains the control clause
and adds `; control ran first (canary)`. Exit `1` or `3` also records that the
control ran first, and ends with
`; INCONCLUSIVE in copy mode — confirm with a serial in-place run tree=<h>`.
Confirm these outcomes serially in place before treating them as test gaps.
The scope is narrow: the canary proves only that the control's test path reads the copy; a hazard-only
escape yields a false survivor, which is why exit 1/3 are INCONCLUSIVE.

The verdict-line marker is `mutation-verify.sh: `: select the LAST line starting
with it, excluding `mutation-verify.sh: hint: ` lines, which are advice.
Every terminal verdict or refusal after the pristine snapshot exists ends with
` tree=<h>`, a checksum of sorted relative paths, file contents, file modes and symlink targets
(excluding mtimes and the snapshot location). Pre-snapshot refusals have no hash;
in-place output has no `tree=`. Copy-mode messages retain the caller's `--file`
spelling.

Baseline and control copies are deleted as soon as their phases finish. On a
non-APFS `TMPDIR`, allow disk space for the pristine tree plus the live phase
copy and capture output per worker; a sweep also retains its shared snapshot.
APFS clonefile may reduce physical use but is not assumed.
The post-command capture probe detects storage write failures. A residual limit:
if a test fills the disk and frees it before the probe, truncated capture output
may go undetected.

**Changed:** in-place advice lines now use the `mutation-verify.sh: hint: ` prefix;
terminal verdict text keeps its existing meaning.

Copy mode isolates only the source tree, not `$HOME`/ports/caches. Tests must avoid
shared external state or allocate their own resources. A concurrent in-place run
in the same tree is unsupported.

## mutation-sweep.sh

```text
mutation-sweep.sh --copy-root <dir> --mutants <file> [-j N] [--timeout S] [--out <dir>]
```

Run from inside the root (including a subdirectory). The sweep snapshots the tree
once, excluding `.git`, then runs every mutant from that snapshot with the cwd
mirrored. Edits to the live tree during the sweep do not change the tested tree.
Keep `TMPDIR` outside the root. Each mutant uses copy mode and must supply a
control; the copy-mode restrictions and canary checks above apply.

The mutants file contains one shell-quoted argument list for `mutation-verify.sh`
per line, without the command name or `--copy-root` (supplied by the sweep).
Blank lines and lines whose first non-whitespace character is `#` are ignored.
Use a relative `--file`; absolute values of `--file` and references to the real
root are refused. Other arguments may begin with `/`, including sed expressions.
Executable command substitutions (`$(...)` and backticks outside single quotes)
and process substitutions (`<(` and `>(`) are refused. Unquoted shell operators
(`; & | < >`), newlines, and ANSI-C quoting (`$'…'`) are also refused.
Argument parsing runs in an empty scratch directory. This check is a guard,
not a sandbox. Single-quote command strings and
variables such as `'$MUTATION_VERIFY_FILE'` so they expand in the phase copy.
Treat the file as trusted shell input, not a sandboxed data format.

Concurrency defaults to min(cores, 8). `MUTATION_VERIFY_SWEEP_JOBS` supplies the
default; `-j N` overrides it. Both require a positive decimal integer. Each worker
sets `RUN_TESTS_JOBS=1` to avoid nested suite parallelism.
`--timeout S` overrides `MUTATION_VERIFY_SWEEP_TIMEOUT` (default `600`); both
require a positive decimal integer. Each mutant uses `timeout -k 20`, then
`gtimeout` if available, otherwise a poll-loop watchdog. A watchdog timeout or rc `124`
is reported as `TIMEOUT` and counts as an error. Other rc `137` exits are
labelled `killed (rc 137)`. A leftover-process mutant is counted as an error
(rc 4), after a 50-poll (about five-second) leader-exit grace. `-h` / `--help` prints
usage, line rules, environment variables and exit codes.

`Sweep dir: <path>` identifies retained results, either `--out` or a temporary
results directory. For each mutant's original line number `<n>`, `<n>.out` holds
combined output, `<n>.rc` the mutation exit code and `<n>.verdict` the extracted
verdict line. Existing result files are refused rather than overwritten.
Per-mutant lines and the final summary appear in input order:

```text
MUTANT <n> rc=<rc> <verdict line>
SWEEP: <c> caught, <u1> unconfirmed-survived, <u3> unconfirmed-unrelated, <e> errors, <m> missing of <N> tree=<h>
```

Counts classify mutation exit `0` as caught, `1` as unconfirmed-survived, `3`
as unconfirmed-unrelated, and other codes as errors. Every copy-mode exit `1`
or `3` is INCONCLUSIVE. Missing rc or verdict files and `not-run` results count as missing.
Exit precedence: missing (1) wins over errors (4). The summary
hash identifies the single sweep snapshot.

| Exit | Meaning |
|---|---|
| `0` | All N results present, no errors; every mutant measured |
| `1` | Missing results |
| `4` | Errors: refusals, canary, TIMEOUT, or rc ≥ 2 except 3 |
| `2` | Usage or setup failure |
| `130` / `143` / `129` | INT / TERM / HUP |

One progress line per finished mutant is printed to stderr. On a signal, the
sweep stops workers, prints partial `MUTANT` lines and a summary, and retains
results. Workers stop launching mutants if the parent dies, terminate their own
mutant group, and record `not-run`. Startup reaps stale sweep and copy directories
owned by dead processes. Finished groups are never signalled. Unfinished groups
receive TERM then KILL after 20 seconds; a mutant leaving processes behind gets
`left processes running` in its verdict. Inspect individual verdicts as well as
the sweep exit code.

Never run two in-place mutants in one tree. Confirm serial-equal verdicts once
for your suite before relying on parallel runs: a parallel exit 0 is only as trustworthy as the suite's parallel-safety; the one-time serial-equal confirmation must include caught mutants. A copy-mode or parallel exit `1`
or `3` is inconclusive until confirmed by a serial in-place run. Source copies
do not isolate `$HOME`, ports or caches: avoid shared state and bound concurrency
to the suite's resource budget; do not overlap an in-place run in the same tree.

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
review-gate brief       --persona <peer-X-reviewer> --mode <design|build|requirements> --for <claude|cross-model>
                        (--range <A..B> | --spec <path>...) [--source <path>]... [--what <text>]
                        [--repo-root <dir>] [--closing-template <path>]
review-gate cross-model [--runtime <agy|codex>] [--timeout <dur>] [--workdir <dir>] --brief <path>...
review-gate log-new     --topic <slug> [--mode <design|build|requirements>] [--persona <name>]...
                        [--project <slug>] [--design-round <label|none>] [--stdout] [--force]
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
requires `--spec` and forbids `--range`; `--mode build` is the reverse; `--mode requirements`
behaves like `design` (requires `--spec`). `--for cross-model` prepends
the full persona body (another runtime cannot auto-load it); `--for claude` omits it. Both append
`templates/review-brief-closing.md`, which carries the "return exactly this structure" instruction
and the file:line requirement — one source for both routes.

**`cross-model`** runs each `--brief` through `dispatch-worker --runtime <agy|codex> --review`,
**serialized, never concurrent** (agy has a wedged-shared-session risk). Each review is printed to
stdout under a `===== review: brief N =====` header, followed by a summary line per brief carrying
its own rc and body length. The process **exits with the worst rc across briefs**, so read the
per-brief rc from the summary rather than `$?`. Pass **`--workdir <dir>`** to override the checkout
`dispatch-worker` reviews for every brief for both `agy` and `codex` runtimes; by default each
brief uses its own declared `repo root:` line, falling back to the current directory only when that
line is absent. Beyond
`dispatch-worker`'s own gating it applies a
last-resort backstop: a body under 400 bytes on an otherwise-clean rc is re-reported as `8`, because
a short no-findings sign-off must never count as a review. It never retries — rc 8 means fall back
to a local reviewer for that lens, not run it again.

`log-new --design-round <label|none>` records the design review round in the log header; `none` records a deviation for a measurement-shaped change.

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
authenticated, `8` empty/short/evidence-free review, `10` source repo changed during the
review window, `124` timeout. On 10 it stops dispatching, lists skipped briefs, and exits 10
regardless of other results. Inspect and restore named changes before committing and re-run;
discard the body unless every change is known concurrent work.

## `drive-cold-session.sh`

```
drive-cold-session.sh [--model M] [--approve] [--timeout S] <claude|codex|agy> <workdir> <prompt-file> [session-name]
```

Creates a **detached tmux session** running the agent in `<workdir>`, waits for boot to settle,
pastes the prompt as one bracketed-paste block, submits it with a single Enter, polls until the
screen stops changing, prints the transcript, and **leaves a live session running** for you to
inspect or continue. Dead sessions are removed after their last screen is printed. `--approve` auto-approves tool calls so an unattended run doesn't stall on a
permission prompt (claude/agy: `--dangerously-skip-permissions`; codex:
`--dangerously-bypass-approvals-and-sandbox`) and best-effort accepts agy's folder-trust prompt.
Env: `DCS_BOOT_MAX` (60), `DCS_SETTLE_MAX` (240), `DCS_STABLE` (3), `DCS_INTERVAL` (2),
`DCS_COLS` (200), `DCS_ROWS` (200), `DCS_KILL=1` to kill the session after printing,
`DCS_DEBUG=1` to print the alternate-screen state after boot. The agent pane history limit is at least 50000 lines;
codex launches with `--no-alt-screen` and Claude Code with `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1`.
Codex daemon-settings, update-choice, model-offer, and folder-trust screens, plus Claude folder-trust and bypass-permissions screens, stop before the prompt is pasted; the session stays up
for a human to answer unless `DCS_KILL=1`.
agy has a user-selectable altscreen display mode; the driver cannot switch it, so agy must be in inline mode or runs end with exit 6.

Exit codes: `0` complete transcript; `1` unexpected error; `2` usage or missing prerequisite;
`3` did not settle (stdout holds the transcript so far); `4` boot interstitial needs a human;
`5` agent exited (stdout holds the full transcript if it exited after replying);
`6` alternate-screen mode prevents transcript completeness verification. Only `0` confirms completeness.

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

## `review-log-status`

```bash
review-log-status [--archive] <path>
```

Checks a review log from any current directory, resolving its Git work tree from the path's
directory. Prints `committed` (exit 0) only when the path exists in HEAD and its index and working
tree match HEAD; this is the state that permits a shipped claim or repo link. `staged` (exit 6)
means the path is in the index but new or changed: commit it, then re-run. `untracked` (exit 3)
means run `git add` and re-run, unless deliberately keeping a draft uncommitted; say so in the
report. `ignored` (exit 4) names the matching ignore rule on stderr and gives local-only guidance.
`missing` exits 5, including when the parent directory is absent. Bad usage, a path outside a Git
work tree, or a Git error exits 2. A clean `git status` is not evidence that an ignored log was
included.

`--archive` must precede the path and only acts on `ignored` logs. It reads
`PEER_REVIEW_LOG_ARCHIVE`; if that variable is unset or does not name an existing directory, the
log stays local-only. An archive directory inside the log's repository is refused. Otherwise the
command prints `archived <dest-path>` on a second stdout line and still exits 4. The copy is
written without overwriting, using a short content hash before the original extension. Repeating
an archive of identical content reuses its path. Requirements-mode logs append rounds; archiving
after a new round creates a new hashed snapshot. File modification time identifies the newest
snapshot. For any ignored log, include the gate's rounds, reviewers, and disposition counts in
the PR body, whether archived or local-only.

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

PASS    1. all 13 entrypoints on PATH + executable
PASS    2. lib/ is not on PATH (…/agent-dispatch/bin/../lib)
PASS    3. codex on PATH (/usr/local/bin/codex)
PASS    4. agy on PATH (/usr/local/bin/agy)
PASS    5. agy models: OK
PASS    5. coding default model present: <coding pin>
PASS    5. review default model present: <review pin>
PASS    6. shellcheck clean (entrypoints, severity>=warning)

Summary: 0 fail, 0 warn
```

Exit codes, in **both** verify and `--install` mode: `0` all pass, `1` any FAIL, `2` any WARN and no
FAIL. So an `--install` that skipped an entrypoint (a foreign symlink it refused to replace) exits
2, not 0 — an installer script must not read that as "done". If `~/.local/bin` is not on your
`PATH`, `--install` tells you and prints the line to add to your shell profile.

## run-tests.sh

```text
bash bin/run-tests.sh [-h|--help] [-j <jobs>] [--timeout <seconds>]
bash bin/run-tests.sh [-h|--help] [-j <jobs>] [--timeout <seconds>] --only <suite>[,<suite>...]
bash bin/run-tests.sh [-h|--help] [-j <jobs>] [--timeout <seconds>] --changed [<base>]
```

Run from the plugin directory, or use `bash agent-dispatch/bin/run-tests.sh` from the
repository root. The full gate discovers `bin/test-*.sh` and `test/*.sh`, sorts them,
and runs suites in parallel through `xargs -0 -P N`. Each suite receives stdin from
`/dev/null`; failures do not stop the remaining suites and are never retried.
After a full run, shellcheck checks executable non-test `bin/` entrypoints at
`--severity=warning` when installed. Zero discovered suites is a failure.

`-j` overrides `RUN_TESTS_JOBS`; `--timeout` overrides `RUN_TESTS_TIMEOUT`.
Jobs default to min(cores, 12), using `nproc` (honors CPU affinity/cpuset), then
`getconf _NPROCESSORS_ONLN`, then `sysctl -n hw.ncpu`, then 2.
On quota-limited containers set `RUN_TESTS_JOBS` explicitly, because core counts may not reflect a CPU quota.
The per-suite timeout defaults to 420 seconds, with
`timeout -k 15` (or `gtimeout -k 15`) giving a 15-second kill grace. Both numeric
settings, including environment values, must match `^[1-9][0-9]*$`; invalid values
exit 2. When neither timeout executable is available, the worker poll loop enforces
the same limit and 15-second kill grace:

```text
run-tests.sh: NOTICE: no timeout/gtimeout found; enforcing timeout in worker poll loop
```

`--only` accepts comma-separated bare basenames or exact plugin-relative suite paths.
Repeated `--only` values append to the selection. Repository-relative paths such as
`agent-dispatch/bin/test-x.sh` are also accepted. Unknown, empty, or ambiguous names
are selection errors; duplicates are removed. `-h` / `--help` prints usage and exits 0.
Usage errors print a `run-tests.sh: <reason>` and one-line usage to stderr before
creating a run directory.
`--only` and `--changed` are mutually exclusive.

`--changed [<base>]` combines committed changes (`<base>...HEAD`), staged changes,
unstaged changes, and untracked files. Without a base it uses the merge base of
`HEAD` and the remote default branch (`refs/remotes/origin/HEAD`), so already-pushed
branch commits remain visible. Changed discovered suites select themselves. Other
files select suites mentioning their repository-relative path, plugin-relative path,
or basename. A deleted suite, another `bin/` or `tools/` change
(`FULL GATE: code change`), or a file whose basename is referenced by a non-test file under `bin/` forces the full gate. So do a file with
no matching suite, no changed files, an unavailable Git repository or base, or a
failed Git change listing. Each fallback prints `FULL GATE: <reason>` and restores
full-gate semantics. An explicit invalid base exits 2 with
`run-tests.sh: unknown base: <base>`; only default-base resolution failure falls back.

Iterate with `--changed`/`--only`; run the full gate before each review round and
before handing back; a partial run exits 4 and is never the gate. A
`coding-dispatch.sh` build command invoking a signature-bearing runner with a
whole `--only` or `--changed` token in the same simple command is refused with
exit 2 before agent launch; use the full runner. Other runners get an advisory. Give
`mutation-verify.sh --test-cmd` a suite directly, never `run-tests.sh --only`.
Use **one tree, one runner**: do not overlap runners in the same checkout.

| Exit | Meaning |
|---|---|
| `0` | Full run: all suites passed; shellcheck passed or is not installed |
| `1` | Zero suites; any suite FAIL, TIMEOUT, KILLED, or missing/invalid result; or shellcheck failed |
| `2` | Usage or selection error |
| `4` | PARTIAL-PASS: every selected suite passed |
| `130` / `143` / `129` | Interrupted by INT / TERM / HUP |

The first output line is `Run dir: <path>`. The directory is created outside the
tree with `mktemp -d "${TMPDIR:-/tmp}/run-tests.XXXXXX"`. It holds per-suite logs,
exit codes (`<key>.rc`), and durations (`<key>.secs`); `<key>` is the plugin-relative
path with `/` replaced by `__`. Exit codes and durations are written atomically
through temporary files and `mv`. The directory is retained on failure and
interruption; passing full and partial runs remove it unless `RUN_TESTS_KEEP_LOGS=1`.

Suite starts stream immediately; the summary prints one result per suite sorted by
name, using the bare suite basename and integer elapsed seconds:

```text
RUN  <suite>
PASS <suite> (<s>s)
FAIL <suite> (exit <rc>, <s>s)
TIMEOUT <suite> (<s>s)
KILLED <suite> (<s>s)
```

TIMEOUT and KILLED mean the runner enforced the limit (TERM and KILL respectively).
A suite returning 124 or 137 itself is an ordinary FAIL. Enforcement reasons are
stored in `<key>.why` as `timeout` or `killed`. If a suite exits but leaves its
process group running, the runner waits at least 50 polls of 0.1 seconds (a true
5-second grace), terminates the leftovers, and
prints `FAIL <suite> (exited N; left processes running)` both live and in the
summary. Its `.rc` is `leaked` and its `.why` contains `leaked`; the result
alone counts as failed even if the diagnostic sidecar is absent.
The summary block is authoritative and computes every verdict from result files
only. A missing or unrecognised result (other than `leaked`) appears as `FAIL <suite> (no result)`.
Interrupted suites without a result or with `not-run` appear as `NOT RUN <suite>`:

```text
FAIL <suite> (no result)
Summary: <p> passed, <f> failed, <n> total
```

After execution, full and partial runs print in this order:

1. Per-suite summary lines, sorted by name.
2. `Summary: <p> passed, <f> failed, <n> total`.
3. `Slowest suites:` and up to five timing lines.
4. Failed-suite log tails (last 20 lines); `CI=true` prints full logs. Missing logs and their `Log tail:` headers are omitted.
5. `SKIP <suite>: <text>` for every log line starting with `SKIP`, sorted by suite; `<text>` is the full log line.
6. Shellcheck output, for full runs only.
7. `Total wall: <s>s`.
8. The final line:

```text
GATE PASS: all <n> suites passed; shellcheck passed
GATE PASS: all <n> suites passed; shellcheck skipped (not installed)
GATE FAIL: <f> of <n> suites failed
GATE FAIL: <f> of <n> suites failed; shellcheck failed
```

Missing shellcheck prints this notice before the total wall time:

```text
run-tests.sh: NOTICE: shellcheck not found; skipping shellcheck --severity=warning
```

A partial run ends with `PARTIAL RUN: <k> of <n> suites — NOT the gate`, where
`<k>` is the selected count and `<n>` is the discovered count. Failed partial runs
exit 1 rather than 4.

On INT, TERM, or HUP the runner stops dispatch, sends TERM to recorded process
groups, allows a 10-second interrupt grace, then sends KILL to those groups.
The parent signals only recorded live groups without a result; a wrapper may
signal both the group and its bare child PID, guarded by `kill -0` before reaping.
It never uses `pkill` or `killall`.
It ends with `INTERRUPTED: <d> finished, <k> not run` then `Total wall: <s>s`,
with no verdict line, and retains the run directory.
A runner started as a background `&` job of a non-interactive script ignores INT
(POSIX); stop it with TERM. Suite TERM traps must be idempotent because GNU timeout
can deliver TERM more than once.
A suite counts as finished if its `.rc` was written before the `INTERRUPTED`
sentinel, regardless of whether it passed.

If `ps` is unavailable, the runner prints
`run-tests.sh: NOTICE: ps not found; runner identity check disabled (liveness only)`.
Wrappers then use PID liveness alone. Empty or failed `ps` output is also treated
as unknown identity; only a definite parent mismatch stops a wrapper.

### Changed from the previous runner

- Suites run in parallel by default, so shared global state can now race.
- Suite stdin is `/dev/null`.
- There is a per-suite 420 s timeout.
- Unknown arguments exit 2; previously they were ignored.
- No fail-fast: all selected suites run.
- Failure/usage/partial-pass exits are now 1/2/4 rather than the failing suite's rc.
- Per-suite lines carry timing; suite output goes to per-suite logs.
- The `failing suite:` line is replaced by the summary block and `GATE FAIL:`.

## Environment variables

| Variable | Read by | Default / effect |
|---|---|---|
| `MUTATION_VERIFY_COPY_ROOT` | commands in `mutation-verify.sh` copy mode | output-only current phase root; caller values are not inputs |
| `MUTATION_VERIFY_FILE` | commands in `mutation-verify.sh` copy mode | output-only absolute copied subject path; caller values are not inputs |
| `MUTATION_VERIFY_SWEEP_TIMEOUT` | `mutation-sweep.sh` | 600 seconds; positive decimal integer; overridden by `--timeout` |
| `MUTATION_VERIFY_SWEEP_JOBS` | `mutation-sweep.sh` | min(cores, 8); positive decimal integer; overridden by `-j` |
| `RUN_TESTS_JOBS` | `run-tests.sh` | min(cores, 12), detected via `nproc`, then `getconf _NPROCESSORS_ONLN`, then `sysctl -n hw.ncpu`, then 2; positive decimal integer; overridden by `-j` |
| `RUN_TESTS_TIMEOUT` | `run-tests.sh` | `420` seconds per suite; positive decimal integer; overridden by `--timeout`; kill grace 15 seconds |
| `RUN_TESTS__TEST_KILL_GRACE` | `run-tests.sh` | test-only TERM-to-KILL grace override; positive integer seconds (default `15`) |
| `RUN_TESTS_KEEP_LOGS` | `run-tests.sh` | `1` retains logs after a passing full or partial run; failure and interruption always retain them |
| `CODING_DISPATCH_TIMEOUT` | `coding-dispatch.sh` | `15m` (codex) / `25m` (agy) — the external bound on the agent |
| `CODING_DISPATCH_WORKTREE` | `coding-dispatch.sh`, `coding-build-phase.sh` | the worktree/branch slug; a worktree with that slug is reused so a multi-task phase accumulates on one branch |
| `CODING_DISPATCH_RM_ON_FAIL` | `coding-dispatch.sh` | `1` = remove the worktree on failure instead of salvaging it; the patch still survives under the parent repo's git dir |
| `CODING_DISPATCH_MUT_EXEMPT` | `coding-dispatch.sh` | whitespace-separated basename globs (default `test-mutants*`), split without pathname expansion. Only dedicated mutation-suite files are exempt by default; directories never confer exemption. Each exempt file containing added marker lines prints its path, matching glob, and marker-line count (all marker lines for untracked files). Setting the variable prints an override-in-effect line including its value; an empty value scans every file. Globs matching any probe basename (`zz9-probe.x`, `main.go`, or `README`), including `*`, `**`, and `?*`, are refused with a stderr warning and do not exempt files. Globs containing `/` are also warned about and ignored because globs match basenames only. Leftover mutants must be removed; refusals name the tracked or untracked file. |
| `CODING_DISPATCH_CHILD_ENV` | `coding-dispatch.sh` | whitespace-separated `KEY=VALUE` pairs exported into the dispatched agent's environment, e.g. `"MYREPO_LEDGER=off CI=1"`. Malformed entries are reported on stderr and skipped. |
| `PEER_REVIEW_LOG_ARCHIVE` | `review-log-status --archive` | existing directory outside the log repository for ignored-log snapshots; unset leaves the log local-only |
| `CODING_DISPATCH_PREAMBLE` | `coding-dispatch.sh` | path to the file holding the dispatch-preamble block (default: the plugin's `docs/dispatch-preamble.md`). A missing or empty block is a hard refusal (exit 2) before any side effect — a brief without the ground rules is the failure this exists to prevent. |
| `CODING_BUILD_CMD` | `coding-build-phase.sh` | default for `--build-cmd` |
| `CODING_BUILD_PLAN_CONTEXT_MAX` | `coding-build-phase.sh` | `12000` — character cap on the plan-preamble `PLAN CONTEXT` block sent with every task; positive decimal integer (leading zeros accepted; zero rejected with exit 2). A longer preamble is cut with a worker note naming the absolute plan path and one stdout warning per phase |
| `CODING_COMMIT_SCOPE` | `coding-build-phase.sh` | conventional-commit scope (default: repo dir basename) |
| `AGY_MODEL` | `coding-dispatch.sh` | agy model for edit dispatches (default: coding pin in `bin/lib/agy-models.sh`) |
| `DISPATCH_NO_VENV` | `gate-run.sh` via `lib/gate-env.sh` | any value = same as `--no-venv` |
| `DISPATCH_GATE_ADVISORY_TTL_SECS` | `coding-dispatch.sh` | `3600` — how long skipped gate-target advisories are deduplicated; partial-runner refusals are never deduplicated |
| `DISPATCH_REVIEW_PIN_TTL_SECS` | `review-pin.sh` | `14400` — after this a pin is stale and auto-removed |
| `RUNTIME`, `MODEL`, `WORKDIR`, `MODULE_DIR`, `CEREMONY`, `REVIEW` | `dispatch-worker` | env twins of the matching flags |
| `TIMEOUT` | `dispatch-worker` | `15m`; `0` or `none` disables the external bound |
| `KILL_AFTER` | `dispatch-worker` | `30s` grace before SIGKILL (`timeout -k`) |
| `REVIEW_OUTFILE` | `dispatch-worker` | where to tee the review. Supplying it means **you** own the file and it is retained. |
| `DISPATCH_MIN_REVIEW_BYTES` | `dispatch-worker` | `1200` byte backstop for `--review` |
| `DISPATCH_REVIEW_REQUIRE_EVIDENCE` | `dispatch-worker` | exactly `0` disables the labelled-severity / `file:line` evidence gate |
| `DISPATCH_REVIEW_WT_DIR` | `dispatch-worker` | preferred parent directory for private review clones; stale clones older than six hours may be reaped across sibling repos |
| `GIT_CONFIG_GLOBAL` | agy review child | private flattened global config copy in hermetic mode; writes stay in the run |
| `DISPATCH_REVIEW_STATE` | stderr output, not an input knob | `clean`, `warn(<n>)`, `critical(<n>)`, or `skipped(<reason>)`, followed by `original_rc=<n>` |
| `DISPATCH_ALLOW_DIRTY` | `dispatch-worker` | `1` = warn instead of refusing when a review brief names an uncommitted path |
| `DISPATCH_LIMIT_NOOP_BYTES` | `dispatch-worker` | `200` — stdout below this, plus a rate-limit signature, is read as a limit no-op (exit 6) |
| `CODING_PREFLIGHT_CODEX_PROBE`, `CODEX_EXEC_PROBE_TIMEOUT` | `coding-preflight.sh codex` | enabled unless exactly `0`; `75s` timeout |
| `AGY_FORM_PROBE_TIMEOUT`, `AGY_BIN` | `coding-preflight.sh` probes | `30s`; the agy binary to probe |
| `DCS_BOOT_MAX`, `DCS_SETTLE_MAX`, `DCS_STABLE`, `DCS_INTERVAL`, `DCS_COLS`, `DCS_ROWS`, `DCS_KILL`, `DCS_CLOSE` | the drive scripts | see above |
| `TMPDIR`, `XDG_CACHE_HOME` | several | honoured for temp files, gate logs, and review-clone fallbacks |

`review-gate cross-model --model <id>` forwards a one-off model override.
Exit 9 means model not offered in `dispatch-worker`; in `coding-dispatch.sh` and
`coding-build-phase.sh` it means review-pin refusal.

## review-clone.sh

```text
review-clone.sh <src> <dest> [<sha>]
review-clone.sh --remove <abs parent> <that path>
review-clone.sh --help | -h
```

Builds a disposable local clone detached at the supplied SHA (default source HEAD), with
hardlinked objects where possible and no alternates. Mirrors local branches, remote-tracking
refs and tags; origin's fetch and push URLs point at a disabled path. Other remotes and the
operator's credential helper remain reachable, so the drift check, not the clone, detects
source changes. Config and refs are private. On success it prints `<dest> <resolved-sha>`
to stdout. It verifies a
clean checkout and matching refs. Exit 0 means success; 3 refuses an unsuitable path or source;
4 means a faithful checkout is unavailable (including filters, LFS, partial clones or invalid
HEAD), allowing the dispatcher's non-hermetic fallback. Invalid CLI arguments exit 64.
Source must be an absolute work-tree path. Destination must be absolute, not symlinked, without a trailing slash, and named
`dispatch-review-wt.*` under an existing parent. It may be absent or an existing empty
directory owned by the current user with mode 700.
Guarded removal requires an absolute,
non-symlink path directly under the resolved parent, with no trailing slash and a basename
matching `dispatch-review-wt.*`. Failed builds use guarded cleanup too.
The clone does not mirror branch upstream config (`@{upstream}`), `stash@{n}`,
`refs/notes/*`, `refs/replace/*` or reflog forms; brief authors should use explicit
`origin/<x>` ranges.

## repo-state-check

```text
repo-state-check snapshot <abs-repo-dir> <file>
repo-state-check compare <before> <after>
```

Snapshot records effective config (including worktree config), hook hashes and modes, refs,
worktrees, dirty paths and configured identity. Files are mode 0600; keep them in a private
temp directory and remove them after inspection. Snapshot exits 0 on success or 3 for an
empty, relative or invalid repository path, a missing hasher, unreadable config or metadata files, or a hash failure in config.
Snapshot exit 3 also means "not evaluated": a timeout, a missing completion record or an
unexpected failure of the bounded git reads. The output file is replaced with `unreadable`
before any other work, so a stale or partial snapshot is never left readable (any special
files found in git metadata are listed after it). The snapshot is published by rename only
once complete. The git reads are killed after `DISPATCH_SNAPSHOT_TIMEOUT_SECS`
(1-86400 decimal seconds; default 60 for this command, 120 for `dispatch-worker`; an
invalid value uses the default with a warning) plus a 5 second kill grace; raise the
limit and the calling tool's own timeout for very large repositories.
A timeout message lists special files found in git metadata (what was found, not a proven
cause), or says none were found, or that the pre-sweep was skipped. A successful snapshot
whose baseline already holds special files warns on stderr and still exits 0.
Invalid CLI arguments exit 64.
Snapshots also hash `info/exclude`, `info/attributes`, and
`objects/info/alternates`; changes to these files are critical.

In `dispatch-worker` review runs, snapshots live separately from reviewer
configuration, with no snapshot path exported or included in the brief. Every
snapshot is SHA-256-pinned in a dispatcher shell variable. A missing or modified
snapshot is critical (exit 10), even if a same-user reviewer discovers its path.
Nonregular files in Git metadata are reported before config and ref reads, so their
names remain visible on stderr even if a later Git read times out.

Compare prints named change lines and exits 0 for clean, 1 for warn-only drift or 2 for
critical drift. Exit 2 also means "not evaluated" when the output is a `state:` line
(`state: compare timed out` or `state: compare could not complete (<reason>)`) or
`config: <unreadable after review>`; stop and investigate, do not re-run. Compare
runs under the same bound and limit as snapshot. Config changes are critical except these benign keys: `branch.*.*`
except `branch.*.pushremote`; `branch.*.remote` is benign only when it names a remote
present before the review or is `.` (the local repository);
`remote.*.fetch`; `remote.*.gh-resolved`; a new remote's `url`/`fetch`/`gh-resolved`;
`gc.*`; `maintenance.*`; `extensions.worktreeconfig`; `core.sparsecheckout`; and
`core.sparsecheckoutcone`. Existing remote URL changes stay critical.
Hook changes and new local-only commits with a committer different from the initial identity
are critical. Ref, worktree and working-tree movement warn. Sensitive values are hashed in
snapshots and output is redacted. Treat compare exit 2 as review rc 10; exits 3/64 mean
check failed: stop and investigate, never clean. `dispatch-worker` treats a compare
that cannot complete as critical and returns rc 10.

| Exit | Meaning |
| --- | --- |
| `0` | Snapshot succeeded, compare clean, or help printed |
| `1` | Compare found warn-only drift |
| `2` | Compare found critical drift (including an unreadable after-snapshot) |
| `3` | Snapshot failure, broken install, unreadable before-snapshot or internal temp failure |
| `64` | Usage error; unlike the usual house exit 2, which here means critical drift |
