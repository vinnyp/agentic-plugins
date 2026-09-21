# Agent-format PRD process rules

Every fill, fix, and review of a PRD authored with `writing-agent-prds` operates under these
rules. They travel verbatim in every fill dispatch and every gate brief.

1. **WHAT, not HOW.** Requirements state product behavior and verifiability obligations — "a test
   can set/observe/induce X" — never mechanisms, module names, storage columns, or API shapes.
   (This is what lets reviewers judge rows without objecting to missing implementation detail.)
2. **Evidence discipline.** Every factual claim cites its source. Documentary evidence carries a
   confirm-on-verification qualifier with its Open-Question id. Unknown numbers become NAMED
   constants, each with a candidate value or an explicit TBD, an interim rule, and the OQ and
   evidence that closes it; no constant ships with its OQ unresolved and no interim stated.
3. **Testability pairing.** A change to any requirement touches its acceptance case and its
   verification-seam row in the same pass — a reshaped rule must never orphan the case that
   proves it or the injection that exercises it. (The single most-violated rule under iteration;
   check it on every fix pass.)
4. **Inherited obligations.** A row whose behavior another document must implement carries an
   explicit "(inherited obligation for the <X> doc)" marker, and appears in the outbound
   obligations table naming the rows that carry it.
5. **Copy honesty.** User-facing strings promise only what requirement rows deliver — no
   unbounded "always/never/instant" claims a row does not back. A restatement of a rule in copy
   or in a note cites the owning row.
6. **Status integrity.** A row's status flips only on a unanimous non-abstaining reviewer
   disposition or the owner's recorded authorization. Owner-authorized edits to an aligned row
   keep alignment and say so inline. Nothing flips silently, and priorities, statuses and
   historical decisions survive every amendment.
7. **Row concision.** A dispositionable row states its rule in at most two sentences. Rationale,
   evidence cites, and fence cites live outside the row — in the fence file, the OQ results, or a
   footnote — never in the cell. Split a row only where the rules genuinely differ; under
   iteration the table shrinks, it never grows by restatement.
8. **Companion files.** Four companions live beside the PRD: `<prd-slug>-journeys.md` (the
   acceptance scenarios — the harness statement, the transition index, the per-journey
   Given/When/Assert tables, the test-controls map), `<prd-slug>-copy.md` (one section per
   user-facing state, with its variants), `<prd-slug>-fences.md` (one dated fence per owner
   decision, plus the fence → row map and the rejected findings), and `<prd-slug>-oq-results.md`
   (one section per answered Open Question). The PRD body carries only their indexes — the
   journeys paragraph, the copy index, the constants and open-question tables — and the word
   budget (rule 14) applies to the body, companions excluded.
9. **Observable, declarable, closed.** Every copy state and its variants are observable by a test
   without wording matching, from an enumerated variant set; every seam input a case exercises is
   declarable; a case that asserts a value the document gives no way to read is a defect, as is a
   case whose fixture no row grants. **A `Given` names a SYNTHETIC value — a record, account,
   name, address, identifier or message invented for the case — never real user data.** These
   documents are committed to the repo, carried by path into every review brief, optionally sent
   to an external model provider on a cross-model pass, and quoted into change-request comments:
   a real record dropped into a fixture travels all four of those routes at once.
10. **Values, not adjectives.** An acceptance assert names the value, the state or the count.
    "Correct", "unchanged", "appropriate" and "as expected" are not oracles.
11. **One home per rule.** A rule lives in an ID-carrying row. Preambles, notes, fences, journeys
    and README text restate and cite; they never introduce.
12. **Both sides of every seam.** A new constant, fixture, variant or obligation that a sibling
    document must honor lands on both sides in the same change, with a dated clarification on the
    sibling fence it touches.
13. **Owner ratifies every WHAT.** An agent-authored amendment may proceed under one blanket
    approval, but every WHAT choice inside it (new row, changed rule, moved rule, retired text,
    priority or status change, OQ answer, interim, sibling amendment) is listed for the owner and
    recorded as its own dated fence citing the owner's decision before re-lock. Fence language is
    not settlement.
14. **Budget and count.** The PRD body has a project-supplied word budget (default **12,000**).
    Count method: strip HTML comments, link targets, code fences and table pipes. Trim rule-free
    prose to fit; never raise the budget; a document that cannot fit is two PRDs.
