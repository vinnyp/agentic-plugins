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
text, what would be preserved. The owner approves with one line ("proceed", or "proceed with your
recommendations").

That approval is recorded as **one provisional fence** whose **Authority** is the owner's line,
quoted and linked.

**Record the scope of what was approved, not merely that something was.** Two approvals that read
alike authorize different things, and the fence has to say which one it is:

- **"You may start."** The owner approves the work, not its content — a bare "proceed", or an
  approval of an audit that is purely structural (what is mis-columned, what is mis-shaped, what
  moves where). It authorizes **the rewrite** and settles **no WHAT choice at all**. Every product
  choice inside it is listed for the owner at step 4 and gets its own dated fence.
- **"These recommendations are approved."** The audit's numbered recommendations **state the
  product choices themselves** — this rate's numerator, this row retired, this constant's interim
  — and the owner approves that list ("proceed with your recommendations"). Those named choices
  **are** authorized, and the approved recommendation, cited by number, is their fence
  **Authority**. Re-asking the owner for a choice their own approved list already states
  misrecords their decision and costs a round.

The test is the **scope of the list**, never the warmth of the wording: a choice the approved
recommendations state explicitly carries that approval; a choice the list did not settle — new,
ambiguous, or expanded during the rewrite — stays under the provisional rewrite fence and goes
back to the owner at step 4. Record in the blanket fence's **Decision** which recommendations the
approval covered, by number, so a later round can tell the two apart without re-reading the audit.

**What would make it wrong.** Treating a "you may start" approval as settling the choices it makes
possible — it settles that the work may start and nothing else. Treating approval of a purely
structural audit as authorizing a product choice: such an audit proposes no WHAT, so its approval
settles no WHAT. And in the other direction: re-asking the owner for a choice their approved
recommendations state by number, or fencing that choice on the editing agent's or the
orchestrator's authority rather than on the recommendation the owner actually approved. A second
fence for the same approval. A fence with no Authority link. Recording a bare "proceed" as a
settled decision rather than a provisional one that step 4 later demotes.

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
resolved baselines the diff checks ran against are recorded in the **fence file's header** at this
round and repeated beside every diff check's result.

**Two baselines, because one cannot do both jobs.** The **preservation baseline** is the commit at
which this document was most recently locked; it answers "has anything been renumbered or
re-statused since the lock?". The **change baseline** is the merge-base of this amendment's branch
and the trunk it targets; it answers "what did THIS amendment change?". They differ whenever the
trunk moved after the lock, which on a shared repo is the normal case — and using the preservation
baseline for the second question makes this amendment answer for a correction somebody else already
landed and already authorized. Resolve both as SHAs at this round, record both, and say which
baseline each diff check used. `references/mechanical-checks.md` carries the per-check mapping.

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
- the **blanket fence from step 1 demoted** by a dated line saying what it did and did not cover,
  naming by number any approved recommendation that did settle its own WHAT;
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
as **PASS / MISS / NOT-RUN (reason)**, the `(baseline, head)` pair each diff check ran against and
which of the two baselines it read, and an
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

**Closure is defined over an inventory of current status surfaces, not over a global string
count.** A **status surface** is a line that states what the document is NOW: its status line, its
index entry, the fence preamble's pending item. A **fence** records what was decided THEN — its
body and its Authority line are a dated statement about a past moment, and they are **immutable
and out of scope for this close**. Tense, not file, tells them apart: if rewriting the line would
change a reader's understanding of the document's CURRENT state, it is a status surface and it
belongs in the inventory; if rewriting it would change the record of what was true when it was
written, it is history and the close does not touch it.

This is why the close cannot be verified by driving the old wording to zero hits.
`assets/fences-template.md` forbids rewriting a fence's original text, so an amendment that ran
several fences keeps the pending wording inside their historical Authority lines permanently. A
global zero is reachable only by falsifying those lines, and a single dated Closed line — the
mechanism this step prescribes — cannot produce one. The two rules are compatible; the global
count was the thing that was wrong.

**The inventory is derived, not remembered.** Before the push, grep the PRD, all four companions,
the product-docs index and every sibling this re-lock touches for the pending mark. Classify each
hit as a **status surface** or as **fence history**, and record in the lock record the
**file:line of every hit together with its classification**. The status-surface half is the
inventory, and it covers at minimum:

- the **PRD status line**;
- the **fence preamble's pending item** — the fourth item the fence companion carries for as long
  as the amendment's rounds run;
- the **product-docs index entry for this PRD**, which carries the same clause and sits outside
  the PRD-plus-four-companions scan;
- **any sibling whose status or OQ line this re-lock touches** — a sibling that mirrors this
  amendment's pending mark, or whose open question is blocked on it and closes here. This one is
  also outside that scan, and it is the half of a mirror that gets forgotten.

The expected count is whatever this document's own grep returns — it is not a constant, and a
count carried over from a previous conversion is a guess.

The push also adds one **dated Closed line** under the first amendment fence, covering the
amendment's Authority lines and naming the fence range `F<n>–F<m>` the status line named. Any
**sibling open question that closes on this re-lock** flips with a dated line.

**Verification, in four parts.** The push is checked against the recorded inventory:

1. **every inventoried surface carries the closed wording** — the new wording's hit count equals
   the inventory's size, one per surface;
2. **no inventoried surface still carries the pending wording** — this is the zero that matters,
   and it is scoped to the inventory, not to the repository;
3. **the dated Closed line covers the stated fence range**, matching the range the status line
   carried;
4. **the diff contains nothing beyond that inventory plus the permitted sibling-OQ delta.**

A non-zero count of the pending wording after the push is **correct** wherever every remaining hit
is classified as fence history. Reporting that count as a miss, and then editing fence text to
clear it, is the defect this framing exists to prevent.

### Worked verification — an amendment that ran three fences

`checkout-limits.md`, locked 2026-01-12, amended under F14–F17. F14 is the blanket rewrite fence
from step 1; F15, F16 and F17 are the per-decision fences from step 4. Step 4 requires each
fence's **Authority** to quote the owner's decision by link, and those decisions were written
while the amendment was open, so each quotes the clause `agent-build amendment 2026-02-03 under
F14–F17 (peer review pending)` verbatim. F14's demotion line quotes it once more. The close runs
on 2026-02-19 under PR #418.

**The inventory — four surfaces, derived by the grep and recorded in the lock record:**

| # | Surface | file:line |
|---|---|---|
| 1 | PRD status line | `checkout-limits.md:6` |
| 2 | Fence preamble, pending item | `checkout-limits-fences.md:14` |
| 3 | Product-docs index entry for this PRD | `product-docs/README.md:31` |
| 4 | Sibling OQ line — the device PRD's OQ 4, blocked on this amendment | `device-limits.md:142` |

**Classified as fence history, and therefore NOT inventoried — four hits:**
`checkout-limits-fences.md:58` (F14's demotion line) and `:71`, `:86`, `:99` (the Authority lines
of F15, F16 and F17).

**What the close changes.** The four inventoried surfaces; one dated Closed line appended under
F14 covering F14–F17; one dated line under the sibling's OQ 4 recording that it closed. Six lines
across four files. Nothing else.

**What the greps return afterwards.**

- Pending wording, over the PRD, the four companions, the index and the sibling: **4 hits, all in
  `checkout-limits-fences.md`, all on lines classified as history; zero on an inventoried
  surface.** **PASS** — by part 2, which asks about the inventory and not about the repository.
- Closed wording, over the same set: **4 hits, one per inventoried surface**, equal to the
  inventory's size. **PASS** — part 1.
- The Closed line under F14 reads `F14–F17`, the range the status line carried. **PASS** — part 3.
- `git diff --stat`: four files, six changed lines, every one of them an inventoried surface, the
  Closed line, or the sibling's OQ delta. **PASS** — part 4.

**Why 4 is the right answer and 0 would be the wrong one.** Each remaining hit sits inside a fence
body or an Authority line and states what was true when it was written: on 2026-02-07 the owner's
decision really was made against an amendment whose review was pending. Rewriting those lines to
say "closed" would have the record claim the owner ratified F16 after a review that had not yet
happened — a falsified authority, and a direct violation of "a fence's original text is never
rewritten". The close's job is to make the document's CURRENT state readable in one pass; the
fence chain's job is to keep the past readable. A global zero buys the first by destroying the
second.

**What a real miss looks like here.** The same grep returning a hit at `checkout-limits.md:6`, or
at `product-docs/README.md:31`, or at `device-limits.md:142` — an inventoried surface still
advertising a review that is closed. That is what the check is for, and a global count would have
hidden it: with eight hits before the push and four after, a "the number went down" check passes
whether or not the right four cleared.

**What would make it wrong.** Any other edit riding along — it would ship unreviewed under a close
that claims review is finished. An inventoried surface the push did not clear. An inventory
asserted from memory or from a previous conversion instead of derived from this document's own
grep — the inventory is the only thing standing between "cleared everywhere" and "cleared where I
remembered". Rewriting a fence body or an Authority line to drive a global count to zero:
append-only history is not what a bookkeeping close gets to reopen, and the close has no authority
over what was true in the past. An un-classified hit — one the lock record lists without saying
whether it is a surface or history — since the verification cannot run against it either way.
Omitting the product-docs index entry or the touched sibling, the two surfaces that sit outside
the PRD-plus-four-companions scan. A sibling open question left open against a document that has
re-locked.

## 8. Attended merge

**Who.** The owner, or an agent the owner explicitly instructed to merge. Never an agent acting on
its own initiative.

**What.** The merge is **owner-authorized**, not necessarily owner-operated: the owner merges, or
the owner says "merge it" and the agent carries that instruction out. What the step protects is
unchanged — **nobody merges their own review on their own initiative**. The failure mode is an
agent deciding for itself that the loop is finished, not an agent executing an instruction it was
given. **A stricter project policy wins where one exists**: where the project reserves the merge
to the human, this step does not license an agent to perform it.

After the merge lands, the worktree is removed.

**What would make it wrong.** An agent merging on its own judgment that the round is done — the
orchestrator merging its own review, or the editing agent merging because the checks came back
clean. Reading a general "looks good" as the instruction: an authorization names the merge.
Merging under this step where the project's own policy reserves it to the human. Removing the
worktree before the merge lands, which strands the branch if the merge needs a fix.

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
