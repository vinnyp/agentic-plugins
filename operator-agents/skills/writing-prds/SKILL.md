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
  owner-locked Req-IDs (the list the brief marks out of scope) and records the round-1
  review-log path. Carried into every subsequent brief and editing dispatch as `--source`.
- **Per-round fix files** — `<prd-dir>/<prd-slug>-round-<N>-fixes.md`, one per round: the
  checkbox list that is that round's resume point.
- **The OQ results file** — `<prd-dir>/<prd-slug>-oq-results.md`, one `## OQ <id>` section per
  answered Open Question.

## Phase 0 — Research inventory

Before any round runs: enumerate the project's research/brief directories, plus the **optional
project-supplied prior-art query command** (a parameter to this skill; none assumed if the
project doesn't supply one). Every piece of relevant evidence is **ingested — or explicitly
deferred by the owner — before any round begins**.

Rationale, verbatim: "late evidence ingestion after lock costs a full re-open/verify cycle."

## Phase 1 — Scaffold

Instantiate `${CLAUDE_PLUGIN_ROOT}/skills/writing-prds/assets/prd-template.md` into the project's
product-docs directory. The template's `{{placeholder}}` parameters are substituted at scaffold
time. An unresolved placeholder is a **lock-blocking defect** — checked, and enforced, at Phase 6.

## Phase 2 — Fill

Dispatch `operator-agents:product-manager` with the scaffold, its template guidance comments,
`references/process-rules.md`, the research inventoried in Phase 0, and the parameterized
upstream docs. Every row it produces gets a Req-ID (`R<section>.<n>`, assigned once, never
renumbered) and lands at pre-alignment status. The operator flags gaps and forks; **it never
marks anything decided** — that authority belongs to the owner alone, in Phase 3.

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

**Resume rule.** On entering Phase 4: if the latest round's fix file has unticked boxes, resume
at (d). If the log's latest round lacks a verification note, resume at (e). `log-new` is
**never** re-run for the same PRD — a second file would split the fresh-lens ledger.

## Phase 5 — Priority pass

After alignment, before lock: assign priorities to every row, then run **one** focused review
asking only: "does anything deferred break the first usable build?" The Legend section (from the
template) is what makes this pass answerable — it declares which priority semantics the document
uses, build-order within the release or cut line, before this pass runs.

## Phase 6 — Lock

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
