# Acceptance scenarios: Link Shortener

Rows own behaviour. The cases in this file supply fixtures, actions, oracles and the rows each
case sources; they restate and cite rules, never introduce them. Every case in this file resolves
to at least one row of `docs/product/link-shortener.md`.

## Harness

The cases drive a simulated HTTP client against the link manager and against the short-code
endpoint; nothing real is served. A case asserts through the copy state and variant the link
manager displays, the short code it shows, and the status line and Location header of the response
to a redirect request. Declare every exercised seam input; only named defaults are exempt. Fixture
values are declared, never copied from the implementation.

**Fixture continuity.** Every case runs against a fixture reset to this harness's declared state,
unless the journey's preamble line declares continuity across that journey's cases; where it does,
each case in that journey runs against the state the previous case left. Continuity is declared in
the preamble line or it does not hold — a case never carries state no preamble granted it, and a
builder reading a case table needs no other source to know which of the two applies.

**Named defaults** (the seam inputs a case may leave undeclared, each with its default value):

| Seam input | Default | Rows |
|---|---|---|
| Clock | 2026-03-01T09:00:00Z, advanced only by a case step that says so | R1.4, R2.2 |
| Short-code generator | Seeded to yield abc1234, then abc1235, then abc1236 | R1.2 |
| Owner account | One synthetic owner, acct-0001, owning every short link a case creates | R1.5 |

## Transition index

| Case | Given | When | Assert | Rows |
|---|---|---|---|---|
| T1 | abc1234 unallocated | In the link manager, acct-0001 submits https://example.com/a-very-long-article-slug | The link manager renders E1 showing short code abc1234, and abc1234 is active | R1.1, R1.2 |
| T2 | abc1234 active with an expiry instant of 2026-03-02T09:00:00Z | The clock advances to 2026-03-02T09:00:01Z, then a redirect request arrives for abc1234 | The response status is HTTP 410, and abc1234 is expired | R1.4 |
| T3 | abc1234 active with no expiry instant | In the link manager, acct-0001 switches abc1234 off | The link manager renders E3 with variant "owner-disabled", and abc1234 is disabled | R1.5 |
| T4 | abc1234 disabled with an expiry instant of 2026-03-09T09:00:00Z, the clock at 2026-03-01T09:05:00Z | In the link manager, acct-0001 switches abc1234 on, then a redirect request arrives for abc1234 | The response status is HTTP 301 with Location https://example.com/a-very-long-article-slug, and abc1234 is active | R1.3, R1.5 |

## Journeys

**Case IDs.** A case ID is `UJ<journey>.<scenario>-<letter>` (`UJ3.1-a`, `UJ3.1-b`, `UJ3.2-a`). A
**scenario** is one continuous run through the journey: a journey that is walked once has a single
scenario, numbered 1, and a second scenario is a second run through the same journey from a
different starting state. Cases within a scenario are lettered in execution order. The
`### UJ n. <name>` headings are the stable anchors the PRD, the fences and sibling documents cite:
a journey is never renumbered or retitled once cited, and case IDs are assigned once and never
renumbered.

### UJ 1. Share a long address in a short message

Scenario 1 runs in the first build phase, under continuity: each of its cases runs against the
state the previous case left. Scenario 2 runs in the phase that lands R1.4 and the "time-expired"
variant, from the harness's declared state.

| Case | Given | When | Assert | Rows |
|---|---|---|---|---|
| UJ1.1-a | abc1234 unallocated, acct-0001 signed in | In the link manager, acct-0001 submits https://example.com/a-very-long-article-slug | The link manager renders E1 showing short code abc1234, and E1 offers the "Copy link" action | R1.1, R1.2 |
| UJ1.1-b | The state UJ1.1-a left | In the link manager, acct-0001 submits ftp://example.com/archive.zip | The link manager renders E2, no short code beyond abc1234 exists, and the generator's next value abc1235 stays unallocated | R1.1 |
| UJ1.1-c | The state UJ1.1-b left: abc1234 active for https://example.com/a-very-long-article-slug, abc1235 unallocated | The clock advances 40 seconds, then in the link manager acct-0001 submits https://example.com/a-very-long-article-slug a second time | The link manager renders E1 showing short code abc1234, and abc1235 stays unallocated | R1.2, R2.2 |
| UJ1.2-a | A fixture reset to the harness state, then abc1234 active with an expiry instant of 2026-03-02T09:00:00Z | The clock advances to 2026-03-02T09:00:01Z, then acct-0001 opens abc1234 in the link manager | The link manager renders E3 with variant "time-expired", and a redirect request for abc1234 returns HTTP 410 | R1.3, R1.4 |

## Test-controls map

Every surface a case in this file drives appears in this map, or in the Harness's **Named
defaults** table. A case that drives a surface named in neither is asserting through a seam nobody
declared, and this map is what makes "declare every exercised seam input" checkable.

| Surface | Controlled input | Observable result | Rows |
|---|---|---|---|
| link manager | The destination an owner submits, the off/on switch an owner operates on a short code, and the instant of a resubmission as the Named defaults table's Clock holds it | The copy state and variant the link manager renders, the short code it shows, and whether the generator's next value stays unallocated | R1.1, R1.2, R1.5, R2.2 |
| redirect request | The short code requested, at the instant the Named defaults table's Clock holds | The response status line and its Location header | R1.3, R1.4 |
