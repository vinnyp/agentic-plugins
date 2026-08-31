# The durable review log

Every peer-review round leaves an auditable record. This file defines WHERE it lives, WHAT shape it
takes, and the GUARD on writing it. It does not restate which reviewers fire — that is
[peer-review-tiers.md](peer-review-tiers.md).

## Where the log lives — the reviewed repo

A peer-review log is a **first-class artifact of the reviewed repo**, not a planning doc belonging to
whatever hub the tooling came from. It must be auditable in that repo's own PR and git history —
that is the whole point: the record of what was reviewed, what was found, and what was done about it
travels with the diff it reviews.

Write it to the caller repo's `docs/agent-reviews/YYYY-MM-DD-<topic>-peer-reviews.md`. This skill
and its `review-gate log-new` helper are merely the *tool* that produces it — a globally installed
compiler writing into your project. "Leave no footprint in someone else's repo" does not mean "skip
the log"; it means the log belongs to the reviewed repo.

## Shape

A log contains:

- **Header** — the subject (the diff SHA range, or the spec path), the reviewers run **plus the
  resolved persona version** (so any skew between the same-model and different-model routes is
  visible), the date, the mode (`design` or `build`), the gate outcome, and a named
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

`review-gate log-new --topic <slug> --mode <design|build> --persona <X>… [--stdout] [--force]`
scaffolds exactly this. `--stdout` emits to stdout instead of writing in place; `--force`
overwrites.

**Shape stability.** The disposition-table columns (`# | finding | raised-by | verify | disposition`)
are the **stable contract** — any log parser keys off them. Adding a header field is additive and
non-breaking; renaming or removing a disposition column is a **breaking** change to the log shape
and to the scaffold that emits it.

## The guard (load-bearing)

- **Git repos only.** `log-new` refuses to write outside a git repository — the log must be
  version-controlled alongside the change it reviews.
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

## When a log is required, and where it is committed

A change **requires a log if and only if it triggered the gate** — that is, the gate ran at least one
reviewer on it. *What* triggers the gate (Tier 1 on every code build, Tier 2 and 3 by trigger) is
defined in [peer-review-tiers.md](peer-review-tiers.md) and is deliberately not restated or carved
out here: if the gate ran, a log is required; if it did not, none is. There is deliberately no
"purely mechanical change" exception, which would contradict the gate's own Tier-1 ALWAYS rule.

When required, the log is committed **alongside** the change it reviews — same branch, same PR — so
the diff and its audit trail are never separated. A review that lives only in a chat transcript or
in `/tmp` is not a record. The briefs are reproducible from the persona plus the spec or diff, but
the **outputs and dispositions must be preserved** in the repo.
