<!-- guidance: this is the acceptance-scenarios companion to `PRD: {{product-area}}`. It is the
     second of the format's four homes: rows own behaviour, and the cases here supply the
     fixtures, actions, oracles and source rows that make a row executable. A case never
     introduces a rule — if a case needs a rule this PRD's rows do not state, the row is missing.
     Two fill families are placeholders: `{{...}}`, substituted at scaffold time, and `_(prompt)_`,
     filled during authoring; an unresolved instance of EITHER is a lock-blocking defect. Every
     guidance comment in this file is deleted at lock, so a rule a BUILDER needs after lock lives
     in body text and never in a comment. -->

# Acceptance scenarios: {{product-area}}
<!-- guidance: {{product-area}} matches the PRD's title exactly, so the pair reads as one
     document; the file itself is `<prd-slug>-journeys.md` beside the PRD in
     {{product-docs-dir}}.
     {{product-docs-dir}}: the project's product-docs directory, where the PRD and its four
     companions live. -->

Rows own behaviour. The cases in this file supply fixtures, actions, oracles and the rows each
case sources; they restate and cite rules, never introduce them. Every case in this file resolves
to at least one row of `{{product-docs-dir}}/<prd-slug>.md`.

## Harness
<!-- guidance: the harness statement. Name the simulated seam a case drives (what stands in for
     the real world), and the readback controls a case asserts through (what the test can
     observe). Then, verbatim: "Declare every exercised seam input; only named defaults are
     exempt." Fixture values are declared here or in the case's Given — never copied out of the
     implementation, because a fixture copied from the code asserts the code against itself.
     The fixture-continuity rule below is BODY text, not guidance: it is the semantics under which
     a builder reads every case table in this file, and it has to survive lock.
     Not conditional: a companion with no harness statement cannot be executed unattended. -->

_(Which simulated seam the cases drive.)_ _(Which readback controls a case asserts through.)_
Declare every exercised seam input; only named defaults are exempt. Fixture values are declared,
never copied from the implementation.

**Fixture continuity.** Every case runs against a fixture reset to this harness's declared state,
unless the journey's preamble line declares continuity across that journey's cases; where it does,
each case in that journey runs against the state the previous case left. Continuity is declared in
the preamble line or it does not hold — a case never carries state no preamble granted it, and a
builder reading a case table needs no other source to know which of the two applies.

**Named defaults** _(the seam inputs a case may leave undeclared, each with its default value):_

| Seam input | Default | Rows |
|---|---|---|
| | | |

## Transition index
<!-- guidance: `T1..Tn`, one case per route through the entity lifecycle — the executable
     counterpart of the PRD's row-transitions table. Enumerate these from that table and from the
     rows, not from memory: a route the PRD's transition table names and this index omits is a
     defect, and so is the reverse. -->

| Case | Given | When | Assert | Rows |
|---|---|---|---|---|
| T1 | | | | |

## Journeys
<!-- guidance: one `### UJ n. <name>` section per journey, in the PRD's order. Under each heading:
     one line of phase/preamble (which build phase the journey's cases run in, and any continuity
     that holds across them, per the Harness's fixture-continuity rule), then the five-column case
     table.
     Rules for every case table in this file:
     - Every Assert names values or observable outcomes. "Correct", "unchanged", "appropriate" and
       "as expected" are not oracles; a case that asserts a value this document gives no way to
       read is a defect.
     - A case whose Given declares a fixture no row grants is a defect: either the row is missing
       or the fixture is invented.
     - Every copy state and every variant in the copy companion has a case here.
     - Per-cause failures get one case each — one case covering "any failure" hides the causes
       that behave differently. -->

**Case IDs.** A case ID is `UJ<journey>.<scenario>-<letter>` (`UJ3.1-a`, `UJ3.1-b`, `UJ3.2-a`). A
**scenario** is one continuous run through the journey: a journey that is walked once has a single
scenario, numbered 1, and a second scenario is a second run through the same journey from a
different starting state. Cases within a scenario are lettered in execution order. The
`### UJ n. <name>` headings are the stable anchors the PRD, the fences and sibling documents cite:
a journey is never renumbered or retitled once cited, and case IDs are assigned once and never
renumbered.

### UJ 1. _(name)_

_(Phase/preamble: which phase these cases run in; any continuity that holds across them.)_

| Case | Given | When | Assert | Rows |
|---|---|---|---|---|
| UJ1.1-a | | | | |

## Test-controls map
<!-- guidance: the last section, always. One line per surface: the input a test controls to drive
     that surface, the result it can observe, and the rows that grant both. Not conditional. -->

Every surface a case in this file drives appears in this map, or in the Harness's **Named
defaults** table. A case that drives a surface named in neither is asserting through a seam nobody
declared, and this map is what makes "declare every exercised seam input" checkable.

| Surface | Controlled input | Observable result | Rows |
|---|---|---|---|
| | | | |
