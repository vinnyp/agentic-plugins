# PRD: Link Shortener

Status: locked (2026-03-12)

Companions: `docs/product/link-shortener-journeys.md` (acceptance scenarios) ·
`docs/product/link-shortener-copy.md` (copy) ·
`docs/product/link-shortener-fences.md` (decisions) ·
`docs/product/link-shortener-oq-results.md` (open-question results)

Format: agent-prd v1

**Format contract.** Every section heading in this document, and the column set of the
row-transitions, constants-and-closure-gates, build-dependencies, requirement, obligations,
copy-index, metrics and open-questions tables, is fixed: the mechanical checks parse them by name.
A project may add a requirement section, add a trailing column to a requirement table, or delete a
section this format marks conditional. Any other reshaping is a fork of this format, not an
instance of it.

---

## Build contract

This PRD owns the behaviour of a short link: how a submitted destination is validated, how a short
code is assigned, what a redirect request returns in each state, and how a short link expires or is
switched off. The Edge Delivery PRD owns how those responses are served at the edge — caching,
geographic routing and the edge's own failure behaviour — and owns nothing this document's rows
state. This PRD deliberately does not cover vanity short codes, bulk import, or any analytics
beyond the two success metrics below; the first two are settled out of the first release by F1, and
the third is decided nowhere yet and is raised as no open question because no row depends on it.

Rows own behaviour; acceptance scenarios supply fixtures, actions, oracles and source rows; copy
owns displayed text; fences own decisions. Preserve row IDs, priorities, statuses and historical
decisions; an amendment is not an implementation completion.

## Row transitions

The `Starting state` and `Result` cells carry state names, never row IDs, and only terms the
Vocabulary marks `(state)`.

| Starting state | Event | Result | Rows |
|---|---|---|---|
| unallocated | An owner submits a destination that R1.1 accepts | active | R1.1, R1.2 |
| active | The short link's expiry instant passes | expired | R1.4 |
| active | The owner switches the short link off | disabled | R1.5 |
| disabled | The owner switches the short link on | active | R1.5 |

## User journeys

The user journeys for this product area are acceptance scenarios, kept in
`docs/product/link-shortener-journeys.md`. The `### UJ n. <name>` headings there are stable
anchors: cite them, and never renumber or retitle them. Cases run per phase — a case for a state or
a variant that a phase mark holds back runs in the phase that lands it — and a finding that depends
on an environment this document has not yet measured stays behind its open question rather than
being asserted here.

## Requirements

### Vocabulary

A term that names a state of the entity this PRD governs is written `- **<term>** (state) — …`, so
the set of state names is read off this list rather than inferred from the rows; the
row-transitions table uses only terms marked that way.

- **short link** — a stored pairing of a short code with a destination, owned by one account.
- **short code** — the seven-character path segment that identifies a short link.
- **destination** — the absolute URL a short link redirects to.
- **expiry instant** — the UTC instant at or after which a short link stops redirecting; a short
  link may have none.
- **redirect request** — an HTTP GET for a short code.
- **link manager** — the one surface this product area ships: the page on which an owner creates,
  inspects and switches short links.
- **access log** — the per-redirect-request record R2.3 bounds; it is the raw form from which the
  M2 rate is computed, and no other stored form of a redirect request exists.
- **max-destination-length** — the named constant bounding a destination's length in characters;
  the constants table below carries its interim value and the evidence that closes it.
- **unallocated** (state) — the short code is assigned to no short link.
- **active** (state) — the short link answers a redirect request with its destination.
- **expired** (state) — the short link's expiry instant has passed, and it no longer redirects.
- **disabled** (state) — the owner has switched the short link off, and it no longer redirects.

### Legend

**Priority — choose exactly one semantic for this release and delete the other bullet before
lock:**

- **Build order within the release — nothing droppable.** Every P0/P1/P2 row ships in this
  release; priority only orders the sequence work happens in.

| Pri | Meaning |
|---|---|
| P0 | Blocks the first usable build: the link manager cannot be exercised without it. |
| P1 | Built after the P0 rows, inside the same release. |
| P2 | Built last inside the release; no row in this document carries it. |

**Release.** The `Release` column on a requirement row names the release that row ships in, in the
project's own release vocabulary. Priority orders the work inside a release; this column says which
release. A row not yet assigned to one leaves the cell empty.

**Phase rule.** A P0 state that offers an action whose rows are P1 is shown without that action
until those rows land. Surfaces, states, actions and body variants carry phase marks as three
distinct kinds — a surface that does not exist yet, an action that is absent from a surface that
does, and a body variant that is not yet produced — and a phase mark says which kind it is. The
mark is written `[phase: surface-absent]`, `[phase: action-absent]` or `[phase: variant-absent]`;
those three are the complete set, here and in the copy companion.

**Status vocabulary** (every requirement, error/state and success-metric row uses exactly these
six values, in this order of progression):

| Status | Meaning |
|---|---|
| pre-alignment | Drafted, not yet reviewed. |
| needs-discussion | Reviewed; at least one open objection or fork. |
| aligned | Reviewed; unanimous non-abstaining disposition, or an owner overrule recorded with the standing objection and reason. |
| in-progress | Aligned and being built. |
| done | Built and verified. |
| deferred | Explicitly cut from this release, not abandoned. |

**Constants and closure gates**

| Constant | Candidate / interim | Owning rows | Closure evidence |
|---|---|---|---|
| max-destination-length | 2,048 characters; interim rule — accept a destination at or below it and reject a longer one | R1.1 | OQ 1 — the length distribution of the destinations submitted during the first dogfood week |

This table is an index: every constant it names is also named in the row that owns it, and that row
is the constant's home. Where the two disagree, the row governs.

**Build dependencies**

| Work | Available contract | What must remain open |
|---|---|---|
| Link manager and create flow | R1.1, R1.2 and R1.5, and copy states E1, E2 and E3 | OQ 1's closure evidence — the interim length F2 set holds until the dogfood sample closes it |
| Redirect handler and expiry | R1.3 and R1.4, and the envelope R2.1 and R2.2 state | nothing |
| Security and privacy posture | none | OQ 2 — whether this product area or the Edge Delivery PRD owns destination screening and redirect-log retention |

A builder builds against the **Available contract** column only. Anything under **What must remain
open** is a stop rather than a guess: that work waits for the ADR, the open question, the hardware
or the dogfood run named there.

**P0 rows that defer to an open question with no interim rule:**

A row in this first list cannot be started: its open question has no interim rule, so a builder
that begins it is guessing. A row in the **Interim stated** list below is started under the interim
rule named there, and re-checked when its open question closes.

- R2.3 — OQ 2.

**Interim stated:**

- R1.1 — OQ 1 — F2.

### Traceability

- Every requirement row gets an ID of the form `R<section>.<n>` (e.g. `R7.4`), where `<section>`
  is the number of its requirement section below.
- Every error/state row in the copy index gets an ID of the form `E<n>` (e.g. `E4`).
- Every success-metric row gets an ID of the form `M<n>` (e.g. `M2`).
- A lead row that carries a table of its own numbers those sub-rows with letters (`R8.1a`).
- IDs are assigned once and never renumbered. **Retired IDs:** none — no ID in this document has
  been retired.
- The **Commit PR** column on a requirement row names the PR that landed it — attributed to the
  PR, not to a bare commit SHA.
- Owner decisions F1–F3 are in the fence file; a row names one for provenance only.

### Surfaces

Every copy state appears under exactly one surface unless this preamble names it as shared. This
product area ships one surface, and no copy state is shared: each of E1, E2 and E3 belongs to the
link manager alone.

| Surface | Shows | The copy states in this surface's flow |
|---|---|---|
| Link manager | The destination field, the submit action, each short link the owner has created, and the switch that turns one off and on | E1, E2, E3 |

### 1. Short links

Traces UJ 1; serves the vision use case *share a long address in a short message*.

| ID | Release | Pri | Requirement | Status | Commit PR |
|---|---|---|---|---|---|
| R1.1 | v1 | P0 | A submitted destination is accepted only when it uses the http or https scheme and is at most **max-destination-length** characters. A destination that fails either test is rejected, no short code is assigned, and the link manager renders E2. | aligned | |
| R1.2 | v1 | P0 | On acceptance the product assigns an unused short code of exactly seven characters drawn from the alphabet 0-9a-z, and the short link becomes active. The link manager renders E1 showing that short code. | aligned | |
| R1.3 | v1 | P0 | A redirect request for an active short code returns HTTP 301 with the short link's destination in the Location header (inherited obligation for the Edge Delivery PRD). A redirect request for an expired or a disabled short code returns HTTP 410, and one for an unallocated short code returns HTTP 404. | aligned | |
| R1.4 | v1 | P1 | A short link created with an expiry instant becomes expired at that instant, and one created without an expiry instant never becomes expired. The link manager renders E3 for a short link that no longer redirects. | aligned | |
| R1.5 | v1 | P0 | The owner may switch an active short link off, and switch a disabled short link back on. The link manager distinguishes a short link that no longer redirects as exactly one of "owner-disabled" or "time-expired" [phase: variant-absent]. | aligned | |

### 2. Operating envelope and quality attributes

Traces UJ 1; serves the vision use case *share a long address in a short message*.

The rows here state the operating envelope this product area must hold: latency and throughput
budgets, data volumes and their growth, concurrency and retry semantics, offline and
partial-failure behaviour, platform and version compatibility, durability, and security and privacy
posture. Not conditional — each of those classes is answered by at least one row here, or by a row
stating that this product area has no requirement of that class and why. A class left out is a
latent decision, not a silent "no requirement".

| ID | Release | Pri | Requirement | Status | Commit PR |
|---|---|---|---|---|---|
| R2.1 | v1 | P0 | A redirect request is answered within 150 ms at the 99th percentile at up to 500 requests per second, against a store holding up to 10 million short links and growing by at most 1 million a year. A redirect request that cannot reach that store is answered with HTTP 503 rather than a redirect, and an acknowledged create survives the loss of any single storage node. | aligned | |
| R2.2 | v1 | P0 | Creating a short link is idempotent under retry: the same destination resubmitted by the same owner within one minute returns the short code already assigned, and two concurrent submissions of it resolve to exactly one short code. The link manager supports the current and one prior major release of each evergreen browser and has no offline requirement, because a short link has no value without the network that resolves it. | aligned | |
| R2.3 | v1 | P0 | Short codes are served over HTTPS only, and the product refuses to create a short link whose destination host resolves to a private-network or loopback address. For each redirect request the access log retains only the short code, the request timestamp truncated to the hour and the two-letter country, for 30 days. | aligned | |

## Inherited obligations

Every cross-document cite in this PRD and its companions names the owning document in its visible
label — "the device PRD's `R6.27`", never a bare `R6.27` — because the row-ID families repeat
across PRDs. An ID written bare is this document's own.

**Outbound** — what this PRD requires of other documents:

| Target PRD | Obligation | Rows |
|---|---|---|
| the Edge Delivery PRD (illustrative: no such document exists beside this example — this row is here to show the seam grammar, not to record a real seam) | Serve the HTTP 301, 410 and 404 responses R1.3 states, at the edge, inside the latency and throughput budget R2.1 states | R1.3, R2.1 |

## Error and state copy index

| ID | State | Surface | Owning rows | Status |
|---|---|---|---|---|
| E1 | Link created | Link manager | R1.2 | aligned |
| E2 | Destination rejected | Link manager | R1.1 | aligned |
| E3 | Link switched off | Link manager | R1.4, R1.5 | aligned |

**Labels rule.** `docs/product/link-shortener-copy.md` is the one place a user-facing label is
written; every action a row names is quoted from it.

**Placeholders rule.** The copy uses one render token, ⟨code⟩, which renders the short code R1.2
assigns. This product area's copy carries no count token, so the zero-count rule has no subject in
this document; a count token added later states here what it renders at zero.

**Variant enumeration rule.** A copy state that has variants names, in its copy-companion entry,
the requirement row that enumerates its variant set, and that row lists the variant names verbatim.
A variant no row enumerates is untestable without matching on wording; an enumerated variant with
no copy is text the builder would have to invent.

**Standing label check.** Run on every copy or row amendment, over the whole product-docs tree:

```bash
# Every quoted label in the copy companion, with every place in the tree that mentions it.
# Each hit must be either the copy companion's owning entry or a row/case quoting it verbatim.
set -o pipefail
rg -o --no-filename -r '$1' '"([^"]+)"' "docs/product/link-shortener-copy.md" \
  | sort -u \
  | while IFS= read -r label; do
      printf '\n== %s\n' "$label"
      rg -n --fixed-strings -- "$label" "docs/product" || echo '   (no other mention)'
    done
# Without ripgrep, the two substitutions are:
#   rg -o --no-filename -r '$1' '"([^"]+)"' F   ->   grep -oh '"[^"]*"' F | sed 's/^"//; s/"$//'
#   rg -n --fixed-strings --                    ->   grep -rnF --include='*.md' --
# The `sed` is load-bearing: `rg -r '$1'` yields the label WITHOUT its quote marks, `grep -oh`
# keeps them, and a search for a quoted string can never find the defect this check exists for —
# a row that states a label instead of quoting it.
```

Each label is read into a shell variable and passed quoted, with `--fixed-strings` and a `--`
end-of-options guard: text taken out of a document is never interpolated into a command string.
The substituted `docs/product` is a literal path, quoted wherever it appears, so a path
containing a space cannot word-split a search into a false clean result.

## Success metrics

| ID | Metric | Definition (start event, end event, statistic, population) | Candidate target | Method | Status |
|---|---|---|---|---|---|
| M1 | Create-to-copy completion | Start: a destination is submitted in the link manager; end: the "Copy link" action fires for the short code that submission produced, in the same session; statistic: the share of submissions reaching that end event; population: every submission in a calendar week. | 80%, illustrative — this example carries no measured baseline and no benchmark | The link manager's client event stream, which records one submitted event and one copied event per short code | aligned |
| M2 | Redirect answer rate | Start: a redirect request arrives; end: its response is sent; statistic: the share of responses carrying HTTP 301, 410 or 404 rather than 5xx; population: every redirect request in a calendar day. | 99.9%, illustrative — this example carries no measured baseline and no benchmark | The access log R2.3 bounds, counted by status code | aligned |

## Open questions

| # | Question | Decision so far | Interim rule | Closer | Feeds (row IDs) | Status |
|---|---|---|---|---|---|---|
| 1 | How long a destination does the product have to accept? | Answered on an interim basis at 2,048 characters, from the shortest limit documented across the browsers R2.2 supports; the results file carries the finding. | Accept a destination of at most 2,048 characters and reject a longer one; the copy that states the number waits for closure. | The example owner, on the length distribution of destinations submitted during the first dogfood week. | R1.1 | aligned |
| 2 | Does this product area own destination screening and redirect-log retention, or does the Edge Delivery PRD own both at the edge? | None. | | The example owner, once the Edge Delivery PRD exists. | R2.3 | needs-discussion |

Every open question carries an interim rule, or its P0 rows are listed in the Legend's no-interim
bullet — there is no third option, and which of the two applies is what tells a builder whether it
may start the rows that question feeds.

Results file: `docs/product/link-shortener-oq-results.md`, one `## OQ <id>` section per
answer; an OQ's Status may change only when its section exists. Every inline
confirm-on-verification marker in this document carries its OQ id; a marker without a matching OQ
is invalid.

---

Upstream: this PRD traces to the product vision at `docs/product/vision.md` and the current
product strategy at `docs/product/strategy.md`. Where it narrows or overrides either, the
build contract says so.
