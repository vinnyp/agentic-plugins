# Copy: Link Shortener

Copy owns displayed text. Every string this product area renders is written once below, under the
`E<n>` that owns it; `docs/product/link-shortener.md` indexes these states, the surface each
appears in and the rows that cause them, and every action a row or an acceptance case names is
quoted from here character for character.

## Entry grammar

One `### E<n> — <state>` section per copy state, in the PRD copy index's order. Those headings are
stable anchors — the PRD, the acceptance cases and the fences cite them — so a state is never
renumbered or retitled once cited, and a retired state keeps its number rather than freeing it.

Each state's `Headline:` and `Body:` render as written, the `Body:` being what renders when no
variant applies; its `Actions:` are the action labels the state offers, in render order; each
`Variant:` line gives the name of one variant, the condition it renders under, and the body it
renders instead. `Variants enumerated by:` names the requirement row that enumerates this state's
variant set. A label in double quotes renders without those quote marks — they mark it as a label
rather than prose — and a variant is identified by its quoted name, never by its wording.

**Render tokens are not placeholders.** A token the product substitutes at render time — a count, a
⟨code⟩ — is named in the PRD copy index's Placeholders rule, is written inside the string it
renders in, and survives lock. It never takes the form of either fill family — the doubled-brace
scaffold parameters or the underscore-parenthesis authoring prompts — so the unresolved-fill sweep
cannot confuse the two.

## Phase marks

A phase mark says that something this file describes is not present in the build yet, and which
kind of absence it is. These are the three kinds the PRD's Legend phase rule defines, written out;
there are exactly three, and no other phase mark is legal:

- `[phase: surface-absent]` — the surface this state belongs to does not exist yet.
- `[phase: action-absent]` — the surface exists, and an action it will offer is not present yet.
- `[phase: variant-absent]` — the variant is not produced yet.

A mark on the `Phase:` field applies to the whole state; a mark written after an action's closing
quote applies to that action; a mark written at the end of a `Variant:` line applies to that
variant. A state, surface or action marked here carries the same mark in the PRD, and the two are
reconciled at every lock. A builder renders a state whose action is marked `[phase: action-absent]`
without that action, and the state is complete without it.

## States

### E1 — Link created

- Status: aligned
- Phase: none
- Variants enumerated by: none
- Headline: Your short link is ready
- Body: Anyone who opens ⟨code⟩ now goes to the address you submitted.
- Actions: "Copy link"

### E2 — Destination rejected

- Status: aligned
- Phase: none
- Variants enumerated by: none
- Headline: We could not shorten that address
- Body: Short links can point only at addresses that start with http:// or https://, and only at addresses within the length we store.
- Actions: "Try again"

### E3 — Link switched off

- Status: aligned
- Phase: none
- Variants enumerated by: R1.5
- Headline: This short link is switched off
- Body: It no longer sends anyone to the address you submitted.
- Actions: none
- Variant: "owner-disabled" — the owner switched this short link off. You switched this link off; switch it back on whenever you want it working again.
- Variant: "time-expired" — the short link's expiry instant has passed. This link reached its expiry date and no longer sends anyone anywhere. [phase: variant-absent]
