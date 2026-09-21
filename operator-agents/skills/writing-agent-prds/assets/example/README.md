# Worked example: a locked agent-format PRD

One complete instance of the `agent-prd v1` format — a link shortener, chosen because it needs no
domain knowledge to read and belongs to no real project. It is **deliberately tiny**: one surface,
eight requirement rows across two sections, three copy states, one journey, four transition
routes, three fences, two open questions and one constant. A real PRD is larger; nothing here
argues that a real one should be this small.

It is a **conformance fixture**. The templates in `../` say what to write and
`../../references/mechanical-checks.md` says what is checked; where the two seem to disagree, this
instance is what the format actually means. Every structure a check parses appears here at least
once: all three ID families, the row-transitions table, the constants-and-closure-gates table,
both Legend dependency bullets (R2.3 with no interim, R1.1 with one), exactly one priority
semantic, a copy state carrying both a variant and a phase mark, the transition index, the Named
defaults table, the test-controls map, a fence with a real Authority and a bare-ID `Carried by`,
the fence → row map, and one rejected finding. No scaffold parameter, no authoring prompt and no
guidance comment survives anywhere in the five files — a locked document carries none of the
three, and the checks enforce exactly that.

Two things here are **illustrative, not real**. The fences' `Authority` lines name the example
owner and cite no decision record, because no review produced them; a real fence cites the owner's
decision by link. And the Edge Delivery PRD, `docs/product/vision.md` and
`docs/product/strategy.md` do not exist — they show the seam and upstream grammar only. The metric
targets are marked illustrative for the same reason: this example has no measured baseline, no
benchmark and no user research behind it.

The five files, as they would sit in `docs/product/`:

- [the PRD](./link-shortener.md)
- [acceptance scenarios](./link-shortener-journeys.md)
- [copy](./link-shortener-copy.md)
- [decisions](./link-shortener-fences.md)
- [open-question results](./link-shortener-oq-results.md)
