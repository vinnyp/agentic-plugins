---
name: writing-prds
description: "Use when turning a product idea or scaffold into a locked, review-aligned PRD — template-driven authoring with an owner-adjudication loop and a multi-round peer-review gate. The skill drives; the OWNER decides all WHAT/WHY. Requires the agent-dispatch plugin (running-the-peer-review-gate with requirements mode). Trigger phrases - \"write a PRD\", \"fill out my PRD scaffold\", \"requirements doc for X\", \"lock the PRD\", \"run the PRD loop\". NOT for a single review round on an existing document — that is agent-dispatch:running-the-peer-review-gate in requirements mode."
---

# writing-prds

Turns a product idea or an existing scaffold into a **locked, review-aligned PRD**:
template-driven authoring, an owner-adjudication loop, and a multi-round peer-review gate that
runs — round after round — until every row is aligned and the document is safe to hand to
engineering.

The mechanical part of any one review round — brief assembly, dispatch, verify-the-reviewer, the
durable log — is handled by `agent-dispatch:running-the-peer-review-gate` in `requirements` mode.
**This skill is the caller of that contract**: it owns the multi-round loop, the state that
survives between rounds (the fence file, the fix files, the OQ results), and every owner
decision. The gate never sees more than one round at a time; this skill is what makes "one gate,
nothing forks" true across the whole PRD lifecycle.

## Overview, roles, and dependency

- **Owner** — the PM. Owns all WHAT/WHY, and makes **every** adjudication call: every fence
  decision, every rejected finding, every lock overrule. Nothing in this flow marks a row decided
  on the owner's behalf.
- **The orchestrator** (you) — drives the six phases below: runs Phase 0's inventory, dispatches
  Phase 2's fill and Phase 4's gate rounds and fix passes, and runs Phase 3's owner adjudication.
- **`operator-agents:product-manager`** — drafts the PRD's content in Phase 2. It flags gaps and
  forks; it never marks anything decided.
- **The gate** — reviews. One round per invocation, requirements mode.

Requires the `agent-dispatch` plugin (>= the release carrying `--mode requirements`) from the
same marketplace; the gate is invoked via the Skill tool as
`agent-dispatch:running-the-peer-review-gate`.

### Preflight (before Phase 1, not Phase 4)

Before Phase 1 (scaffold) begins, verify the gate skill is installed and that
`review-gate brief --mode requirements` is accepted. If it is not: **STOP** with "install/upgrade
the agent-dispatch plugin". Do this check up front — never discover the missing dependency inside
Phase 4, with a scaffold, a fill, and owner adjudication already sunk and the loop dead-ended with
artifacts half-produced.

### Runtime notes

The flow is runtime-neutral. On Claude Code, Phase 3 uses AskUserQuestion and dispatches run via
the Agent tool; on other runtimes (e.g. agy), adjudication falls back to plain-text option lists
with a stated recommendation, and dispatches follow the gate's pluggable-runtime path
(cross-model-style briefs with inlined persona bodies). Validated end-to-end on Claude Code; other
runtimes per those notes.

## State artifacts

All of this lives **beside the PRD, in the project repo — never in `/tmp`**:

- **The review log** — the audit trail and fresh-lens ledger, at
  `docs/agent-reviews/<date-of-round-1>-<prd-slug>-peer-reviews.md`. Created **once**, at round 1;
  its path is recorded in the fence-file header. Every later round **appends** a `## Round N`
  section to this same file.
- **The cumulative fence file** — `<prd-dir>/<prd-slug>-fences.md`. Records owner decisions
  **and** owner-rejected findings. The fence file's header also enumerates the currently
  owner-locked row IDs — any of the template §2's three families (`R<section>.<n>`, `E<n>`,
  `M<n>`) — (the list the brief marks out of scope) and records the round-1
  review-log path. Carried into every subsequent brief and editing dispatch as `--source`.
- **Per-round fix files** — `<prd-dir>/<prd-slug>-round-<N>-fixes.md`, one per round: the
  checkbox list that is that round's resume point.
- **The OQ results file** — `<prd-dir>/<prd-slug>-oq-results.md`, one `## OQ <id>` section per
  answered Open Question.
- **The journeys and copy companions** — `<prd-dir>/<prd-slug>-journeys.md` (one
  `### Journey: <name>` section per journey: happy-path steps and failure branches) and
  `<prd-dir>/<prd-slug>-copy.md` (one entry per user-facing string: ID, surface, the string, the
  rows that back it). Process rule 8: the PRD's §4 and §6 carry only their index, so a reviewer
  traces a journey step or a string back to the row that backs it, and the PRD body stays inside
  its word budget (Phase 2).

## Phase 0 — Research inventory

Before any round runs: enumerate the project's research/brief directories, plus the **optional
project-supplied prior-art query command** (a parameter to this skill; none assumed if the
project doesn't supply one). Every piece of relevant evidence is **ingested — or explicitly
deferred by the owner — before any round begins**.

Rationale, verbatim: "late evidence ingestion after lock costs a full re-open/verify cycle."

## Phase 1 — Scaffold

Instantiate `${CLAUDE_PLUGIN_ROOT}/skills/writing-prds/assets/prd-template.md` into the project's
product-docs directory, alongside the two empty companions (`<prd-slug>-journeys.md`,
`<prd-slug>-copy.md` — see State artifacts). The template's `{{placeholder}}` parameters are
substituted at scaffold time. An unresolved placeholder is a **lock-blocking defect** — checked,
and enforced, at Phase 6.

## Phase 2 — Fill

Dispatch `operator-agents:product-manager` with the scaffold, its template guidance comments,
`references/process-rules.md`, the research inventoried in Phase 0, and the parameterized
upstream docs. Every dispositionable row it produces gets the row ID the template's §2 defines
for its table — `R<section>.<n>` for §7 requirements, `E<n>` for §8 error/state rows, `M<n>` for
§9 success metrics — assigned once, never renumbered — and lands at pre-alignment status. The operator flags gaps and forks; **it never
marks anything decided** — that authority belongs to the owner alone, in Phase 3.

**Word budget.** The PRD body — tables, Legend, Open Questions; companions excluded — has a word
budget: the project-supplied value (a parameter to this skill), default **12,000 words**. The fill
brief states it, and the orchestrator reports the count after the fill and after every fix pass.
Over budget is a defect of the fill, not a fence for the owner to impose in a late round: run a
compaction pass under process rules 7 and 8 before the next round. A document that cannot fit
because it has too many rows is two PRDs — split it, as its row-ID families and cross-PRD cites
already allow. Rationale: a PRD reached ~33k words before the owner fenced two-sentence rows at
round 15 and a companion split at round 16, each costing a full verification round; the next PRD
in the same project repeated the refactor under its own fence.

## Phase 3 — Owner adjudication

The **ORCHESTRATOR** — not the operator, which has no question tool — runs AskUserQuestion
batches over the gaps and forks Phase 2 surfaced, recommended option listed first. Every
decision, and every finding the owner rejects, appends to the fence file — carried verbatim into
every subsequent brief and editing dispatch ever after, so a fenced point is never resurfaced.

## Phase 4 — The gate loop

State owner: this skill (see State artifacts, above). Each iteration runs five steps, in order:

(a) **Invoke the gate** (`agent-dispatch:running-the-peer-review-gate`, `requirements` mode) for
one round. Round 1 creates the review log via the gate's `log-new`, and the created path is
recorded in the fence-file header. Round 1 passes the fence file; every later round passes the
fence file and the recorded log path as `--source` — never inlined. On the **first full round
only**, the orchestrator also
offers the owner an optional different-model (cross-model) pass via the gate's cross-model route
— it is never repeated unprompted on any later round, and any cross-model findings delta-verify by
the same re-dispatch as step (e).

(b) **Adjudicate** the round's consensus findings via Phase 3.

(c) **Write the round's checkbox fix file** — one box per finding from **every** review that ran
this round — and verify it **item-for-item against each review** before dispatching it. This is
the check against the dropped-finding failure mode.

(d) **Dispatch the fix.** A general-purpose editing agent, or the PM operator, receives the fix
file plus the fence file **as the owner's written authorization** for any status changes it
makes, and **ticks each box as that fix lands**. The fix file is the resume point for this round.

(e) **Delta-verify.** Re-dispatch the same lenses with the prior round's log and the fix file
passed as `--source`, asking per-finding RESOLVED/UNRESOLVED. Same-session agent resumption is an
optimization when available — **never the contract**; cross-model findings delta-verify the same
re-dispatch way.

**Editorial edits do not re-open a row.** An edit that changes no *meaning* is an *editorial
edit* — a link target or label that keeps the same owning document, an index / Legend /
fence-to-row map entry, typography and punctuation, a status cell the fix file authorizes as
bookkeeping for a disposition already on the record: the
orchestrator verifies the diff against the fix file word by word, records it in the round's log
section as editorial, and the row keeps its alignment (process rule 6: owner-authorized edits to
an aligned row keep alignment and say so inline). It does not trigger a lens round.

Anything that changes meaning is **not** editorial, even when no rule cell was retyped: a change
to Legend priority semantics, to the wording of user-facing copy, to which PRD a cite names as
owner, to any rule cell, or a status change that *carries* a disposition rather than transcribing
one (`needs-discussion` → `aligned`). Each goes through a lens round — a delta over the edited
rows is enough.
Rationale: seven rows whose rule text never changed cost six delta rounds when every index repair
was treated as a re-open; the class is narrow to save those rounds, not to pass a contract change
by the lenses unreviewed.

**Resume rule.** On entering Phase 4: if the latest round's fix file has unticked boxes, resume
at (d). If the log's latest round lacks a verification note, resume at (e). `log-new` is
**never** re-run for the same PRD — a second file would split the fresh-lens ledger.

## Phase 5 — Priority pass

After alignment, before lock: assign priorities to every row, then run **one** focused review
asking only: "does anything deferred break the first usable build?" The Legend section (from the
template) is what makes this pass answerable — it declares which priority semantics the document
uses, build-order within the release or cut line, before this pass runs.

## Phase 6 — Lock

**Mechanical lock preconditions (orchestrator-run, bracketing the pre-lock round).** No lens can see
these — each lens is briefed on one document and disposes rows one by one — so the orchestrator
runs them itself and records the result (what was checked, the misses, the fix or the post-lock
item) in the review log's lock record:

1. **Cross-PRD consistency**, over every PRD this document cites *or* is cited by — the direction
   does not matter and the citation need not be reciprocal. The outbound set is read off this
   document; the inbound set is **not** derivable from it, so enumerate the sibling PRDs and their
   companions and search them for links to this document and to its row-ID families. Each pair the
   two sets produce gets every check below: (a) inherited
   obligations agree both ways — every line in this PRD's obligations table that names another
   PRD has its counterpart there, each naming the rows that carry it; (b) shared rows agree on
   priority — where one document says a row "moves into" or "is in" a build phase, the other's
   Pri cell says the same, and a conditional in one is matched in the other or in neither;
   (c) every cross-PRD cite names the owning document in its visible label ("the device PRD's
   R6.27"), never a bare ID, because the row-ID families repeat across PRDs (standing check: no
   `[R…](../…)`, `[E…](../…)`, or `[M…](../…)` link without an owning-PRD label); (d) retired and
   moved IDs are retired in the source Legend and recorded in the destination; (e) fence numbering
   is per PRD, and a fence cited from another PRD is qualified the same way a row is.
2. **Index sync:** derive the fence-to-row map from the fence file, and cross-check the Legend
   and Surfaces lists against the companion files' marks; every miss is an editorial edit
   (Phase 4), fixed before the round.
3. **Latent-decision inventory:** constants without an OQ, copy states with no producing row,
   rows an upstream PRD places at a higher priority, undefined terms the rows lean on. Each
   becomes an Open Question or a Phase 3 adjudication *before* the pre-lock round — never
   discovered one per verification round afterwards.

**The clean result must belong to the document that locks.** The checks run once before the
pre-lock round *and again after the last edit of that round's fix pass* — the state that actually
locks. Any edit after a clean check re-runs all three before lock: a row, an Open Question, a
fence, the Legend, the fence-to-row map, a companion file. A result recorded for an earlier state
does not carry forward, and an editorial edit (Phase 4) is still an edit for this purpose.

The same three checks re-run before any re-lock (a refactor of a locked PRD, a companion split, an
amendment that moves rows). Rationale: one PRD carried a shared row at P1 while its sibling's
locked P0 placed the same row in the first build phase; the pre-lock round had run, and a reviewer
found it only by happening to read the obligations table. A "no rule changes" refactor of a locked
PRD then surfaced ~15 unnamed decisions, one per round, over five rounds.

**Mandatory pre-lock round.** Before lock can be declared, run one Phase 4 iteration whose lenses
include the retargeted `peer-plan-reviewer` — retargeting line: "Could the follow-on spike and
first build phase execute from this document unattended — is every open question actionable,
every deferred constant named, every dependency ordered?" — **plus** at least one lens that the
review log shows has not previously reviewed the document (the fresh-lens rule). Lock cannot be
declared without that round's verdicts at proceed.

Lock requires all of the following:

- **Every row aligned** — flipped by a unanimous non-abstaining disposition, or by an owner
  overrule recorded with the standing objection and the owner's reason.

  Lock rule, verbatim: "no unresolved objection that the owner has not explicitly overruled on the record."
- **The mandatory pre-lock round has run** — the retargeted `peer-plan-reviewer` plus fresh-lens
  requirement above, with its findings adjudicated per Phase 3 (see above).
- **The mechanical preconditions ran clean** — cross-PRD consistency, index sync, and the
  latent-decision inventory above, run against the state being locked, with the result in the
  lock record.
- **The OQ contract complete** — a results-file section for every answered Open Question.
- **Zero unresolved placeholders.**
- **Template guidance comments deleted.**

Then ship via the project's own workflow — this skill does not define one of its own.

## Red flags

| If a dispatch, editor, or reviewer argues... | The rule stands regardless |
|---|---|
| "the reviewer is wrong, skip verification" | verify-the-reviewer, always — every Blocker/Major (and Critical/High), every round |
| "flip the row, it's obvious" | only a disposition or recorded owner authorization flips a row |
| "re-litigate a fenced decision" | fences are settled |
| "re-run log-new for round 2" | append to the recorded log path instead |

## References

- [`assets/prd-template.md`](assets/prd-template.md) — the scaffold Phase 1 instantiates.
- [`references/process-rules.md`](references/process-rules.md) — the rules that travel verbatim
  in every Phase 2 fill dispatch and every Phase 4 gate brief.
- `agent-dispatch:running-the-peer-review-gate` — the one-round gate this skill's Phase 4 invokes,
  in `requirements` mode. See its "Requirements-mode specifics" section and the PRD tier in its
  tier reference for the persona set, the flip rule, and the log convention this skill relies on.
