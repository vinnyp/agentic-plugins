---
name: dispatching-into-a-worktree
description: Use coding-dispatch.sh --worktree (and coding-build-phase.sh --worktree) so a coding dispatch's hard-revert runs in an isolated worktree and can never delete a concurrent session's uncommitted work in the shared checkout. Use for any dispatch against a shared/concurrent checkout — the default. Trigger phrases - "dispatch into a worktree", "isolate the coding agent", "concurrent checkout safe dispatch", "coding-dispatch deleted my work", "what did the dispatch leak".
---

# dispatching-into-a-worktree

## When to use

Any dispatch against a shared or concurrent checkout — the default for most repos. Our repos are often a single shared checkout that several agent sessions use at once, so a failure-path hard-revert (`git reset --hard && git clean -fd`) in the shared tree can delete a *concurrent* session's uncommitted work (this really happened once — a hard-revert during one session's coding phase removed files a parallel session had written but not committed).

Use `--worktree` for any dispatch where another session may have uncommitted files in the same checkout, or where you cannot guarantee the tree is clean and stays clean for the duration of the dispatch.

## How

**Single task** (one dispatch call):

```bash
CODING_DISPATCH_WORKTREE="my-feature-slug" \
  coding-dispatch.sh --worktree <codex|agy> <repo> <prompt-file> [gate-cmd]
```

**Phase** (multiple tasks, all accumulating on one branch):

```bash
coding-build-phase.sh <codex|agy> <plan.md> <repo> <task-id...> \
  --worktree --build-cmd "<gate-cmd>"
```

The worktree lands at `<repo>/../.worktrees/<slug>` — **outside** the parent checkout, resolved to the physical absolute path. A sibling session's `git clean -fd` on the parent cannot reach it.

On success both commands leave the worktree and branch in place. **`coding-dispatch.sh` does NOT commit** — a single-task dispatch leaves its edits *uncommitted* in the worktree, so `merge --ff-only` would land nothing and `worktree remove` would refuse the dirty tree (or discard the work if forced). Commit the work in the worktree first, then land it:

```bash
# single task: the dispatch left the edits uncommitted — commit them first
git -C <worktree-path> add -A && git -C <worktree-path> commit -m "<message>"
# a worktree isolates FILES, not refs — the parent branch may have moved meanwhile.
# re-check the base and rebase onto it if a concurrent session advanced it, or the
# ff-only merge below is REJECTED (non-fast-forward) and the commit is left stranded.
git -C <repo> fetch -q
if ! git -C <repo> merge-base --is-ancestor <base-ref> <slug>; then
  git -C <worktree-path> rebase <base-ref>   # replay the work onto the moved base
fi
git -C <repo> merge --ff-only <slug>
git -C <repo> worktree remove <worktree-path>
```

(A `coding-build-phase.sh` phase run commits per task, so its `<slug>` branch already carries commits — the same re-check-and-rebase-if-moved rule applies before `merge --ff-only` lands them.)

## The concurrency guarantee

A hard-revert (`git reset --hard` + `git clean -fd`) runs inside the isolated worktree, not the parent checkout. A tracked-but-uncommitted change in the parent survives byte-identical through a failed dispatch — this is the invariant verified by the (b) test in `test-coding-dispatch.sh`: before/after `git status --porcelain`, `HEAD`, and file contents are identical.

The worktree is placed one level above the repo (`<repo>/../.worktrees/`) so even a parent-level `git clean -fd` cannot reach it.

## Untracked content is NOT shared

A worktree shares TRACKED state with the source checkout — commits, branches, the index — but **not** untracked files: `git worktree add` gives the new worktree its own independent copy of whatever untracked files exist at creation time, not a live view onto the source checkout's untracked files. One migration hit this: a step meant to delete untracked content ran inside the worktree instead and silently did nothing — it deleted the worktree's own (disconnected) copy, left the source checkout's untracked files fully intact, and the omission only surfaced at verification time.

**If a migration or dispatch needs to delete untracked content from the source checkout, that deletion must run against the source checkout directly — never inside the worktree.** After any such deletion, verify against the source path itself (not the worktree) before declaring it done.

## Publishability pre-screen for migrated files

Any migration of untracked or private-adjacent content into a tracked tree must grep the deny file itself across the full migrated file set — never a reconstructed name list, which drifts out of sync with the file the downstream gate reads.

## What did the dispatch leak / where is the salvaged work

```bash
git worktree list
```

Lists all registered worktrees for the repo. A stranded worktree shows up here with its branch and path. After a failed dispatch the agent's diff is left in the worktree (salvage-on-failure default). Prune orphaned worktree entries with:

```bash
git -C <repo> worktree prune
```

To remove a salvaged worktree after inspecting it:

```bash
git -C <repo> worktree remove --force <worktree-path>
```

To remove on failure instead of salvaging (opt-in, for throwaway builds):

```bash
CODING_DISPATCH_RM_ON_FAIL=1 coding-dispatch.sh --worktree ...
```

## Documented limitation

A worktree isolates the working **directory**, not the shared `.git` refs and objects. A hijacked or rogue agent running inside the worktree could still alter refs (branch pointers, tags) visible to every worktree. This is the established, accepted dispatch model — the revert net is scoped to working-dir isolation, not full ref isolation.
