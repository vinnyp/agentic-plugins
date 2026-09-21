# Converting a locked PRD

This is the flow for turning an existing **locked** human-format PRD into the agent format without
losing anything the lock already settled. It is an amendment, not a rewrite of the product: the
document changes shape, the decisions inside it do not.

**Assumed host.** As written this flow assumes **GitHub**: it anchors line comments in a diff, and
it relies on the host refusing an approval from the change's own author. The host-neutral
equivalent is any reviewable change request with **per-line comments** and a **stable change
identifier** — read "PR" as that change request and "PR #<n>" as its identifier. On a host without
per-line comments, post the round as one comment carrying file:line references instead; on a host
that does let an author approve their own change, step 6 stays a comment anyway, because a review
that is also authorship has no standing to give.

## Three roles

- **The editing agent** — any coding agent. It audits, it rewrites, it lands fixes and decisions on
  the branch. It proposes WHAT choices; it never settles one.
- **The orchestrator** — reviews, and **never edits the branch**. It runs the mechanical checks,
  reads the diff, dispatches the lenses, posts the reviews, and carries the owner's decisions into
  the record.
- **The owner** — decides. Every WHAT choice inside the amendment is the owner's, one at a time.

**Why the orchestrator not editing matters.** A reviewer that fixes what it finds stops finding
things: the fix becomes the memory of the defect, and the next round has nothing to compare against.
Keeping authorship on one side and acceptance on the other means every change on the branch is
attributable — "did the fix land as decided?" is answered by reading the diff, not by remembering
the conversation — and it keeps the round count honest, because a round that resolves nothing is
visible as a round that resolved nothing. It is also why step 6 is posted as a comment rather than
an approval: GitHub refuses approvals from the PR author's account, so a review that is also
authorship has no standing to give.

---

## 1. Audit

**Who.** The editing agent.

**What.** It reads the locked PRD and its companions against the agent format and returns
**numbered recommendations** — what would be replaced, what is structurally wrong in the locked
text, what would be preserved. The owner approves with one line ("proceed").

That approval is recorded as **one provisional fence** whose **Authority** is the owner's line,
quoted and linked. It authorizes **the rewrite**, not the WHAT choices inside it.

**What would make it wrong.** Treating the blanket approval as settling the choices it makes
possible — it settles that the work may start and nothing else. A second fence for the same
approval. A fence with no Authority link. Recording it as a settled decision rather than a
provisional one that step 4 later demotes.

## 2. Rewrite

**Who.** The editing agent, **in a worktree, on a branch, as a PR**.

**What gets instantiated first.** The authoring loop's Phases 1–2 are replaced on this path, so
nothing else creates the companions. Instantiate all four templates FIRST —
`assets/prd-template.md`, `assets/journeys-template.md`, `assets/copy-template.md` and
`assets/fences-template.md` — substituting their `{{…}}` parameters exactly as Phase 1 would, and
create `<prd-slug>-oq-results.md` headed and empty. **Then** migrate the locked document's content
into them: content moves into the template's sections, never the reverse. Rewriting the existing
companions in place instead yields a document with no `## Harness`, no `## Transition index` and no
`## Fence → row map` — the sections the mechanical checks parse by name — and those checks then
report NOT-RUN rather than the PASS a reader would assume.

**What gets replaced.** Narrative background, the problem statement, persona-story headings and any
inline narrative become the **build contract**. The lifecycle diagram becomes the **row-transition
index**. Scattered provisional values become the **constants and closure gates** and **build
dependencies** tables. Journey prose becomes **Given/When/Assert acceptance tables** in the journeys
companion. Inline user-facing strings — headlines, body copy, action labels, empty- and error-state
wording — become the **copy companion**, one section per state, with the requirement rows citing
copy IDs instead of repeating the strings. **Any of the four companions the source document lacks is
created in this step**, the copy companion and the open-questions results file included; none is
deferred to a later PR.

**What gets repaired.** The structural defects the locked text carries: a mis-columned table (a
header with more columns than its rows have cells renders as garbage and hides a column), a false
oracle ("counts unchanged" where nothing reads the count), a stale claim, a double-counted quantity,
a rate with the wrong numerator.

**What is preserved — all of it.** Every row ID, every priority, every status, every anchor other
documents link to, and every historical decision. **An amendment is not an implementation
completion.**

**Also in this PR.** Sibling mirrors recorded on **both sides** — a constant, fixture, variant or
obligation a sibling document must honor lands there in this same PR, with a dated clarification on
the sibling fence it touches. Post-lock items that this rewrite makes true are ticked here, not
later. The status line gains the amendment clause, ending in the pending mark:
`; agent-build amendment <date> under F<n>–F<m> (peer review pending)`.

**What would make it wrong.** A renumbered ID. A status flipped to `done` because the rewrite
describes behavior that has since been built. A dropped anchor. A sibling half left "for the next
PR". Editing in the shared checkout instead of a worktree. Rewriting a companion in place rather
than instantiating its template and migrating into it. A companion the source document never had
left uncreated.

## 3. Round 1

**Who.** The orchestrator.

**What.** In order: run the **mechanical checks**; **read the whole diff**, every line; then
dispatch the four lenses — `peer-product-manager-reviewer`,
`peer-staff-software-engineer-reviewer`, `peer-test-reviewer` and `peer-interface-reviewer` — with
the brief's standing instruction, quoted verbatim into every brief:

> Every WHAT the agent chose under the blanket approval is listed as an owner decision, never marked
> settled; findings settled by an existing fence are not re-raised.

**Dispatch them by those full names.** This step dispatches the lenses **directly**; no gate runs in
between to correct a name, so a shortened one is not caught. Through the Agent tool the
`subagent_type` is plugin-qualified — `peer-reviewer-agents:peer-product-manager-reviewer`, and the
same form for the other three. Through the peer-review gate's CLI the same four are
`--persona peer-product-manager-reviewer` and so on. **Never dispatch `product-manager` or
`staff-software-engineer`**: those are the names of OPERATOR agents, which WRITE files, and
dispatching a document's own author as its reviewer yields an approval rather than a review.

Then **verify every Blocker and Major on the branch** — grep the current text for the thing the
finding claims before accepting it — and post **one** review: line comments anchored in the diff,
with **every anchor checked against the hunks** first, owner decisions marked **"do not pick"**, and
a **decision table** carrying one recommendation per item.

**Where the lock record lives on this path.** The authoring loop's review log is created by that
loop's round 1 and is **not** created here: this path never invokes the gate's `log-new`, and
re-running it for a document that already has a log splits the fresh-lens ledger. On this path the
lock record is **the posted review comment for the round, plus the fence file**. The round's
mechanical-check results go in the posted comment, each one **PASS / MISS / NOT-RUN (reason)**; the
resolved `(base, head)` pair the diff checks ran against is recorded in the **fence file's header**
at this round and repeated beside every diff check's result. `<base>` is the commit of the
document's most recent lock.

**Confirm the repo's visibility before the first post.** Steps 3, 4 and 6 route the entire review
out through change-request comments, where it is published with the document. Check visibility
before posting anything. On a **public** repo, post the decision table and cite PRD content **by row
ID and file:line** rather than excerpting it — the copy companion holds verbatim user-facing strings
and the journeys companion holds fixtures, and a review comment quoting either publishes it.

**What would make it wrong.** A finding passed through unverified. More than one review posted for
one round. A line comment whose anchor is not in the diff — the host drops it or places it on the
wrong line, and the owner never sees the item. An owner decision written as though the orchestrator
had already picked it: the recommendation is advice, and the "do not pick" mark is what keeps it
advice. A round whose check results land nowhere, or land in a review log this path did not create.

## 4. Decisions

**Who.** The owner decides; the orchestrator records; the editing agent lands.

**What.** On the owner's word, the orchestrator posts **one comment** listing each decision exactly
as it is to be recorded:

- a **dated fence per decision**, with **Authority** (a link to the owner's comment) and
  **Carried by** (the rows, cases, copy states and sibling fences it touches);
- **dated clarification lines** appended under each existing fence the decision touches — a fence's
  original text is never rewritten;
- the **blanket fence from step 1 demoted** by a dated line saying what it did and did not cover;
- **siblings amended in the same PR**, both halves;
- **direct fixes restated** in the same comment, so the owner sees in one place everything the push
  will contain.

**What would make it wrong.** A fence written from the orchestrator's recommendation rather than the
owner's words. Authority that names no link. An existing fence edited in place instead of clarified
by a dated line. The blanket fence left standing as though it still covered the WHAT choices. A
sibling amendment deferred.

## 5. Delta rounds

**Who.** The orchestrator dispatches; the same four lenses review; the editing agent fixes.

**What.** Each delta round briefs the lenses with the prior review, the posted comments, the agent's
replies, the decisions comment and the fence file — by path, never inlined. Each returns, per
finding, **RESOLVED / UNRESOLVED / PARTIAL with file:line**, plus **new defects the fixes
introduced**.

Every round also runs the **transcription check**: each decision is read against the fence that now
records it. **A fence that decides more than the owner did is UNRESOLVED** — a phase the owner never
named, a numerator the owner never chose, a scope widened from "this surface" to "all surfaces".

New WHAT choices surfaced by the fixes become further numbered decisions and go back through step 4.
**Repeat until a round returns no Blocker or Major that is not itself an owner decision.**

**What would make it wrong.** A "RESOLVED" with no file:line behind it. Skipping the transcription
check because the fences were written from the owner's own comment — that is exactly when the
over-reach slips in. Treating an open owner decision as a Blocker that stops the loop: the loop ends
on the owner's docket being the only thing left, not on it being empty.

## 6. Bounded final check

**Who.** The orchestrator alone. **No lens round.**

**What.** A bounded pass over the last push: **every line of the delta read**, every decision and
every minor verified by inspection, and the **mechanical checks re-run** against the state that will
lock. Posted as a **comment review** — the host refuses approvals from the change author's account.

**This comment is the lock record**, together with the fence file. It carries every check's verdict
as **PASS / MISS / NOT-RUN (reason)**, the `(base, head)` pair the diff checks ran against, and an
owner fence by name for each NOT-RUN the lock accepts. Nothing here is written into the authoring
loop's review log — this path never created one.

**What would make it wrong.** Sampling the delta instead of reading it. Skipping the re-run because
the checks were clean before the round's last edit — that earlier result belongs to an earlier
document. Attempting an approval and recording a failed one as the sign-off. Locking with a NOT-RUN
that no fence names.

**No fresh lens here — an accepted risk, not an equivalent control.** The authoring loop's pre-lock
round requires a lens the review log shows has not seen the document; this re-lock requires none.
That is the owner's decision, and it is recorded here as what it is: **a risk accepted**, not a gap
closed. It is acceptable because of scope — an amendment changes the document's shape, not its
decisions, and every WHAT choice inside it is ratified by its own dated fence citing the owner. It
remains a risk because a fence and a fresh lens control **different failure modes**: a fence
establishes that the owner CHOSE a WHAT; a fresh lens finds a defect **nobody noticed**, which by
definition no one wrote a fence about. The fence chain does not substitute for the second.

**And the record cannot falsify itself.** Across five conversions of locked PRDs in one project, the
four standing lenses plus this bounded check converged without a fresh lens — but no fresh lens ran
in any of the five, so no fresh-lens finding could have appeared. That record shows the loop
terminated. It does not show that nothing was missed.

**Calibration — run one.** On the **next** conversion, dispatch at step 6 one lens the review record
shows has not seen the document, and record in the lock record whether it found anything the four
standing lenses missed. One run is what turns this from an untested assumption into a measured one;
until it happens, treat the paragraph above as a decision under uncertainty.

A re-lock that is **not** an amendment — a refactor or a companion split, where no per-decision
fence chain exists — goes back through the authoring loop's pre-lock round, fresh lens included.

## 7. Bookkeeping close

**Who.** The editing agent, on the orchestrator's instruction. **One push, and nothing else may
change in it.**

**What.** The exact wording change: the status line's amendment clause
`; agent-build amendment <date> under F<n>–F<m> (peer review pending)` becomes
`; peer review closed <date> (PR #<n>); re-locked on merge`.

**The pending mark is grep-derived, not counted from memory.** Before the push, grep the PRD and all
four companions for the mark, and record in the lock record the **hit count and the file:line of
every hit**. The expected count is whatever this document carries — it is not a constant, and a
count carried over from a previous conversion is a guess. The push clears **every** recorded hit and
no others. The fence companion's preamble carries the mark as its fourth item for as long as the
amendment's rounds run, so it is always among the hits; the status line is always another.

One **dated Closed line** under the first amendment fence, covering the amendment's Authority lines.
Any **sibling open question that closes on this re-lock** flips with a dated line. The whole push is
then **verified by grep**: the old wording returns no hits, the new wording returns exactly the
recorded count, and the diff contains nothing else.

**What would make it wrong.** Any other edit riding along — it would ship unreviewed under a close
that claims review is finished. A recorded hit the push did not clear. An expected count asserted
from memory or from a previous conversion instead of derived from this document's own grep — the
count is the only thing standing between "cleared everywhere" and "cleared where I remembered". A
sibling open question left open against a document that has re-locked.

## 8. Attended merge

**Who.** The owner merges. Nobody else.

**What.** After the merge lands, the worktree is removed.

**What would make it wrong.** The orchestrator merging its own review. Removing the worktree before
the merge lands, which strands the branch if the merge needs a fix.

---

## Standing observations

From five conversions of locked PRDs in one project, each of which ran three lens rounds and a
bounded final check:

- **Roughly one new WHAT surfaces per round** — a rate's numerator, the basis of a tally, which
  document owns a fixture, a phase carve-out. They are not defects in the rewrite; they are
  decisions the locked text had left implicit and the format now forces into the open. **Budget
  three rounds.**
- **Reviewers disagree with each other about a fifth of the time.** **The orchestrator's grep
  decides** — read the branch, not the reviews, and record in the round which reading won and why.
- **The most common agent over-reach is a fence that decides more than the owner did** — a phase or
  a numerator nobody chose. That is what the transcription check in step 5 exists to catch.
- **The most common omission is the sibling half of a mirror** — the constant, variant or obligation
  landed here and never landed there. Step 2 and step 4 both say "both sides" because one saying it
  was not enough.
