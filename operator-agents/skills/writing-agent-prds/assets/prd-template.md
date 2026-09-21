<!-- guidance (the principle this whole format exists to enforce — read before filling anything):
     Rows own behaviour; acceptance scenarios supply fixtures, actions, oracles and source rows;
     copy owns displayed text; fences own decisions. Anything a builder needs to know lives in
     exactly one of those four places and nowhere else. A rule restated in a preamble, a note, a
     journey or a README is a restatement that cites its owning row — it never introduces.
     Template shape is never the point; buildability by an agent is — but the shape is fixed
     rather than advisory: the Format contract below names what a project may change and what it
     may not, and the mechanical checks parse the sections it fixes by name.
     Two fill families are placeholders: `{{...}}`, substituted at scaffold time, and `_(prompt)_`,
     filled during authoring; an unresolved instance of EITHER is a lock-blocking defect. Every
     guidance comment in this file — this one included — is deleted at lock, so a rule a BUILDER
     needs after lock lives in body text and never in a comment; a comment carries only what an
     AUTHOR needs while filling the document. The word budget for this body (companions excluded)
     is {{word-budget}} words: count it with HTML comments, link targets, code fences and table
     pipes stripped; trim rule-free prose to fit; never raise the budget; a document that cannot
     fit is two PRDs.
     {{word-budget}}: the project-supplied word budget for this PRD body, default 12000. -->

# PRD: {{product-area}}
<!-- guidance: {{product-area}} is the product or feature area this PRD governs — a short name,
     substituted once at scaffold time. The PRD's file name and its `<prd-slug>` are derived from
     it, and that slug names every state artifact below (journeys, copy, fences, OQ results). -->

Status: draft
<!-- guidance: the status line has exactly three forms, in this order over the document's life.
     At scaffold: `Status: draft`. At lock: `Status: locked (<date>)`. An amendment APPENDS to the
     locked form: `; agent-build amendment <date> under F<n>–F<m> (peer review pending)` — naming
     the fence range that authorises it. The bookkeeping close then REWRITES that appended clause
     to `; peer review closed <date> (PR #<n>); re-locked on merge`, and changes nothing else.
     There is no author line in this document: the owner is named in the fence file. -->

Companions: `{{product-docs-dir}}/<prd-slug>-journeys.md` (acceptance scenarios) ·
`{{product-docs-dir}}/<prd-slug>-copy.md` (copy) ·
`{{product-docs-dir}}/<prd-slug>-fences.md` (decisions) ·
`{{product-docs-dir}}/<prd-slug>-oq-results.md` (open-question results)
<!-- guidance: name all four companions by path, on one line, so an agent handed only this file
     can find every other place a rule of this product lives. Not conditional: all four exist from
     scaffold time, even while empty.
     The four SUFFIXES are a contract, not a convention: `-journeys.md`, `-copy.md`, `-fences.md`
     and `-oq-results.md`. The mechanical checks parse this line to resolve the companions and
     assert that all four are declared, so renaming one is a breaking format change that must be
     made here and in the checks together.
     {{product-docs-dir}}: the project's product-docs directory, written REPO-ROOT-RELATIVE (e.g.
     `docs/product`), not as an absolute path and not relative to this file. The mechanical checks
     resolve companion paths against the repository root, so a path written any other way makes
     them resolve against the wrong base. Where this PRD and its four
     companions live — never `/tmp`, always in the project repo. -->

Format: agent-prd v1
<!-- guidance: the format version this document is authored to, and the version whose checks a
     re-lock runs. A change to the format that would make a conforming document non-conforming — a
     renamed section, a changed column set, an added lock condition — is a new major version;
     re-locking under a newer version is a deliberate migration, recorded as its own fence.
     What v1 fixes, and what an author may therefore change: every section heading in this
     document, and the column set of the row-transitions, constants-and-closure-gates,
     build-dependencies, requirement, obligations, copy-index, metrics and open-questions tables,
     is fixed — the mechanical checks parse them by name. A project may add a requirement section,
     add a trailing column to a requirement table, or delete a section this format marks
     conditional. Any other reshaping is a fork of this format, not an instance of it. This
     version line is the locked document's one citation of that contract; the contract itself is
     not restated in body text, because it is a rule for authoring and checking this document and
     not for building the product. -->

---

## Build contract
<!-- guidance: two paragraphs, no headings inside, and nothing else. This section REPLACES the
     background section, the problem statement, persona-story headings and every piece of inline
     narrative a human-audience PRD carries — a building agent needs ownership and rules, not
     motivation, and narrative is where behaviour hides.
     Paragraph 1 — ownership: what this PRD owns, and what each sibling document owns instead, one
     clause per sibling, each naming that sibling BY DOCUMENT NAME, then what this PRD
     deliberately does not cover. A reader who lands here must be able to route any question to
     the document that answers it — and a non-goal stated here is a question a builder stops
     asking, where an unstated one is a gap it fills by guessing.
     Paragraph 2 — the four-place rule (rows / acceptance scenarios / copy / fences), plus,
     verbatim: "Preserve row IDs, priorities, statuses and historical decisions; an amendment is
     not an implementation completion." If this PRD is gated on an open architectural fork, name
     it here with its open question and its ADR, and state that neither reading is selected here.
     {{sibling-document-name}}: one per sibling PRD this document shares a seam with — the
     document names used in this paragraph and in every cross-PRD cite in this file. -->

This PRD owns _(what this document is the single source of)_. {{sibling-document-name}} owns
_(what that document owns instead)_ — _(one clause per sibling, by document name)_. This PRD
deliberately does not cover _(the non-goals, and where each is decided instead if it is decided at
all)_.

Rows own behaviour; acceptance scenarios supply fixtures, actions, oracles and source rows; copy
owns displayed text; fences own decisions. Preserve row IDs, priorities, statuses and historical
decisions; an amendment is not an implementation completion. _(If an architectural fork is open:
name it, cite its open question and its ADR, and state that neither reading is selected here.)_

## Row transitions
<!-- guidance: one table, one row per route between the states of the entity this PRD governs,
     each naming the requirement rows that own the route. This section REPLACES the lifecycle
     diagram: a diagram is read, a table is checked.
     Enumerate the routes FROM THE REQUIREMENT ROWS, not from memory — walk every row that can
     change the entity's state and give its route a line here. A route any row can cause and this
     table omits is a defect (two reviewers independently caught one omitted route in the first
     conversion run of this format). -->

The `Starting state` and `Result` cells carry state names, never row IDs, and only terms the
Vocabulary marks `(state)`.

| Starting state | Event | Result | Rows |
|---|---|---|---|
| | | | |

## User journeys
<!-- guidance: one paragraph, no table. The journeys themselves are acceptance scenarios and live
     in the journeys companion; this paragraph points at it and states the three things a reader
     needs to use it: the `### UJ n. <name>` headings are stable anchors (cite them, never
     renumber them), cases run per phase, and hardware- or environment-gated findings stay behind
     their open questions rather than being asserted here. -->

The user journeys for this product area are acceptance scenarios, kept in
`{{product-docs-dir}}/<prd-slug>-journeys.md`. _(State that the `### UJ n. <name>` headings there
are stable anchors, that cases run per phase, and that gated findings stay behind their OQs.)_

## Requirements

### Vocabulary
<!-- guidance: every term the rows use, one line each — a term a row leans on and this list does
     not define is a latent decision. Include the product's measurement tiers where it has them
     (e.g. the raw, the stored and the computed form of whatever this product measures) and EVERY
     state name the row-transitions table uses. Not conditional. -->

A term that names a state of the entity this PRD governs is written `- **<term>** (state) — …`, so
the set of state names is read off this list rather than inferred from the rows; the
row-transitions table uses only terms marked that way.

- **_(term)_** — _(one line.)_

### Legend
<!-- guidance: the vocabularies every later table depends on: priority semantics (exactly one of
     the two bullets survives to lock — delete the other), the phase rule, the status vocabulary,
     then the two tables and the two bullets below. Not conditional. -->

**Priority — the semantic the `Pri` column carries in this release:**

- **Build order within the release — nothing droppable.** Every P0/P1/P2 row ships in this
  release; priority only orders the sequence work happens in.
- **Cut line — lower priorities may not ship.** Priority marks what survives if scope tightens;
  the cut line is stated explicitly per release, never implied by ordering.

| Pri | Meaning |
|---|---|
| P0 | _(e.g. blocks the first usable build)_ |
| P1 | _(e.g. in this release, above the cut line)_ |
| P2 | _(e.g. candidate for this release, first to cut if scope tightens)_ |

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
<!-- guidance: every named provisional constant this product has, its candidate value or "TBD"
     plus the interim rule that holds until it closes, the rows that use it, and the open question
     plus the evidence that closes it. Names identify product parameters, not storage columns or
     API names. Every constant listed here is also named in its owning row — this table is an
     index, not the constant's home. -->

| Constant | Candidate / interim | Owning rows | Closure evidence |
|---|---|---|---|
| | | | |

This table is an index: every constant it names is also named in the row that owns it, and that row
is the constant's home. Where the two disagree, the row governs.

**Build dependencies**
<!-- guidance: what the first build can proceed on, and what must stay gated. One row per unit of
     work: the contract already available to build against, and what must remain open (an ADR, an
     open question, hardware, a dogfood run) rather than being guessed at by the builder. -->

| Work | Available contract | What must remain open |
|---|---|---|
| | | |

A builder builds against the **Available contract** column only. Anything under **What must remain
open** is a stop rather than a guess: that work waits for the ADR, the open question, the hardware
or the dogfood run named there.

**P0 rows that defer to an open question with no interim rule:**
<!-- guidance: these two lists stay separate and are NEVER merged into one — merging them hides
     the difference the body text below states. Derive both from the Open questions table, not
     from memory. -->

A row in this first list cannot be started: its open question has no interim rule, so a builder
that begins it is guessing. A row in the **Interim stated** list below is started under the interim
rule named there, and re-checked when its open question closes.

- _(row ID — the open question it defers to.)_

**Interim stated:**

- _(row or metric ID — the open question — the fence that set the interim.)_
<!-- guidance: any ID family may appear here, including an `M<n>` metric row, which carries no
     `Pri` column at all — this list is not priority-filtered, unlike the one above it. A row runs
     under the named interim whatever its priority, and is re-checked when the question closes. -->

### Traceability
<!-- guidance: the ID contract. Three families, one per dispositionable table; lettered sub-rows
     where a lead row carries a table of its own (`R8.1a`); assigned once at first draft and never
     renumbered, so a cut or deferred row keeps its ID rather than freeing it for reuse; retired
     IDs listed by ID so a reader who finds a cite can resolve it. Not conditional.
     Fill the **Commit PR** column with the pull (or merge) request that landed the row, never with
     a bare commit SHA: a SHA stops resolving the moment the branch is squashed on merge. -->

- Every requirement row gets an ID of the form `R<section>.<n>` (e.g. `R7.4`), where `<section>`
  is the number of its requirement section below.
- Every error/state row in the copy index gets an ID of the form `E<n>` (e.g. `E4`).
- Every success-metric row gets an ID of the form `M<n>` (e.g. `M2`).
- A lead row that carries a table of its own numbers those sub-rows with letters (`R8.1a`).
- IDs are assigned once and never renumbered. **Retired IDs:** _(list them; never reuse them.)_
- The **Commit PR** column on a requirement row names the PR that landed it.
- Owner decisions F1–F<n> are in the fence file; a row names one for provenance only.

### Surfaces
<!-- guidance: every user-facing surface this product area touches, what it shows, and the copy
     states in that surface's flow. Every copy state appears under exactly one surface unless the
     state is deliberately shared, in which case this preamble says so and names the surfaces.
     Phase marks (see the Legend's phase rule) go on P1-only surfaces, states and actions. The copy
     strings themselves are never written here — they live in the copy companion. Conditional: a
     product area with no user-facing surface deletes this subsection rather than leaving it
     empty. -->

Every copy state appears under exactly one surface unless this preamble names it as shared.
_(Preamble: name any copy state deliberately shared across surfaces, and the surfaces sharing it.)_

| Surface | Shows | The copy states in this surface's flow |
|---|---|---|
| | | |

### 1. {{requirement-section-name}}
<!-- guidance: one subsection per group of requirements; its heading number is the `<section>` in
     `R<section>.<n>`, so section 1's rows are `R1.1`, `R1.2`, … Repeat this exact table header on
     every section. Open each section with a `Traces UJ…` line naming the journeys that exercise
     it and the vision use case it serves — a section no journey exercises is either unjustified
     or missing a journey. Each row states its rule in at most two sentences: rationale, evidence
     cites and fence cites live outside the cell. Every constant a row uses is NAMED IN THAT ROW,
     not only in the Legend's constants table.
     {{requirement-section-name}}: the name of this requirement section — one per group of rows
     this PRD's product area divides into.
     Three COLUMN NAMES are a contract, here and in the copy index and the metrics table: `ID`,
     `Pri` and `Status`. The mechanical checks locate them by header name rather than by position,
     precisely because the three tables put `Status` in three different columns — so adding a
     column or reordering one is safe, and RENAMING any of those three is a breaking format change
     that silently empties a check's field. Rename one only as a deliberate format version. -->

Traces UJ_(n)_, UJ_(n)_; serves the vision use case _(name)_.

| ID | Release | Pri | Requirement | Status | Commit PR |
|---|---|---|---|---|---|
| | | | | | |

### 2. Operating envelope and quality attributes
<!-- guidance: mandatory, and always the LAST numbered requirement section. Its heading takes the
     number after the project's own requirement sections — assigned at scaffold time, before any
     ID exists, and never changed afterwards — so its rows are `R<that number>.<n>` and are
     ordinary requirement rows in every respect: same columns, same priorities, same statuses,
     same acceptance cases in the journeys companion, same named constants in the Legend's
     constants table. This is the class of requirement a builder most often has to go back to
     product for, so the format scaffolds it rather than leaving it to be remembered. -->

Traces UJ_(n)_; serves the vision use case _(name)_.

The rows here state the operating envelope this product area must hold: latency and throughput
budgets, data volumes and their growth, concurrency and retry semantics, offline and
partial-failure behaviour, platform and version compatibility, durability, and security and privacy
posture. Not conditional — each of those classes is answered by at least one row here, or by a row
stating that this product area has no requirement of that class and why. A class left out is a
latent decision, not a silent "no requirement".

| ID | Release | Pri | Requirement | Status | Commit PR |
|---|---|---|---|---|---|
| | | | | | |

## Inherited obligations
<!-- guidance: outbound first — every behaviour this PRD's rows require another document's product
     to implement. The inbound table is conditional on siblings existing: when they do, it carries
     the same three columns for what those documents require of this one.
     Standing check, run on every amendment: the obligation summary on each side of a seam says
     the same thing; a change on one side lands on the other IN THE SAME PR, with a dated
     clarification on the fence it touches. The most common missing thing in an amendment is the
     sibling half of a mirror. -->

Every cross-document cite in this PRD and its companions names the owning document in its visible
label — "the device PRD's `R6.27`", never a bare `R6.27` — because the row-ID families repeat
across PRDs. An ID written bare is this document's own.

**Outbound** — what this PRD requires of other documents:

| Target PRD | Obligation | Rows |
|---|---|---|
| | | |

**Inbound** — what other documents require of this one:
<!-- conditional: include only when sibling PRDs exist; delete the heading and table otherwise. -->

| Target PRD | Obligation | Rows |
|---|---|---|
| | | |

## Error and state copy index
<!-- guidance: the index of the copy states, plus the three standing rules below. The copy text
     itself — headline, body, actions, variants — lives in the copy companion and nowhere else.
     Labels rule: the copy companion is the ONE place a user-facing label is written, and every
     action a row names is quoted from it.
     Placeholders rule: name the tokens in use, the zero-count rule (what a count token renders as
     at zero), and which row a ⟨code⟩ token names.
     Variant enumeration rule: the row that enumerates a state's variants lists the variant names
     verbatim.
     The Labels rule is enforced by a runnable search over the whole product-docs tree, run on
     every copy or row amendment. The command lives with the mechanical checks (check 13, "The
     standing label check, run") and is not carried in this document: it is how the document is
     checked, not something a builder reads. -->

| ID | State | Surface | Owning rows | Status |
|---|---|---|---|---|
| | | | | |

**Labels rule.** `{{product-docs-dir}}/<prd-slug>-copy.md` is the one place a user-facing label is
written; every action a row names is quoted from it.

**Placeholders rule.** _(Name the tokens in use, what each count token renders as at zero, and
which row each ⟨code⟩ token names.)_

**Variant enumeration rule.** A copy state that has variants names, in its copy-companion entry,
the requirement row that enumerates its variant set, and that row lists the variant names verbatim.
A variant no row enumerates is untestable without matching on wording; an enumerated variant with
no copy is text the builder would have to invent.

## Success metrics
<!-- guidance: precise enough that two people computing the same metric from the same data get the
     same number. The Method column names the OBSERVABLE a test or a dogfood runbook reads — not
     "measure adoption" but the event, surface or file it is read from; evidence artifacts are
     named files. Not conditional. -->

| ID | Metric | Definition (start event, end event, statistic, population) | Candidate target | Method | Status |
|---|---|---|---|---|---|
| | | | | | |

## Open questions
<!-- guidance: every question this PRD cannot yet answer that blocks a row. Closer names who or
     what closes it (the evidence, the run, the owner call), Feeds names the row IDs it blocks; an
     OQ with no row it feeds is scope creep, not a blocker. Reserved numbers stay reserved: a
     withdrawn OQ keeps its number rather than freeing it. Not conditional. -->

| # | Question | Decision so far | Interim rule | Closer | Feeds (row IDs) | Status |
|---|---|---|---|---|---|---|
| | | | | | | |

Every open question carries an interim rule, or its P0 rows are listed in the Legend's no-interim
bullet — there is no third option, and which of the two applies is what tells a builder whether it
may start the rows that question feeds.

Results file: `{{product-docs-dir}}/<prd-slug>-oq-results.md`, one `## OQ <id>` section per
answer; an OQ's Status may change only when its section exists. Every inline
confirm-on-verification marker in this document carries its OQ id; a marker without a matching OQ
is invalid.

---

Upstream: this PRD traces to the product vision at `{{upstream-vision-path}}` and the current
product strategy at `{{upstream-strategy-path}}`. Where it narrows or overrides either, the
build contract says so.
<!-- guidance: {{upstream-vision-path}} is the durable WHY this PRD serves; {{upstream-strategy-path}}
     is the active bets and roadmap it sits inside. Both are project-supplied paths, substituted at
     scaffold. A divergence from either is stated in the build contract, never left implicit. -->
