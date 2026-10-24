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
  1200) and an evidence gate requiring a labelled severity (Blocker/Major/Minor/Nit/Critical) or a
  `file:line` citation. Failing either is exit 8 — **not** a pass. A single timeout is retried once
  internally; a second timeout is also exit 8. And if the real tree is dirty *and* the brief names
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

Every runtime's `--review`, including fallback, snapshots source state before and after.
Unexpected config changes, hook changes, foreign committers on new local commits, or an
unreadable after-snapshot exit 10, overriding every post-launch result. A compare that
cannot complete is also critical (rc 10). Ref, worktree and
working-tree movement only warn. stderr reports
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
| `8` | an agy `--review` did not produce a real review (too short, no evidence, or timed out twice) |
| `9` | effective agy model missing from live `agy models`; update `bin/lib/agy-models.sh` or the override |
| `10` | source repo changed during the review window or compare could not complete; inspect and restore named changes before committing, discard the body unless every change is known concurrent work, then re-run. Known residual: a review run can still execute a planted `filter.*.clean` during the after-snapshot's `git status`. |
| `124` | the external `--timeout` bound killed a hung agent — a blocked phase, not a result |
| other | the runtime's own exit code; native 10 is remapped to 1 during review |

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
mutation-verify.sh --file <path> --test-cmd <cmd>
                   (--mutate-sed <expr> | --mutate-cmd <cmd>)
                   [--expect-anchor <str>]... [--expect-marker <str>]...
                   [--syntax-cmd <cmd>] [--cover-check <line-or-symbol>]
```

Proves a test is load-bearing: break the code, confirm the test goes red, restore. It snapshots
the file by copy (`mktemp`), **never** with git — the pass this exists to protect against is
`git checkout -- <file>` on an uncommitted diff, which restores the last commit and throws away
the in-flight fix while reporting a clean "mutation-proof" result.

A restore refreshes the file’s mtime, forcing one rebuild of dependents.

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
review-gate brief       --persona <peer-X-reviewer> --mode <design|build|requirements> --for <claude|cross-model>
                        (--range <A..B> | --spec <path>...) [--source <path>]... [--what <text>]
                        [--repo-root <dir>] [--closing-template <path>]
review-gate cross-model [--runtime <agy|codex>] [--timeout <dur>] [--workdir <dir>] --brief <path>...
review-gate log-new     --topic <slug> [--mode <design|build|requirements>] [--persona <name>]...
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

## Environment variables

| Variable | Read by | Default / effect |
|---|---|---|
| `CODING_DISPATCH_TIMEOUT` | `coding-dispatch.sh` | `15m` (codex) / `25m` (agy) — the external bound on the agent |
| `CODING_DISPATCH_WORKTREE` | `coding-dispatch.sh`, `coding-build-phase.sh` | the worktree/branch slug; a worktree with that slug is reused so a multi-task phase accumulates on one branch |
| `CODING_DISPATCH_RM_ON_FAIL` | `coding-dispatch.sh` | `1` = remove the worktree on failure instead of salvaging it; the patch still survives under the parent repo's git dir |
| `CODING_DISPATCH_CHILD_ENV` | `coding-dispatch.sh` | whitespace-separated `KEY=VALUE` pairs exported into the dispatched agent's environment, e.g. `"MYREPO_LEDGER=off CI=1"`. Malformed entries are reported on stderr and skipped. |
| `PEER_REVIEW_LOG_ARCHIVE` | `review-log-status --archive` | existing directory outside the log repository for ignored-log snapshots; unset leaves the log local-only |
| `CODING_DISPATCH_PREAMBLE` | `coding-dispatch.sh` | path to the file holding the dispatch-preamble block (default: the plugin's `docs/dispatch-preamble.md`). A missing or empty block is a hard refusal (exit 2) before any side effect — a brief without the ground rules is the failure this exists to prevent. |
| `CODING_BUILD_CMD` | `coding-build-phase.sh` | default for `--build-cmd` |
| `CODING_COMMIT_SCOPE` | `coding-build-phase.sh` | conventional-commit scope (default: repo dir basename) |
| `AGY_MODEL` | `coding-dispatch.sh` | agy model for edit dispatches (default: coding pin in `bin/lib/agy-models.sh`) |
| `DISPATCH_NO_VENV` | `gate-run.sh` via `lib/gate-env.sh` | any value = same as `--no-venv` |
| `DISPATCH_GATE_ADVISORY_TTL_SECS` | `coding-dispatch.sh` | `3600` — how long a "your build-cmd skips gate-target X" advisory is deduplicated |
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
empty, relative or invalid repository path, a missing hasher, or unreadable config.
A failed snapshot writes an `unreadable` marker to the output file when possible.
Invalid CLI arguments exit 64.
Compare prints named change lines and exits 0 for clean, 1 for warn-only drift or 2 for
critical drift. Config changes are critical except these benign keys: `branch.*.*`
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
