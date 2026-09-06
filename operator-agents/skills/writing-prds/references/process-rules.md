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
