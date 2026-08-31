# Safety and data flow

What the revert net does and does not cover, what leaves your machine and to whom, and where the
local artifacts land. Read the [What this does NOT protect](#what-this-does-not-protect) section
before you point agent-dispatch at code you did not write.

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

## What this does NOT protect

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
