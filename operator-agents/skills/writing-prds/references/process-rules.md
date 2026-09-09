# PRD process rules

Every fill, fix, and review of a PRD authored with `writing-prds` operates under these rules.
They travel verbatim in fill dispatches and gate briefs.

1. **WHAT, not HOW.** Requirements state product behavior and verifiability obligations — "a test
   can set/observe/induce X" — never mechanisms, module names, or API shapes. (This is what lets
   reviewers judge rows without objecting to missing implementation detail.)
2. **Evidence discipline.** Every factual claim cites its source. Documentary evidence carries a
   confirm-on-verification qualifier. Unknown numbers become NAMED TBD constants, each with a
   candidate value and its Open-Question id; no constant ships with its OQ unresolved.
3. **Testability pairing.** A change to any requirement touches its verification-seam row in the
   same pass — a reshape must never orphan its injection. (The single most-violated rule under
   iteration; check it on every fix pass.)
4. **Inherited obligations.** A row whose behavior another document must implement carries an
   explicit "(inherited obligation for the <X> doc)" marker.
5. **Copy honesty.** User-facing strings promise only what requirement rows deliver — no
   unbounded "always/never/instant" claims a row does not back.
6. **Status integrity.** A row's status flips only on a unanimous non-abstaining reviewer
   disposition or the owner's recorded authorization. Owner-authorized edits to an aligned row
   keep alignment and say so inline. Nothing flips silently.
7. **Row concision.** A dispositionable row states its rule in at most two sentences.
   Rationale, evidence cites, and fence cites live outside the row — in the fence file, the OQ
   results, or a footnote — never in the cell. Split a row only where the rules genuinely
   differ; under iteration the table shrinks, it never grows by restatement.
8. **Companion files.** User journeys (§4) and user-facing strings (§6) live in companion files
   beside the PRD — `<prd-slug>-journeys.md` and `<prd-slug>-copy.md` — and the PRD body carries
   only their index (ID, one line, the rows served). The PRD body is the tables, the Legend, and
   the Open Questions; the word budget (the skill's Phase 2) applies to it, companions excluded.
