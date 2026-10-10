# The review log (a working record — verify where it landed with `review-log-status`)

Every peer-review round leaves an auditable record. This file defines WHERE it lives, WHAT shape it
takes, and the GUARD on writing it. It does not restate which reviewers fire — that is
[peer-review-tiers.md](peer-review-tiers.md).

## Where the log lives — the reviewed repo

A peer-review log is a **working record of the reviewed repo**, not a planning doc belonging to
whatever hub the tooling came from. The repo may legitimately ignore `docs/agent-reviews/`.

Create it at the caller repo's `docs/agent-reviews/YYYY-MM-DD-<topic>-peer-reviews.md`. After
writing it, and after committing it, run `review-log-status --archive <path>`.
The CLI checks the index and ignore rules directly; `git status` and `git add` alone cannot prove
where the log landed. Always pass `--archive`; the CLI handles an unset
`PEER_REVIEW_LOG_ARCHIVE`.

In the PR body, report the verified state:

- `committed`: link the repo-relative log path. The path exists in HEAD and the index and working
  tree match it. This is the only state that permits a committed or shipped claim.
- `staged`: commit the log, then re-run. The path is in the index but is absent from HEAD or has
  uncommitted changes. Do not call it shipped.
- `untracked`: run `git add` and re-run, unless the caller deliberately keeps the log uncommitted
  (for example, a design-mode draft); say so explicitly in the report.
- `ignored` with an `archived <path>` line: say the log is archived and name the archive location
  generically in a public PR, without exposing a private local path. Include the gate summary
  (rounds, reviewers, disposition counts) in the PR body. Do not claim it is in the repo.
- `ignored` without an archive: say the log is local-only. Include the gate summary (rounds,
  reviewers, disposition counts) in the PR body; do not link or claim a repo log.
- `missing`: fix the missing log before reporting completion.

## Shape

A log contains:

- **Header** — the subject (the diff SHA range, or the spec path), the reviewers run **plus the
  resolved persona version** (so any skew between the same-model and different-model routes is
  visible), the date, the mode (`design`, `build`, or `requirements`), the gate outcome, and a named
  **`tier-rationale:`** line: which Tier-2 and Tier-3 lenses ran and why, or `none — <reason>`. A
  named line keeps the rationale present-or-absent-checkable, the way the disposition columns are.
- **Per-reviewer sections** — each reviewer's raw findings.
- **The verify-the-reviewer disposition table** — the load-bearing part:

  | # | finding | raised-by | verify | disposition |
  |---|---|---|---|---|

  One row per Blocker/Major, recording what was **accepted / rejected / corrected** and **why**,
  checked against the real code or spec rather than the reviewer's say-so. A reviewer occasionally
  cross-attributes or hallucinates a line; the disposition column is where that gets caught and
  recorded.

  **Severity vocabularies.** Some personas classify Blocker/Major/Minor/Nit; the security and
  privacy lenses classify Critical/High/Medium/Low/Info. For gating and for the disposition table,
  **map Critical → Blocker and High → Major** — log every Critical and every High as its own
  disposition row, exactly as you would a Blocker or a Major. Do not let a security Critical or a
  privacy High escape the table because it was not spelled "Blocker". Medium/Low/Info findings from
  the security/privacy vocabulary are advisory: note them in the narrative or summary if useful, but
  they do not require their own disposition row and do not block merge.

`review-gate log-new --topic <slug> --mode <design|build|requirements> --persona <X>… [--stdout] [--force]`
scaffolds exactly this. `--stdout` emits to stdout instead of writing in place; `--force`
overwrites.

**Shape stability.** The disposition-table columns (`# | finding | raised-by | verify | disposition`)
are the **stable contract** — any log parser keys off them. Adding a header field is additive and
non-breaking; renaming or removing a disposition column is a **breaking** change to the log shape
and to the scaffold that emits it.

## The guard (load-bearing)

- **Git repos only.** `log-new` refuses to write outside a git repository so the working record
  belongs to the reviewed repo.
- **Repo-root-relative only.** It writes under `docs/agent-reviews/` relative to the repo root;
  never an absolute path, never `..` outside the repo.
- **Never silently overwrite.** If a dated log for the same topic exists, `log-new` refuses — a
  same-day second pass must not clobber the morning's dispositions. An explicit `--force` is
  required. Prefer a **new `<topic>` slug** over `--force` for a genuinely separate pass; `--force`
  overwrites in place and git history is the only recovery.
- **PII redaction is the agent's job when FILLING the log — not a CLI guarantee.** `log-new` only
  scaffolds an empty log; it never sees the findings, so it cannot mechanically strip anything.
  Don't claim it can. When you fill the scaffold you MUST record the *finding*, not the raw personal
  data a review quotes — a privacy review citing real names, for instance.
- **Public-bound redaction is authoring judgment.** Whether a repo is headed for publication is
  determined by that repo's own governance, not by any attribute the CLI can read, so the CLI cannot
  detect or enforce it. On a public-bound repo the **author** redacts any personal data a finding
  would carry **before commit**. Stating this as a flat CLI MUST would be an unenforceable
  precondition — exactly the substrate-enforceability trap the spec gate warns against.

## When a log is required, and where it is recorded

A change **requires a log if and only if it triggered the gate** — that is, the gate ran at least one
reviewer on it. *What* triggers the gate (Tier 1 on every code build, Tier 2 and 3 by trigger) is
defined in [peer-review-tiers.md](peer-review-tiers.md) and is deliberately not restated or carved
out here: if the gate ran, a log is required; if it did not, none is. There is deliberately no
"purely mechanical change" exception, which would contradict the gate's own Tier-1 ALWAYS rule.

When required, preserve the log in the reviewed repo's working tree. Commit it alongside the
change when the path is trackable. When ignored, archive it if configured; otherwise keep it
local-only and put the gate summary in the PR body. Never claim the log was shipped without a
`committed` result from `review-log-status`. The briefs are reproducible from the persona and target,
but the outputs and dispositions need an explicit record.

## Multi-round logs (requirements mode)

A multi-round caller creates the log once (round 1) and appends one `## Round N` section per
round. Round 1's findings and dispositions are written under `## Round 1` (the header's
`**Reviewers:**` line lists round 1's lenses; each later round restates its own list in its
section). Each round section carries: the lenses run, their per-row disposition tables, graded
findings, and the round's verify-the-reviewer dispositions. The per-round lens lists are the
fresh-lens ledger. The existing top-level shape and the finding-keyed disposition columns are
unchanged — this subsection is additive.
