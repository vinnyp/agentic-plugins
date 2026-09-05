# The tiered peer-review gate — which reviewers fire, and when

This is the **normative source for reviewer selection**. `SKILL.md` runs the gate; this file
decides *who* reviews. The `review-gate` CLI is persona-agnostic and never decides for you.

The rule: after any code build — your own, or a dispatched one — run a tiered peer-review gate
before commit/merge. A few lenses are ALWAYS required; security and privacy are required when
their surface is touched; the specialist lenses are your call by change-shape. A parallel **spec
gate** runs cheap checks *before* the build, so an expensive review round is not spent on a design
that cannot actually be built.

The reviewers are the `peer-*-reviewer` personas shipped by the `peer-reviewer-agents` plugin
(marketplace `agentic-plugins`). Doers and reviewers are deliberately separate: an operator agent
(`devops-engineer`) does the work, its paired `peer-devops-reviewer` only reviews it.

---

## Tier 1 — Baseline (ALWAYS in `build` mode, no discretion)

This tier is **`build`-mode only** — it reviews a diff and its green suite. On every code build,
before commit/merge:

- **`peer-code-reviewer`** — correctness against the real contracts the change integrates with;
  seam bugs.
- **`peer-test-reviewer`** — does the green suite actually **prove** the behavior (false-greens,
  mutation check, coverage)? "Has tests" is not "is tested". Test review is baseline *because* a
  redaction layer has shipped non-functional twice behind a passing suite.

Both are written in diff-and-green-suite terms and do not fit a `design`-mode spec review, which has
no diff to check. **In `design` mode the baseline is the spec-gate checks below** (substrate
verification, instrument validity, the recorded pre-build round) **plus
`peer-staff-software-engineer-reviewer` as the primary lens on any technical spec or implementation
plan** (end-to-end soundness: the WHAT is executable, the HOW fits the existing system, the plan
builds the spec with complete workstreams), with **whatever Tier-3 lenses the spec warrants stacked
on top** — the product lenses for a user-facing one, and `peer-architecture-reviewer` when the spec
is **structural**: it adds a process/service boundary, changes data ownership or a consistency
model,
or claims a property like "scales horizontally" — not by default, or the two lenses file the same
finding twice. Pass the staff lens both documents: `--spec <artifact> --source <upstream>` (the PRD
for a spec, the spec for a plan) and the claimed properties in `--what`; without the upstream it
marks its verdict partial. Tier 2 triggers still apply in either mode where their surface is
touched.

Resolve every **Blocker** before proceeding; **Majors** before merge. The gate's checks must pass
on a clean runner with pinned tools, not just on the author's machine.

## Tier 2 — Conditional-required (by trigger, no discretion)

Mandatory when the trigger fires; skipped only when genuinely N/A.

- **`peer-security-reviewer`** — REQUIRED if the change touches auth, secrets, gating, infra
  mutation, or external input, **or** if the tool is publish-posture — i.e. it is, or is about to
  be, published to a public registry, marketplace, or repo where a stranger runs it.
- **`peer-privacy-reviewer`** — REQUIRED if the change touches PII, personal data, data sent to a
  third party, or logs that could carry it.
- **`peer-database-reviewer`** — REQUIRED at a **release door for a store-backed CLI** — a release
  door being the moment a change is cut for release: a version tag, a merge to a release branch, or
  a registry publish (schema + full-text index + triggers + migrations by construction). The highest-severity bugs at that door
  have been database-shaped and were caught only by the DB lens; code and test review missed them.
  For non-release changes it stays a Tier-3 discretionary lens (below).
- **`peer-apps-script-reviewer`** — REQUIRED when the diff touches any file in a directory tree
  rooted at a `.clasp.json` or an `appsscript.json`, or any `.gs` file anywhere. A `.js`/`.ts` file
  is in scope only under such a root. This trigger is a **file test** — decide it by that test and
  do not apply the "if unsure, it fires" rule to it. In `build` mode it runs **alongside** the
  Tier-1 `peer-code-reviewer`, never instead of it; in `design` mode (an Apps Script spec, with no
  diff) it runs on the spec on its own. The code lens owns correctness; this lens owns the platform
  contract the code runs inside: execution identity and deployment posture (an *execute as me* web
  app opened to `ANYONE` or `ANYONE_ANONYMOUS` is an open proxy into the owner's account),
  simple-vs-installable trigger semantics and whose authority a trigger wields, the execution walls
  (6 minutes; 30 seconds for custom functions and Workspace add-ons) and the per-day quota budget,
  unbatched per-cell service calls in a loop, OAuth-scope breadth in the manifest, and Workspace
  sharing blast radius. On a co-dispatched review, **OAuth-scope breadth and manifest hygiene are
  the Apps Script lens's call — dedupe toward it** rather than filing the same finding twice. An
  Apps Script **web app**, or any change touching its authorization, also fires
  `peer-security-reviewer` (external input + publish posture); this lens hands the exploit model to
  it. Pass it the manifest path via `--source`, and the deployment shape (who executes it and under
  whose authority), the trigger inventory, and the real data volumes in `--what` — they are not
  paths, and the lens will report them as unverified rather than guess. Requires
  `peer-reviewer-agents` >= 1.2.0; if the persona does not resolve in your installed plugin,
  upgrade it or run the platform checklist yourself against the manifest and say so in the log —
  do not record the trigger as N/A.
- **`peer-plan-reviewer`** — REQUIRED when a plan will be executed **unattended or by a remote
  coding agent**. Runs on the plan doc BEFORE any build step begins — unlike the other Tier-2
  entries, this one fires PRE-BUILD. Pass it the plan path plus the spec path. It catches spec→plan
  gaps, sequencing errors, oversized tasks (no single verifiable outcome and no test step), missing
  test steps, and placeholder violations — all cheaper to fix before dispatch than after. Not
  required for attended execution where a human steps through the tasks. It runs alongside
  `peer-staff-software-engineer-reviewer`, which owns whether the plan is the right way to build
  the spec; this lens owns the unattended-execution mechanics.
- **A measurement-methodology lens** — REQUIRED when the change is **measurement-shaped**: it adds
  or changes a gate, threshold, metric, scorecard, eval, or verdict (anything that decides pass/fail
  or quantifies quality). The question is whether the thing actually measures its claim, and whether
  "pass" means "evaluated and passed" or merely "didn't look" — the false-green / measurement-floor
  trap. This is distinct from the Tier-1 `peer-test-reviewer`, which asks whether a suite proves
  *code* behavior; this lens asks whether a metric or verdict measures the *quality* it claims. No
  such persona ships in `peer-reviewer-agents`; use one from another plugin if you have it installed,
  otherwise run the lens yourself against the checklist below and say so in the log.

  **Measurement-methodology checklist** (the substance of this lens when you run it by hand):

  1. **Construct validity — the metric matches the claim.** The number measures the quality it is
     named for (recall@k measures recall, a "pass rate" measures the behavior, not merely that the
     harness ran). Read the formula, not the label.
  2. **"Pass" means evaluated-and-passed, not didn't-look.** Trace one passing case to the assertion
     that made it pass. A gate that returns green when its subject is absent, empty, or unreachable
     is a false green — the measurement-floor trap. Confirm a should-fail input actually fails.
  3. **The corpus/arms can distinguish good from bad.** A golden set or A/B that scores high (or
     equal) regardless of the system is hiding quality, not measuring it. There must be an input the
     metric would score badly.
  4. **The comparison is fair.** Same inputs, same conditions across arms; the only thing that varies
     is what is under test. No leakage between the thing measured and the thing measuring it.
  5. **The sample supports the conclusion.** Enough cases (and, for a stochastic system, enough
     repetitions) that the reported difference is not noise; no cherry-picked N, no multiple-
     comparisons fishing reported as one clean result.

  The **Instrument validity** section below (§"verify before anchoring a decision to an eval
  result") is the same lens applied to the narrower case of a spec that cites an eval number as
  evidence; items 1–3 there are the sharp edge of this checklist.

If you are unsure whether a trigger fires, **it fires.**

## Tier 3 — Discretionary (your call by change-shape)

Add when the change warrants it; stack them for a high-stakes gate.

- **`peer-architecture-reviewer`** — a design/spec or structural change, **before** build.
- **`peer-staff-software-engineer-reviewer`** — a PRD / requirements doc before engineering
  commits to it (is the WHAT executable — unambiguous, complete enough to define the HOW,
  feasible, non-functionals stated). On a spec or plan it is not discretionary — see the
  design-mode baseline above.
- **`peer-performance-reviewer`** — a hot path, scaling, or data-volume change.
- **`peer-interface-reviewer`** — a CLI/API contract, output-shape, or breaking change.
- **`peer-reliability-reviewer`** — a long-lived service, deploy, or failure-handling change.
- **`peer-database-reviewer`** — a schema, migration, or non-trivial SQL change (especially
  SQLite). Query *speed* stays with performance; data *ownership* with architecture.
- **`peer-devops-reviewer`** — hosting/DNS/registrar, access model, edge config, or service estate;
  standing up or changing a live site. App-runtime resilience stays with reliability; the
  exploit/threat model with security.
- **`peer-release-reviewer`** — a release or publish: risk and rollback readiness, severity/triage
  correctness, release-notes accuracy against the diff, comms, process adherence, go/no-go, semver.
- **`peer-product-manager-reviewer`** — requirements/PRD/spec, a user-facing journey or use case, or
  README use-case and onboarding docs: is the right thing being built for a real user. Often runs at
  the spec gate before build.
- **`peer-product-marketing-manager-reviewer`** — user-facing narrative and positioning: README
  narrative, landing page, announcement, release notes, naming. Does the story make the right
  audience care, clearly and honestly.
- **`peer-standards-reviewer`** — a spec, standard, protocol, or interchange format that a second
  implementer must be able to build from unambiguously.
- **`peer-retrieval-reviewer`** — a retrieval/RAG pipeline: chunking, embedding usage, hybrid
  fusion, reranking, and whether the recall/ranking/precision diagnosis itself is correct.

State which Tier-3 lenses you ran and why (or why none applied). The **choice** is yours; it is
**recorded, not silent**.

> The canonical reviewer **set** is whatever `peer-*-reviewer.md` personas the installed plugins
> actually provide — the tooling resolves them by glob, never from a hardcoded list. Treat any
> count in prose as illustrative.

---

## Before the build — the spec gate

A pre-build review round (architecture plus the relevant lenses on a design or spec, often a
different-model pass) is **expensive**. Spend it only on a design that can actually be built. Two
cheap gates run first, and like Tier 3 they are recorded, not silent.

### Verify the load-bearing control's enforcement substrate

If a design rests its safety or correctness on a control the **platform** must enforce — a push
protection rule, a permission/IAM grant, an isolation boundary, a rate limit or quota, an auth mode
— then **before** the round:

1. **Name** the control explicitly in the spec: "the safety of X rests on control Y, enforced by
   substrate Z."
2. **Verify** Z can actually enforce Y on the **real target** — the specific repo, account, plan, or
   tier, not the product in general. Read the platform docs **and** run a live capability check. If
   it cannot, **fail fast and refit the design before spending the round.**

A ten-minute substrate check is cheaper than a multi-lens round. This once cost a full
architecture/security/privacy/reliability round on a design whose core data-protection control
turned out to be unavailable on the target account tier.

**Scoped to the trigger.** This fires *only* when safety rests on a platform-enforced control. A
design with no such control — pure local logic, a document, a self-contained CLI — needs no
substrate ceremony. Do not invent a control in order to verify one.

### Multi-artifact / new-domain specs get a recorded pre-build review

When a spec spans **multiple artifacts** (an agent plus a skill plus a CLI, say) or **founds a new
domain**, run a pre-build round — architecture at minimum, plus the relevant lenses — before the
build. Do not let one spec advance to a plan on a single authoring pass while a sibling gets a full
pre-build round; that asymmetry is exactly the "false founding assumption surfaces late" failure the
review exists to catch. The choice of lenses is yours, but **state it**: "pre-build review: ran
architecture + interface", or "skipped — single-artifact, low-stakes, because …".

### Instrument validity — verify before anchoring a decision to an eval result

When a spec cites an eval result as evidence ("the reranker is rejected because recall is already
at 0.846"), verify the instrument is sound **before** the review round:

1. **The metric definition matches the claim** — recall@k measures recall, precision measures
   precision. Confirm the formula implements what it claims.
2. **The corpus is not trivially satisfiable** — a golden set that scores high regardless of the
   system is not measuring quality, it is hiding it.
3. **Known-bad input scores badly** — run one deliberately wrong query or retrieval. If it still
   scores well, the instrument has a floor effect.

If the instrument fails any of these, treat the evidence as unsound and re-instrument before
spending a round on the dependent design. A metric bug once anchored a wrong architecture decision:
a measured 0.846 ≥ 0.80 was an artifact of the instrument, not a signal.

### Exploit-attempt briefs need an EXECUTED artifact, not a verdict

When a brief explicitly asks a reviewer to attempt an exploit — "try to defeat the guard", "try to
bypass the check" — a bare narrative verdict ("cannot be bypassed") is not evidence. Require the
**command it ran and the output it got** as part of the PASS. Treat a verdict with no attached
executed artifact as unverified, not as a pass, and re-run it before acting on it. A reviewer that
concludes "not bypassable" without showing the attempt is a decoration, not a check. A
different-model review lane false-PASSed exactly this shape once; the guard was defeatable in a
single sandbox command, and a second lane found four Blockers and reproduced two independently.

---

## Runtime is pluggable

A persona is not tied to one model. Run any tier's reviewers by whichever route fits:

- **The Claude Agent tool** — dispatch the plugin-qualified persona as `subagent_type`
  (`peer-reviewer-agents:peer-code-reviewer`, and so on): same-model, in-session, lowest friction.
  The default.
- **A different-model second opinion** — `agy` or `codex` via the persona-in-brief recipe in
  [different-model-reviews.md](different-model-reviews.md). The recipe is runtime-agnostic, so
  `--runtime agy` and `--runtime codex` swap freely. For a high-stakes pre-merge or pre-publish
  gate, a different-model pass **plus verify-the-reviewer** is the strongest form available.

---

## Sequencing rules (load-bearing)

**Commit before dispatching a Bash-capable reviewer.** If a reviewer has Bash access (a
`peer-test-reviewer` running mutation testing, say), commit the diff *before* dispatching it. A
Bash-capable reviewer that hand-rolls its mutation cycle with `git restore` / `git checkout` /
`git stash` will, if the diff is uncommitted, silently revert in-flight changes — producing data
loss and vacuous tests the reviewer then marks green. This is the **commit-then-review** rule.

**Invoke `mutation-verify.sh`; never hand-roll a restore.** The same risk applies to the
orchestrator's own mutation probes. A `git checkout -- <file>` after a mutation always restores to
HEAD — if the reviewed diff is uncommitted, that silently discards the work and can yield a false
"mutation-proof" pass, because the test stays green against the already-buggy committed baseline.
The prose-only version of this rule ("commit first, or copy aside") failed three separate times
before a structural replacement shipped: **`mutation-verify.sh`**, in this plugin's `bin/`.

```
mutation-verify.sh --file <path> --test-cmd <cmd> (--mutate-sed <expr> | --mutate-cmd <cmd>)
```

It snapshots the target file by **copy** into a temp dir outside the repo, mutates, runs the test,
restores from the copy, and verifies byte-identity — immune to commit state, and it **never invokes
git**. Exit codes: `0` mutation caught (the test genuinely isolates), `1` mutation not caught
(false-green test), `2` harness error (bad args, a no-op mutation, a failed restore, or an invalid
baseline). Use it for every mutation-verify pass, orchestrator or reviewer alike.

**Concurrent mutation-DOING reviewers — isolate them, or make them read-only.** When you dispatch
two or more reviewers that themselves RUN mutations (mutate a file → run the test → restore), do
not point them at one shared worktree: they edit the same files in parallel, leave the tree dirty,
restore each other's mutations, and cross-flag one another's in-flight edits. Either give each
mutating reviewer its own isolated worktree, **or** instruct read-only diff review and run the
mutation-verify yourself, serialized. Never share one worktree across concurrent mutators.

**Grep-evasion is an auto-Blocker.** A spec's acceptance criteria must never be satisfiable by a
textual stand-in for the behavioral requirement. When a criterion is expressed as a text or pattern
check (a `grep`, a string match, a regex), the reviewer's job is not to confirm the check as
literally written — it is to ask **what behavior the check stands for** and verify that behavior
directly. An implementation that satisfies the letter of the criterion while defeating its intent
(splitting a string across two variables so a `grep` for the whole string no longer matches, while
the forbidden behavior still occurs) is a **Blocker**, full stop. Never accept it as clever.

---

## Where this fits

**Before the build (spec gate):** name and verify the load-bearing control's substrate (fail fast
if unenforceable) → for a multi-artifact or new-domain spec, a recorded pre-build round → if the
decision rests on eval evidence, verify instrument soundness → refit, or proceed to plan/build.

**After the build:** the build → **verify-the-coder** (a separate upstream discipline — diffing the
coding agent's output against the prompt for scope creep or dependency substitution — **out of scope
for this skill**; named here only to place the gate in the pipeline) → **commit the diff** → **this
gate** (Tier 1 always, Tier 2 by trigger,
Tier 3 by judgment) → **verify-the-reviewer** (check every finding against real code; correct the
severities) → resolve Blockers/Criticals and Majors/Highs (multi-file fixes are dispatched, not
hand-edited) → one clean commit → the durable review log
([review-log-convention.md](review-log-convention.md)).
