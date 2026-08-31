# Worktree isolation

Why `--worktree` exists, where the worktrees land, and how to land, salvage, or prune them.

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

## Untracked content is NOT shared

A worktree shares **tracked** state with the source checkout — commits, branches, the index — but
**not** untracked files: `git worktree add` gives the new worktree its own independent copy of
whatever untracked files exist at creation time, not a live view onto the source checkout's
untracked files.

**If a dispatched task needs to delete untracked content from the source checkout, that deletion
must run against the source checkout directly — never inside the worktree.** A deletion run in
the worktree removes the worktree's own disconnected copy and leaves the source checkout's
untracked files fully intact: the "deletion" silently does nothing to the content it was meant to
remove. After any such deletion, verify against the source path itself, not the worktree.
