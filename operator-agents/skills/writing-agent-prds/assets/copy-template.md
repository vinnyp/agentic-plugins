<!-- guidance: this is the copy companion to `PRD: {{product-area}}`. It is the third of the
     format's four homes: copy owns displayed text. Every user-facing string this product area
     renders is written here once; rows, acceptance cases and sibling documents quote it and never
     restate it, so a string never drifts between two homes.
     Two fill families are placeholders: `{{...}}`, substituted at scaffold time, and `_(prompt)_`,
     filled during authoring; an unresolved instance of EITHER is a lock-blocking defect. Every
     guidance comment in this file is deleted at lock, so a rule a BUILDER needs after lock lives
     in body text and never in a comment — the entry grammar and the phase marks below are body
     text for exactly that reason. -->

# Copy: {{product-area}}
<!-- guidance: {{product-area}} matches the PRD's title exactly, so the set reads as one document;
     the file itself is `<prd-slug>-copy.md` beside the PRD in {{product-docs-dir}}.
     {{product-docs-dir}}: the project's product-docs directory, where the PRD and its four
     companions live. -->

Copy owns displayed text. Every string this product area renders is written once below, under the
`E<n>` that owns it; `{{product-docs-dir}}/<prd-slug>.md` indexes these states, the surface each
appears in and the rows that cause them, and every action a row or an acceptance case names is
quoted from here character for character.

## Entry grammar

One `### E<n> — <state>` section per copy state, in the PRD copy index's order. Those headings are
stable anchors — the PRD, the acceptance cases and the fences cite them — so a state is never
renumbered or retitled once cited, and a retired state keeps its number rather than freeing it.

Each section is a list of fields, one field per line, each written as `- <Field>: <value>` with the
field name unemphasized, so an extraction keys on the literal `<Field>: ` prefix. The fields, in
this order:

- `Status:` — one of the six status values the PRD's Legend defines. It must equal the `Status`
  cell this `E<n>` carries in the PRD's copy index; the two are reconciled at every lock.
- `Phase:` — this state's phase mark, or `none`.
- `Variants enumerated by:` — the ID of the requirement row that enumerates this state's variant
  set, or `none` where the state has no variants. A variant set no row enumerates is untestable
  without matching on wording.
- `Headline:` — the headline as it renders.
- `Body:` — the body as it renders when no variant applies.
- `Actions:` — the action labels this state offers, in render order, each in double quotes and
  separated by commas, or `none`.
- `Variant:` — one line per variant, and none where the state has none, written
  `- Variant: "<name>" — <the condition it renders under>. <the body it renders.>`

**Quote marks carry meaning in this file.** A double-quoted string is a checkable label — an action
label, or a variant's enumerated name — and nothing else in this file is quoted. `Headline:`,
`Body:` and the condition and body text on a `Variant:` line are prose and carry no quote marks, so
a search for a label cannot collide with the prose around it. A variant is asserted on by its
quoted name, never by its wording.

**Render tokens are not placeholders.** A token the product substitutes at render time — a count, a
⟨code⟩ — is named in the PRD copy index's Placeholders rule, is written inside the string it
renders in, and survives lock. It never takes the form of either fill family — the doubled-brace
scaffold parameters or the underscore-parenthesis authoring prompts — so the unresolved-fill sweep
cannot confuse the two. Those two families are written out in this template's head comment, which
is deleted at lock; this sentence names them without reproducing them, because a locked document
that spelled either one would fail that sweep on the line explaining it.

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
<!-- guidance: one section per copy state, `### E<n> — <state>`, numbered per PRD. Every state here
     appears in the PRD's copy index, under exactly one surface unless the PRD's Surfaces preamble
     declares it shared, and has at least one acceptance case in the journeys companion. A state no
     requirement row causes is a latent decision, not copy: raise it as an open question rather
     than writing text for it. Copy honesty (process rule 5): a string promises only what a row
     delivers. Not conditional — a product area with no user-facing surface deletes the sections
     and says "none" here, rather than leaving the file empty. -->

### E1 — _(state)_

- Status: _(one of the six status values.)_
- Phase: _(a phase mark, or `none`.)_
- Variants enumerated by: _(the requirement row that enumerates this state's variants, or `none`.)_
- Headline: _(the headline as it renders.)_
- Body: _(the body as it renders when no variant applies.)_
- Actions: _(each label in double quotes, comma-separated, in render order — or `none`.)_
- Variant: _("<name>" — the condition it renders under. The body it renders.)_
