# Running a reviewer persona on a different model

The Claude Agent tool loads a `peer-*-reviewer` persona automatically. Another runtime does not —
`agy` and `codex` have no idea those persona files exist. The **persona-in-brief recipe** below is
how you run any of the same lenses through a different model, for a genuinely independent second
opinion (or to keep a review off the main session's token budget).

`agy` is **capability-confirmed** for `peer-code-reviewer`, `peer-security-reviewer`, and
`peer-privacy-reviewer` by a planted-issue test: one self-contained Go snippet per persona, each
with a planted domain-appropriate defect, fed to `agy` as a brief. Each run was checked for four
things — it ran clean, it adopted the persona and its exact output structure, it caught the planted
issue with `file:line` plus a fix, and it did the false-positive reduction (credited genuinely
correct code). All three passed. The recipe is persona-agnostic, so the other lenses *should* run
the same way, but they have not been through that test; re-run it before trusting a different model
on an untested lens at a high-stakes gate. Through the Claude Agent tool, every lens works today.

---

## The recipe

```bash
cd <the worktree holding the branch under review>   # load-bearing — see below
dispatch-worker --runtime agy --review --brief <brief.md> --timeout 7m > review.md 2> review.err
# rc 0 = ran; rc 124 = hung/killed (BLOCKED, not a result)
```

`review-gate cross-model` wraps exactly this, serialized across briefs, and translates the exit
codes. Use it rather than calling `dispatch-worker` by hand.

## Which tree gets reviewed — run it from the right cwd

An `agy` review runs inside a throwaway detached worktree created at the HEAD of the repo resolved
from the **launch cwd** (`--workdir`, defaulting to `$PWD`). Launch it from a shared checkout and
you review the shared checkout's branch: the feature branch and its spec are invisible, and the
reviewer returns confident false Blockers about work it never saw. So `cd` into the feature worktree
first, or pass it as `--workdir`.

Because only **committed HEAD** is snapshotted, an uncommitted artifact — a spec or design doc —
must be committed first. The stderr warning about a dirty tree tells you changes are excluded; it
does **not** tell you the whole repo is the wrong one.

This is agy-specific. `--runtime codex` and `--runtime claude` build no worktree and ignore
`--workdir`, reading the caller's live cwd instead.

## Three load-bearing rules

### 1. The persona goes INTO the brief — as paths, never excerpts

`agy` does not auto-load Claude's agent files. Build the brief from: the full persona body (copy
from the installed `peer-reviewer-agents` plugin's `agents/peer-<lens>-reviewer.md`, minus its YAML
frontmatter) + the concrete target (a SHA range, or **file paths plus the repo root they resolve
against**) + what the change should do + the real contract sources to read + the persona's "return
exactly this structure, nothing else" closing + the file:line clause.

**Prefer `review-gate brief` over hand-assembling this.** It emits paths only (`--spec`, `--range`,
`--source`), stamps the `repo root:` line, instructs the reviewer to open the paths, and appends the
shared closing — so the excerpt failure mode is structurally unavailable. Pass `--repo-root <dir>`
when the review targets a worktree other than your cwd: **`agy` does not load worktrees**, so a bare
relative path can silently resolve against the wrong tree.

> **"Or embed its full text in the brief" is not an equal option.** Measured: four `agy` rounds
> briefed with the authoring agent's own excerpts found **zero** of the two Blockers that a single
> path-briefed round found, and one brief truncated immediately above a table definition produced a
> wrong finding that had to be read back against the source and rejected. An excerpt cannot contain
> what the truncation removed, whichever model reads it — so an excerpt-briefed review is a
> **consistency check on the brief**, never a correctness gate on the code, and must not be counted
> as a lens having run. If the artifact truly cannot be committed, write it to a real path inside the
> repo root the runtime will read, and pass **that path**.

**The file:line requirement** — this clause belongs in every review brief's closing, and
`review-gate brief` appends it automatically from `templates/review-brief-closing.md`:

> For every **Blocker** or **Critical** finding, you MUST provide: (a) `file:line` — the exact file
> and line number, and (b) the mutation that would make the test or behavior fail. A severity claim
> without a location is unverifiable and will be treated as a non-finding. Do not emit
> Blocker/Critical without both.

It exists because a reviewer without location evidence produces false-alarm Blockers that cost more
to refute than to address — in one observed run all three Blockers were wrong and none had a
`file:line`. The persona's own structure already requires it, but restating it in the closing anchors
it when the model compresses output under token pressure.

### 2. Pass `--review` — it is load-bearing, not optional

`dispatch-worker --runtime agy --review` runs `agy exec - < brief` under an external
`timeout -k 30s` watchdog with a **read-only review preamble**: no edit instructions, no completion
marker, stdout is the deliverable. The review lands on **stdout** — redirect it to a file.

**Without `--review`** the agy path injects the autonomous-**edit** preamble ("implement the change…
write the marker… your narration output is IGNORED"), which silently corrupts a review by telling
the reviewer its findings do not count. That was a real latent bug, and `--review` is what makes the
"no completion-marker requirement" promise true.

Do **not** use `coding-dispatch.sh` for a review either — that path is edit-oriented (clean-tree
check, build gate, hard revert), so a zero-diff review looks like a failed edit. For codex,
`--review` forces a read-only sandbox and skips the dependency gate; codex needs no preamble swap
because it injects none.

### 3. Serialize, and trust only the external timeout

Run reviewers one at a time — `agy` has a wedged-shared-session risk, so never run multiple
`agy exec` concurrently. `agy`'s own `--print-timeout` is untrustworthy (observed hanging six and a
half hours past a fifteen-minute setting), so the external `timeout` is the real bound, and rc 124
means BLOCKED. Always use the STDIN `agy exec -` form; `agy --print "<prompt>"` hangs headless.

## Diff-scale briefs hit the timeout ceiling

`agy --review` times out repeatedly on diff-scale code-review briefs while plan- and design-scale
briefs finish within budget. This is distinct from the wedged-session hang above: that is a health
problem, this is a scale problem. Do not chase it with a bigger `--timeout` alone — substitute a
Claude `peer-code-reviewer` subagent for diff-scale reviews and keep the different-model runtime for
plan- and design-scale gates.

## When to use which route

- **The Claude Agent tool** — dispatch the plugin-qualified persona as `subagent_type`
  (`peer-reviewer-agents:peer-code-reviewer`, and so on): in-session, same-model peer, lowest
  friction. The default.
- **A different-model runtime, `agy` or `codex`** — a genuine-independence second opinion, or a way
  to keep the review off the main session's token budget. The recipe is runtime-agnostic: swap
  `--runtime agy` ↔ `--runtime codex`, keeping `--review` on either. Pairs well with
  verify-the-reviewer for a high-stakes pre-merge or pre-publish gate. (The capability test above
  was run on `agy`; codex-as-reviewer rides the same recipe but has not been capability-tested.)
