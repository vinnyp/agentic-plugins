# Decisions: Link Shortener

## Preamble

Every fence below is **settled**: it is carried into every review brief and every editing dispatch
for this PRD, and it is never re-litigated. A reviewer finding that a fence already settles is not
re-raised.

**Historical baseline:** fences F1–F3 predate the current lock and stand as recorded. An
amendment preserves them; it does not re-decide them.

**Review log:** `docs/agent-reviews/2026-02-20-link-shortener-peer-reviews.md`.

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

### F1 — One surface for the first release (2026-02-20)

- **Authority:** the example owner, in the scoping review of 2026-02-20. This example's authorities
  name the example owner rather than linking to a decision record, because no real review produced
  them; see this example's README.
- **Decision:** the first release ships one surface, the link manager. Vanity short codes and bulk
  import are out of the release.
- **Why:** the two non-goals are the ones a builder would otherwise read into the short-code rule
  and the owner's link list.
- **Carried by:** R1.1, R1.2, R1.5, E1, E2, E3

### F2 — Interim maximum destination length (2026-02-27)

- **Authority:** the example owner, on the 2026-02-27 draft. Illustrative, as F1 states.
- **Decision:** R1.1 is built against an interim max-destination-length of 2,048 characters, and
  the copy that states that number waits until OQ 1 closes.
- **Carried by:** R1.1, E2

**Clarified 2026-03-05 (the example owner, on the round-2 fix pass):** the interim bounds the
destination as submitted, before any redirect the destination itself performs.

### F3 — Screening and retention stay open (2026-03-05)

- **Authority:** the example owner, on the round-2 disposition of 2026-03-05. Illustrative, as F1
  states.
- **Decision:** R2.3 states the posture this product area would hold, and is not started until
  OQ 2 settles whether the Edge Delivery PRD owns that posture instead. No interim rule is set.
- **Why:** an interim here would have a builder ship a screening rule and a retention window that
  the seam may move wholesale.
- **Carried by:** R2.3, M2

## Fence → row map

- **F1** — R1.1, R1.2, R1.5, E1, E2, E3
- **F2** — R1.1, E2
- **F3** — R2.3, M2

## Rejected findings

| # | Finding | Raised by (round) | Owner's reason | Authority |
|---|---|---|---|---|
| 1 | The short-code alphabet and length should become a named constant beside max-destination-length. | the product lens, round 1 | The alphabet and the length are settled and have no closure evidence pending, so a constants row for them would name a gate that nothing closes. R1.2 states both directly, which is where a builder reads them. | the example owner, on the round-1 disposition of 2026-02-27. Illustrative, as F1 states. |
