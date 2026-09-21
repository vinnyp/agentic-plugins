<!-- guidance: this is the decisions companion to `PRD: {{product-area}}`. It is the fourth of the
     format's four homes: fences own decisions. Every owner decision and every owner-rejected
     finding lands here as its own dated fence, and this whole file travels as a `--source` in
     every review brief and every editing dispatch thereafter.
     Two fill families are placeholders: `{{...}}`, substituted at scaffold time, and `_(prompt)_`,
     filled during authoring; an unresolved instance of EITHER is a lock-blocking defect. Every
     guidance comment in this file is deleted at lock, so a rule a BUILDER needs after lock lives
     in body text and never in a comment. -->

# Decisions: {{product-area}}
<!-- guidance: {{product-area}} matches the PRD's title exactly; the file itself is
     `<prd-slug>-fences.md` beside the PRD in {{product-docs-dir}}.
     {{product-docs-dir}}: the project's product-docs directory, where the PRD and its four
     companions live. -->

## Preamble
<!-- guidance: five things, in this order, and nothing else — the fourth and fifth only while
     an amendment is open.
     1. The settlement statement: what a fence is and what it costs to reopen one.
     2. The historical baseline: which fences predate the current lock, and the statement that
        they stand as recorded — an amendment preserves historical decisions, it does not
        re-decide them.
     3. The review-log path: the durable log this PRD's rounds append to, recorded once, at
        round 1, and never re-created.
     4. The amendment pending mark: the PRD status line's amendment clause, repeated here while
        that amendment's review rounds run and cleared by the bookkeeping close — absent from a
        document with no amendment open, which is why the rule below, and not a scaffolded line,
        is what this template carries.
     5. The resolved base: the commit SHA the amendment's diff checks compare against, recorded
        once at round 1 — present only where an amendment or a re-lock is open, for the same
        reason as item 4. A diff check whose base is not recorded here is NOT-RUN, because two
        runs that resolved the base differently are not comparable.
     Fence language is not settlement: a fence records a decision the OWNER made, by link. An
     agent-authored amendment may proceed under one blanket approval, but every WHAT choice inside
     it is still listed for the owner and recorded as its own dated fence before re-lock. -->

Every fence below is **settled**: it is carried into every review brief and every editing dispatch
for this PRD, and it is never re-litigated. A reviewer finding that a fence already settles is not
re-raised.

**Historical baseline:** fences F1–F_(k)_ predate the current lock and stand as recorded. An
amendment preserves them; it does not re-decide them.

**Review log:** `{{review-log-path}}`.
<!-- guidance: {{review-log-path}} is the path of the durable peer-review log for this PRD,
     created once at round 1 and appended to by every later round — recorded here so every later
     brief can find it without re-deriving it. -->

**Amendment pending mark.** While an amendment's review rounds run, and only then, this preamble
carries a fourth item: the same amendment clause the PRD's status line carries, naming the fence
range that authorises that amendment. Its presence says that the fences in that range are not yet
closed and the rows they touch are not yet re-ratified. The bookkeeping close clears it here and in
every other place the document carries it, in the one push that closes the amendment.

**Resolved base.** While that amendment is open, the preamble also records the commit the diff
checks compare against — the commit at which this document was most recently locked, resolved once
at round 1 and written here as a SHA rather than as a branch name or a description. The diff checks
read it from here, and every run of one records the `(base, head)` pair it used beside its result.
A branch name resolves differently on two days; a SHA does not, which is the whole reason this line
exists rather than each run resolving the base for itself.

## Fences
<!-- guidance: one `### F<n> — <title> (<date>)` per decision, in ascending order, numbered per
     PRD. Fence numbers are assigned once and never reused.
     Each fence's four fields mean:
     - **Authority** — the owner comment or decision that made it, BY LINK. A fence with no
       authority is an agent's preference wearing a fence's clothes.
     - **Decision** — what was decided, in the owner's terms, scoped to what the owner actually
       decided. The most common agent over-reach is a fence that decides a phase or a numerator
       the owner did not.
     - **Why** — optional; include it only where the reason changes how the decision is applied.
     - **Carried by** — where the decision now lives. A decision with nothing carrying it has not
       landed. -->

**Fence grammar.** Every fence is a `### F<n> — <title> (<date>)` section carrying **Authority**
(the owner decision that made it, by link), **Decision** (what the owner decided, in the owner's
terms), **Why** (optional) and **Carried by**, in that order.

**Carried by grammar.** A **Carried by** value is a comma-separated list of IDs and nothing else —
row IDs, case IDs, copy-state IDs, metric IDs and sibling fence numbers. Each item is a bare ID,
optionally preceded by the name of the document that owns it for a cross-document reference ("the
device PRD R6.27"), so the ID is the last whitespace-separated token of the item. No prose, no
ranges, no "see above": the mechanical checks build the fence → row map from this line rather than
trusting the map section, and rationale belongs in **Why**.

**A fence's original text is never rewritten.** A later clarification, narrowing, demotion or close
is appended under the fence as its own dated line, `**Clarified <date> (<authority>):** …`; where
an appended line and the original differ, the latest dated line governs. A fence cited from another
PRD is qualified by document ("the device PRD's F12"), exactly as a row ID is, because fence
numbering repeats across PRDs.

### F1 — _(title)_ (_(date)_)

- **Authority:** _(link to the owner comment or decision that made this.)_
- **Decision:** _(what the owner decided, scoped to what the owner actually decided.)_
- **Why:** _(optional.)_
- **Carried by:** _(the IDs this decision now lives in, by the grammar above.)_

**Clarified _(date)_ (_(authority)_):** _(the appended clarification; the fence above is never
rewritten.)_

## Fence → row map
<!-- guidance: one line per fence. This is the index the mechanical checks reconcile against the
     fence bodies: no map entry may point at deleted text, and every changed row must appear in
     some fence's Carried-by. -->

Each line of this map is `- **F<n>** — <IDs>`, where `<IDs>` follows the **Carried by** grammar
above, or the single clause `governs no rows` where a blanket amendment fence authorises a rewrite
rather than deciding a WHAT. No map line reads "see the lists above".

- **F1** — _(the row IDs this fence governs.)_

## Rejected findings
<!-- guidance: every reviewer finding the owner rejected, with the same authority-by-link
     discipline as a fence. A rejection recorded here is settled: it is carried into every later
     brief so the finding is never resurfaced round after round. Not conditional — a file with no
     rejections keeps the heading and says "none". -->

| # | Finding | Raised by (round) | Owner's reason | Authority |
|---|---|---|---|---|
| | | | | |
