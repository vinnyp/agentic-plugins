# The dispatch preamble

Three clauses that every dispatched brief carries, whatever the runtime and
whatever the agent is for — a coding worker, a reviewer, a research or archival
subagent. They are concatenated into the brief at assembly time, not cited from
it: a hand-maintained register of "places that cite this rule" is exactly what
fails, because the next assembling path does not join the register.

**Provenance.** These clauses are vendored from the maintainer's private
dispatch-standards collection, which is their upstream (`vinnyp/foundry#197`,
`vinnyp/foundry#203`). A public repository cannot read a private source at
runtime, so this file is the copy `agent-dispatch` ships and the only one its
own tooling reads. A change to a clause belongs in both places.

`{{DIRTY_PATHS}}` is a **named substitutable token**, not prose in angle
brackets. The assembling path replaces it with the paths `git status
--porcelain` reports in the tree the agent will work in, or with the literal
`none`. An unsubstituted token reaching a real brief leaves the second clause
inert, so an assembling path substitutes it or does not ship the brief.

<!-- PREAMBLE:START -->
- **Never touch a file you did not create.** `rm`, `git checkout`, `git restore`, `git reset`, `git clean` and `git stash` are forbidden against any path outside your task's declared files. Treat unknown files as foreign and leave them. This binds every dispatched agent — a coding worker, a reviewer, a research or archival subagent, any runtime — not only a `coding-dispatch.sh` run.
- **These paths are already dirty and are not yours:** {{DIRTY_PATHS}}. Reverting or deleting one of them is the failure this rule exists to prevent.
- **You do not run the long gate.** Run every command in the foreground and let it finish. A subagent cannot receive a completion notification, so a backgrounded command hangs forever with nothing to wake it; if you catch yourself writing "I'll wait for the notification", that IS the violation. Never kill or signal a process you did not start.
<!-- PREAMBLE:END -->

## Who concatenates it

- `bin/coding-dispatch.sh` — the primary brief-assembly site. It reads the block
  out of this file at dispatch time, substitutes `{{DIRTY_PATHS}}` from the
  target tree, and prepends it to the brief the agent receives. A missing or
  empty block is a hard failure, not a silently shorter brief.
- `skills/running-the-peer-review-gate/SKILL.md` — every reviewer brief, on both
  the Claude Agent-tool route and the different-model route.

`bin/test-dispatch-preamble.sh` asserts the clauses reach a **generated** brief,
so deleting one from this file turns that suite red. Grepping for a citation
could never do that.

## Why each clause is here

1. **Cleanup.** A read-only sweep once reverted and deleted pre-existing
   uncommitted files it believed it had created. The prohibition existed, but
   every mechanism naming it was a coding-dispatch run, so a reviewer or a
   research subagent found no hook.
2. **Dirty paths.** The prohibition above is unenforceable if the agent cannot
   tell which files were already there. Naming them turns a rule into a check
   the agent can actually perform.
3. **The long gate.** A subagent has no channel on which a completion
   notification could arrive, so a backgrounded command never returns and the
   agent waits for a wake-up that cannot come. The orchestrator-side half of
   this rule — that the orchestrator drives long gates itself — is the
   caller's, and is not part of the dispatched brief.
