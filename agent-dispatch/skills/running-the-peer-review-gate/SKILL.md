---
name: running-the-peer-review-gate
description: Use after any code build or before committing a non-trivial change/spec to run the tiered peer-review gate consistently across any project — assemble per-persona briefs, dispatch Claude Agent-tool reviewers (and optionally a different-model agy/codex pass), verify-the-reviewer, and keep a review log (a working record — verify where it landed with `review-log-status`) with a disposition table in the caller repo. Use in BUILD mode for a diff (post-build, pre-merge) or DESIGN mode for a spec/design doc (pre-build, the spec gate), or REQUIREMENTS mode for a PRD/requirements doc — one round per invocation; the multi-round PRD loop belongs to the caller — operator-agents:writing-prds, or operator-agents:writing-agent-prds for an agent-audience PRD. Trigger phrases - "run the peer-review gate", "peer-review this build", "review gate", "get peer reviewers on this", "spec gate", "requirements gate", "review this diff before merge", "gate this change".
---

# running-the-peer-review-gate

Runs a **tiered peer-review gate** over a diff or a spec: pick the lenses the change warrants,
brief each one identically, dispatch them, check every finding against the real code, and leave a
review log (a working record — verify where it landed with `review-log-status`).

The mechanical parts — brief assembly, the different-model run, the log scaffold with its
disposition table — are handled by the `review-gate` helper CLI. The **judgment** — which tiers
fire, verify-the-reviewer, commit-then-review — stays here.

This skill writes the review log into the reviewed repo's `docs/agent-reviews/` as a working
record. Some repos ignore that directory; verify its state before claiming it is in a PR. See
[references/review-log-convention.md](references/review-log-convention.md).

**The single source of *who* reviews is the tier reference, not this file.**
[references/peer-review-tiers.md](references/peer-review-tiers.md) defines the tiers (Tier 1 always;
Tier 2 by trigger; Tier 3 by change-shape) and the measurement-lens trigger. This skill points to it
— it does not restate the tier rules. The `review-gate` CLI is persona-agnostic and never decides
who reviews.

## Setup

Build the helper CLI (build-from-source, hash-keyed — needs a Go toolchain; see the plugin README):

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/ensure-review-gate.sh" \
  || echo "review-gate unavailable — install a Go toolchain, then reinstall or re-run the plugin's doctor"
RG="${CLAUDE_PLUGIN_ROOT}/.bin/review-gate"
```

`review-gate` resolves persona bodies from the **installed** `peer-reviewer-agents` plugin
(marketplace `agentic-plugins`) — the same source the Claude Agent tool loads — and stamps the
resolved persona version into every brief and log header, so any skew is visible.

## The phases (judgment flow)

### 1. Resolve mode + target

- **`build`** (post-build, pre-merge): reviews a **diff** — a `--range <base..head>`, and/or paths.
- **`design`** (pre-build, the spec gate): reviews a **spec/design doc** — a `--spec <path>`.
- **`requirements`** (the PRD gate, one round per invocation): reviews a **requirements/PRD
  document** — a `--spec <path>` (pass the OQ results file as a second `--spec` when it exists).
  Persona set: the PRD tier in the tier reference. The multi-round loop (fences, owner
  adjudication, fix passes, delta verification, lock) belongs to the caller —
  `operator-agents:writing-prds`, or `operator-agents:writing-agent-prds` for an agent-audience
  PRD; this skill runs exactly one round: brief → dispatch → verify → log. Before running
  phases 6–7 in this mode, read **Requirements-mode specifics** below.

The mode sets the brief preamble and which input is expected: `design` and `requirements` require
`--spec`, `build` requires `--range`.

### 2. Select personas per the tier reference — and RECORD the choice

Read [references/peer-review-tiers.md](references/peer-review-tiers.md) and select:

- **Tier 1 — always in `build` mode:** `peer-code-reviewer` + `peer-test-reviewer` (no discretion).
  These review a diff and its green suite, so they apply in `build` mode only — see the
  requirements-mode PRD tier for the retargeted exception. **In `design` mode
  the baseline is instead the spec-gate checks plus `peer-staff-software-engineer-reviewer` on the
  spec or plan** (end-to-end soundness — no discretion), with the Tier-3 lenses the spec warrants
  stacked on top (architecture for a structural design) — there is no diff for the Tier-1 pair to review.
- **Tier 2 — by trigger:** security / privacy / database (at a release door) / plan (unattended) /
  Apps Script (alongside `peer-code-reviewer`) —
  and the **measurement-lens trigger**: a measurement-shaped change (a new or changed gate,
  threshold, metric, or verdict) pulls in a measurement-methodology lens. If you are unsure whether
  a trigger fires, **it fires.**
- **Tier 3 — by change-shape:** architecture / performance / interface / reliability / devops /
  release / standards / retrieval / the product lenses, per the reference.

**State which Tier-2 and Tier-3 lenses ran and why (or why none applied).** The choice is yours, but
it is **recorded, not silent** — it goes in the log header (Phase 7).

### 3. Build briefs

One brief per persona. For the Claude route, omit the persona body (the subagent auto-loads it);
for the different-model route, include it:

```bash
# Claude Agent-tool route (default) — persona body omitted:
"$RG" brief --persona peer-code-reviewer --mode build --for claude \
  --range "$RANGE" --source path/to/contract.go --what "<what the change should do>" > /tmp/brief-code.md

# Different-model route — persona body prepended:
"$RG" brief --persona peer-code-reviewer --mode build --for cross-model \
  --range "$RANGE" --source path/to/contract.go --what "..." > /tmp/brief-code-xm.md
```

For `design` mode, pass `--spec <path>` instead of `--range`. The closing (the "return exactly this
structure" instruction plus the file:line clause) comes from the shared template — do not hand-write
it.

**Context that is not a path goes in `--what`.** Some lenses need runtime facts no file in the repo
carries — the clearest case is `peer-apps-script-reviewer`, whose highest-value check is the web-app
deployment posture (`executeAs` x `access`), which for an editor-deployed web app is deployment-time
state absent from `appsscript.json`. Pass the manifest as a `--source` and put the rest in `--what`:

```bash
"$RG" brief --persona peer-apps-script-reviewer --mode build --for claude \
  --range "$RANGE" --source appsscript.json \
  --what "<what the change should do>. Deployment: web app, executeAs=USER_DEPLOYING, access=ANYONE; 2 installable triggers installed by the sheet owner; ~40k rows/run"
```

This is a documented workaround, not a designed slot — `review-gate brief` has no `--context` flag
yet. A lens not given these facts must report them unverified rather than infer them.

**Every brief carries the dispatch preamble.** Before dispatching, concatenate the block from
[../../docs/dispatch-preamble.md](../../docs/dispatch-preamble.md) onto the top of each brief file —
both routes, every persona. It is concatenated, not cited: a reviewer who is only pointed at a rule
is the shape that left two correct rules unreachable.

```bash
PRE="${CLAUDE_PLUGIN_ROOT}/docs/dispatch-preamble.md"
DIRTY="$(git status --porcelain | sed 's/^...//' | sed 's/^/`/; s/$/`/' | paste -sd ' ' -)"
[ -n "$DIRTY" ] || DIRTY='none'
for b in /tmp/brief-*.md; do
  { sed -n '/<!-- PREAMBLE:START -->/,/<!-- PREAMBLE:END -->/p' "$PRE" | sed '1d;$d' \
      | sed "s|{{DIRTY_PATHS}}|$DIRTY|"; echo; cat "$b"; } > "$b.tmp" && mv "$b.tmp" "$b"
done
```

Run it against the tree the reviewers will read — a worktree's dirty paths, not your cwd's — and
check no brief still contains the literal `{{DIRTY_PATHS}}`. The four clauses are:

- **Never touch a file you did not create.** `rm`, `git checkout`, `git restore`, `git reset`, `git clean` and `git stash` are forbidden against any path outside your task's declared files. Treat unknown files as foreign and leave them. This binds every dispatched agent — a coding worker, a reviewer, a research or archival subagent, any runtime — not only a `coding-dispatch.sh` run.
- **These paths are already dirty and are not yours:** {{DIRTY_PATHS}}. Reverting or deleting one of them is the failure this rule exists to prevent.
- **You do not run the long gate.** Run every command in the foreground and let it finish. A subagent cannot receive a completion notification, so a backgrounded command hangs forever with nothing to wake it; if you catch yourself writing "I'll wait for the notification", that IS the violation. Never kill or signal a process you did not start.
- **Scratch repos fail closed.** Create a throwaway repo only under an absolute `mktemp -d "${TMPDIR:-/tmp}/<name>.XXXXXX"`, in a script running `set -eu`, and abort if the path is empty. Every `git config`, `checkout`, `branch`, `merge`, `commit` or `push` in it carries `-C <that path>`. Pass an identity per command (`-c user.name=… -c user.email=…`, or `GIT_AUTHOR_*`/`GIT_COMMITTER_*` env), never with `git config`, and never `--global`. `git -C ""` silently runs in the current directory, and in a linked worktree `git config` rewrites the shared repository's config.

The third clause matters most here: a reviewer given Bash will otherwise background the suite it was
asked to run and then wait for a notification that has no channel to arrive on.

**Never hand-roll a brief out of pasted excerpts.** `review-gate brief` emits PATHS (`--spec`,
`--range`, `--source`) plus a `repo root:` line, and tells the reviewer to open them. That is the
point: an excerpt-briefed review is a consistency check on the brief, not a correctness gate on the
code, and does **not** count as a lens having run. Measured — four different-model rounds briefed
with the author's own excerpts found zero of the two Blockers a single path-briefed round found, and
a brief truncated above a table definition produced a wrong finding that had to be rejected. If the
target is uncommitted, commit it (or write it to a real path under the repo root) and pass the path.
Pass `--repo-root <dir>` when the review runs against a worktree other than your cwd — `agy` does
not load worktrees, so a bare relative path can silently resolve against the wrong tree.

**Standing rule — the author of a fix must not be the last party to test it.** When one pass writes
both a fix and the tests that verify it, those tests can pass for a reason unrelated to the fix (a
guarded path that exits before ever reaching the guard), and the mutant that should catch it can
survive every subsequent pass. Whenever a `build`-mode brief covers a range where the same pass
authored both, say so **in the brief** — it is a slot, not an orchestrator's in-the-moment idea:

> Author-wrote-both overlap: the same pass authored the fix in `<file>` AND the tests in
> `<test-file>`. Treat those tests as UNPROVEN. Re-run the specific mutant that should catch a
> regression in `<file>` (via `mutation-verify.sh --expect-fail-output '<hazard failure text>'`)
> before accepting any of them as evidence.

A fix that ships with **no** new tests does not satisfy this rule by default — "nobody tested it" is
not "an independent party tested it". Call it out in the brief the same way.

**Personas outside `peer-reviewer-agents`.** The `review-gate` CLI resolves persona bodies from the
installed `peer-reviewer-agents` plugin only. For a persona owned by another plugin — a
measurement-methodology reviewer, if you have one installed — `brief --persona <name>` returns
empty, because the body lives elsewhere. Use the **Agent-tool direct-dispatch fallback**:

```bash
# Direct dispatch for personas outside peer-reviewer-agents:
# 1. Hand-author the brief (use the shared template at templates/review-brief-closing.md):
#    - the brief preamble + the range/spec context + the closing template
#    - omit the persona body (the Agent tool auto-loads the subagent)
# 2. Dispatch via the Agent tool:
#    subagent_type: <owning-plugin>:<persona-name>
#    prompt: <contents of the hand-authored brief>
```

The different-model (`cross-model`) path cannot run personas outside `peer-reviewer-agents` — they
are unavailable to `dispatch-worker`. For those lenses the **Claude Agent-tool pass is the only
pass**; say so in the tier-rationale log entry (Phase 2).

### 4. Dispatch

- **Claude Agent-tool reviewers (default, parallel):** dispatch each as
  `subagent_type` = the plugin-qualified persona name (`peer-reviewer-agents:peer-code-reviewer`,
  `peer-reviewer-agents:peer-test-reviewer`, and so on), **pasting the contents of that
  persona's `--for claude` brief file** into the prompt. Never re-summarize — the brief file is the
  shared contract that keeps both routes consistent.

  **Parallel Bash-capable reviewers must be isolated.** When dispatching multiple reviewers (say
  `peer-code-reviewer` + `peer-test-reviewer`) in parallel and either can run the test suite or
  issue file mutations, give each an **isolated clone**, or serialize the test-executing lenses.
  Concurrent bytecode recompilation and file-mutation churn from two processes in the same worktree
  produce non-deterministic test failures that surface as false code-defect findings. Use
  `review-clone.sh <repo> <abs parent>/dispatch-review-wt.<slug>` per reviewer, or run code-reviewer and test-reviewer
  sequentially. Remove it afterwards with
  `review-clone.sh --remove <abs parent> <that path>`. A linked worktree shares the
  repository's config and refs.

  Around each Claude reviewer round, run `repo-state-check snapshot <repo> <before>`
  before dispatching. Afterwards run `repo-state-check snapshot <repo> <after-snapshot>`
  and `repo-state-check compare <before> <after-snapshot>`. Treat compare exit 2 as
  rc 10: inspect and restore the named changes before committing, discard the review body
  unless every change is known concurrent work, and re-run. An unreadable after-snapshot
  also requires stopping and inspection. Exits 3/64 mean "check failed: stop and investigate",
  never clean; stop on snapshot failure too.

- **Optional different-model pass (serialized)** for independence on load-bearing lenses (code,
  security and privacy are capability-confirmed on `agy`; standards and interface for public-bound
  specs). See [references/different-model-reviews.md](references/different-model-reviews.md).

  **Egress:** this pass sends the brief — and the repo content it names — to the external model
  provider behind the runtime you choose, via `dispatch-worker`. Choose the lens and the runtime
  accordingly for a private or sensitive repo.

  **Pre-flight for a build-gate cross-model run:** verify the branch is rebased on `origin/main`
  first. A stale branch makes `cross-model` diff against unrelated upstream churn, generating false
  Blockers ("guts the framework") that are staleness artifacts, not real defects:

  ```bash
  git fetch origin
  git rebase origin/main   # or: git log --oneline origin/main..HEAD to confirm it's current
  ```

  The review clone mirrors the source's refs at dispatch time; origin's fetch and push URLs
  point at a disabled path. Other remotes and the operator's credential helper remain reachable,
  so the drift check, not the clone, detects source changes. Rebase or fetch in the source
  *before* dispatching. When in doubt, rebase first.

  ```bash
  "$RG" cross-model --runtime agy --brief /tmp/brief-code-xm.md --timeout 14m
  ```

  `cross-model` runs `dispatch-worker` serialized (never concurrent) and captures the review from
  STDOUT. It prints each brief's review (framed by a `===== review: brief N =====` header) followed
  by a run summary listing **each brief's rc**, and the process **exits with the worst rc** across
  briefs — so read the per-brief rc from the summary, not just `$?`. Each rc has a defined
  orchestrator action:

  - **10** — source repo changed during the review window: inspect and restore the named changes before committing; discard the review body unless every change is known concurrent work; re-run.
  - **9** — agy model not offered → fix the pin or pass `--model` to `review-gate cross-model`, then re-run; do NOT fall back to a Claude reviewer.
  - **5/6** — for a lens whose PRIMARY runtime is codex, auth or rate limit is **not a build failure**: fix auth/ratelimit and re-run.
  - **Runtime-unavailable evidence** = rc **124**, rc **7**, or a body of **0 bytes at rc 0, 1 or 8, or at any rc not otherwise enumerated** (read `body_bytes` from the run summary). For an agy lens, if attended and the cause is rc 7, sign in to agy and re-run on agy first. Otherwise, for an AGY lens, re-run the lens ONCE on codex: `"$RG" cross-model --runtime codex --brief <same brief>`.
    Codex egress is default DENY; explicit operator approval for this repo is required.
    Only that approval permits sending this repo's content to codex's provider. An unattended run without explicit approval goes straight to the Claude fallback and logs why. If the one-shot codex substitute returns 124, 5, 6, an empty body, or an evidence-free body (rc 8), use the Claude fallback and record it; the substitute does not get fix-auth-and-re-run handling. A primary codex lens with runtime-unavailable evidence goes straight to Claude.
  - **Content-deficient** = rc **8** with a non-empty body: use the Claude fallback. Do not retry blindly. Requirements-mode per-row ALIGN/OBJECT/ABSTAIN tables count as evidence.
  - A short (non-empty) body at an unlisted rc → Claude fallback.
  - A codex substitute is recorded as `codex (not capability-tested)` and does not count toward a capability-confirmed lens claim.
  - Record the runtime that actually produced each lens's review in the **per-lens runtime block** under Reviewers, including substitutions, original runtime, rc, and reason even when there are no Blocker/Major findings.
    A same-model Claude substitution must never be reported as a cross-model pass in the log or a PR body.

- **Fallback ownership — honor the dispatch gate and inspect the body.** The rc 2/3/9/10 rules take precedence regardless of body size: fix the invocation/tree for rc 2, environment for rc 3, model pin for rc 9, and inspect source changes for rc 10. Otherwise apply the runtime-unavailable rule before the content-deficient rule; use `body_bytes` from each brief's summary, including for unlisted exit codes. Run a Claude Agent-tool reviewer for a fallback lens. The one-shot codex substitute gets the handling above. rc 5/6 retain fix-auth/ratelimit-and-re-run handling only for a lens whose PRIMARY runtime is codex. rc 9 retains fix-the-model-pin-and-re-run handling. rc 10 requires source-repo inspection and restoration before re-running regardless of the body. rc 3 retains fix-the-environment handling.

### 5. Verify-the-reviewer

Check **every Blocker/Major** against the real code or spec **before accepting it** — both
same-model and different-model reviewers occasionally cross-attribute or hallucinate a line. Record
each as accept / reject / correct, with the reason. A false-alarm Blocker costs more to refute than
to address; a missed real one is worse. This is judgment — the CLI never resolves a finding.

### 6. Resolve

Resolve all **Blocker/Major** findings (Minor is deferrable, but say so). Multi-file fixes are
CODING — dispatch them, don't hand-edit inline. In requirements mode, resolution belongs to the
caller's owner-adjudicated loop — stop after verify-the-reviewer and hand the findings back (see
Requirements-mode specifics).

For **`build`** mode, enforce **commit-then-review** ordering: commit the build *before* dispatching
build-reviewers. A Bash-capable reviewer's mutation cycle issues `git restore` / `git checkout`,
which silently reverts uncommitted work — see
[references/peer-review-tiers.md](references/peer-review-tiers.md) § sequencing rules. And
**re-check any cross-repo follow-up** a review calls "open" against the other repo before trusting
it.

**Every mutation cycle runs through `mutation-verify.sh` — no exceptions, and regardless of WHO runs
it.** The rule binds the orchestrator exactly as it binds a reviewer subagent: hand-rolling the
dance as `sed` plus `git restore` / `git checkout` has silently destroyed uncommitted work four
times, once with the orchestrator as the actor. This plugin's `bin/mutation-verify.sh` is
**copy-based** — it snapshots to `mktemp` and never invokes git in any form — so it is immune to
commit state and safe on a dirty tree. Do not eyeball a diff; use its applied-verification flags:

```bash
mutation-verify.sh --file <path> --test-cmd "<the gate>" --mutate-sed '<expr>' \
  --expect-anchor '<text that must be present BEFORE mutation>' \
  --expect-marker '<text that must be present AFTER mutation>' \
  --syntax-cmd "bash -n <path>" \
  --expect-fail-output '<text only the hazard assertion prints when it fails>'
# --syntax-cmd alternatives: python -m py_compile <path>, go build ./...
```

`--syntax-cmd` is the leg that matters most and the one hand-rolling always omits: a malformed
mutant produces a syntax error, the test "fails" (or "passes") for the wrong reason, and the result
is indistinguishable from a genuine verdict. **Never add a git-state check to
`mutation-verify.sh`** — being git-free is precisely what makes it safe on uncommitted work.

**A mutant proves a hazard only when the hazard assertion catches it.** A RED run caused by an
incidental change (an error message, a needle, an unrelated assertion) is not a catch.
`mutation-verify.sh` exit 3 (not the dispatch-worker rc 3 above) means the failing run lacked the
hazard's failure text; record it as a surviving mutant, not a harness error to retry. Choose the
text before the run, from the line the runner prints when the hazard assertion fails, including
the runner's own framing (pytest's `AssertionError: <message>`, Go's `<file>_test.go:<line>:
<message>`): a bare message literal is also in the test source, and pytest prints source on any
failure. The text must be unique at run time: only the hazard test can make it appear. A literal
found once by `grep -rF` is not enough inside a shared helper, a loop or a parametrized test; then
name the hazard test or its call site (pytest's `FAILED <file>::<test> - <message>` summary line;
Go helpers must call `t.Helper()`). Never use a message several assertions share, runner-wide
text alone (`FAILED`, `AssertionError`, `panicked`), the product's error text, or a test name
alone. After an exit 3, replace the text only when that output shows the hazard test itself
failing at its own call site, not a shared helper's line (the rendering was wrong); cite that
location and both runs. Otherwise the exit 3 stands as a survivor. See `docs/commands.md` for per-runner
renderings. Quote the verdict's `matched:` text in the disposition row. The check is a presence check, so it cannot split
one snapshot or diff assertion by cause. A mutant written to show that a fix
closes a hazard must reproduce that hazard's real trigger (the fail-open input itself, not a
neighbouring input the old code already refused).

**A surviving mutant is a test gap by default.** Dismissing one needs a written reason it cannot
matter (no input reaches the code, or the mutant is behaviorally equivalent), recorded in the review
log's disposition table. "Defense in depth" or "possibly harmless" is not a reason: prove it, or add
the test. (foundry#259: a survivor waved off as defense in depth was load-bearing at five call
sites, and a "caught" snapshot mutant had failed only because a message changed.)

### 7. Keep the review log (a working record — verify where it landed with `review-log-status`)

In requirements mode, log-new runs only on round 1 — later rounds append to the recorded log (see
Requirements-mode specifics).

Scaffold the log in the caller repo, then fill it:

```bash
"$RG" log-new --topic <slug> --mode build --persona peer-code-reviewer --persona peer-test-reviewer
# -> docs/agent-reviews/YYYY-MM-DD-<topic>-peer-reviews.md
#    (refuses to overwrite an existing file unless --force; refuses outside a git repo;
#     writes repo-root-relative only)
```

Fill the scaffold with each reviewer's findings, the **verify-the-reviewer disposition table**
(`# | finding | raised-by | verify | disposition`), and the recorded tier rationale from Phase 2.
After writing the log, and again after committing it, run
`review-log-status --archive <log-path>`; the CLI handles an unset archive variable. Quote the CLI's
first stdout word in the completion report. Only `committed` permits a shipped claim or repo link.
`staged` means commit it, then re-run. For `untracked`, run `git add` and re-run unless the caller
deliberately keeps the log uncommitted (for example, a design-mode draft); say so explicitly in the
report. For `ignored`, use the archive or local-only PR wording in the convention. Correct `missing`
or usage errors before completion. A clean `git status` or successful `git add` does not prove the
log was included.

**PII redaction is a hard precondition.** Record the *finding*, not the raw personal data — if a
review quotes real personal data (a privacy review citing real names, say), redact it in the log.
On a **public-bound** repo this is load-bearing: **the author** refuses to write a finding that
would carry personal data into a repo headed for publication — authoring judgment, not a tool
guarantee. `log-new` only scaffolds an empty file and never sees the findings, so the CLI cannot
scan or strip anything. See
[references/review-log-convention.md](references/review-log-convention.md) for the guard and
[references/peer-review-tiers.md](references/peer-review-tiers.md) for the gate — this skill points
to them, it does not restate them.

## Requirements-mode specifics (one round)

- **Brief inputs.** The CLI emits the requirements preamble INCLUDING the per-row
  disposition return contract (ALIGN / OBJECT (finding-id) / ABSTAIN over the document's row IDs
  (Req-IDs, and any E-/M-family rows §2 defines)).
  `--what` carries only the lens's retargeting line (tier reference). The caller's cumulative
  fence file and the prior round's log are passed by PATH as `--source` entries — never inlined
  (paths are fail-closed validated; a missing fence file kills the brief instead of silently
  producing a fence-free round).
- **Flip rule.** A row is flip-eligible only when every non-abstaining lens ALIGNs and at least
  one lens opined. Owner-locked rows are listed in the brief as out of scope; a reviewer may flag
  one only if a later edit changed it.
- **Non-conforming reviewer.** A lens that returns no per-row and no per-finding verdicts has not
  run — re-dispatch it; never interpret prose as a verdict. The body is the trigger, not the exit
  code.
- **Verify-the-reviewer applies unchanged**, including to per-row OBJECTs.
- **Log.** `log-new` runs exactly ONCE per PRD, at round 1; the caller records the created path
  and every later round APPENDS a `## Round N` section to it (see the multi-round subsection of
  the review-log convention). Re-running `log-new` for the same PRD is the defect — a second file
  splits the fresh-lens ledger.
- **Runtime.** The Claude route is the default; a cross-model pass is opt-in (callers decide
  cadence — `writing-prds` and `writing-agent-prds` each offer it once, on their first full round).

## Gate

Resolve every **Blocker/Critical** before proceeding and every **Major/High** before merge;
Minor/Low can be resolved or explicitly deferred. "The build passes" is **not** a substitute — a
green suite has shipped a non-functional layer behind it, which is why the Tier-1 test lens exists.

Completion checklist: run `review-log-status --archive <log-path>`, quote its first stdout word,
and use the matching PR-body wording from the review-log convention.

## Out of scope (deliberate)

- **Tier selection is not automated** — it stays in
  [references/peer-review-tiers.md](references/peer-review-tiers.md) plus the judgment above.
- **Findings are never auto-applied** — verify-the-reviewer is judgment; the CLI never resolves.
- **The agy/codex invocation is not re-implemented** — `cross-model` only orchestrates
  `dispatch-worker`, captures STDOUT, and passes the rc through.

## References

- [references/peer-review-tiers.md](references/peer-review-tiers.md) — which reviewers fire, when,
  the spec gate, and the sequencing rules.
- [references/different-model-reviews.md](references/different-model-reviews.md) — running a persona
  on `agy` or `codex`, and the file:line clause.
- [references/review-log-convention.md](references/review-log-convention.md) — where the log lives,
  its shape, and its guard.
- CLI source: `tools/review-gate/`, built by `bin/ensure-review-gate.sh`. The shared closing
  template lives at `templates/review-brief-closing.md`.
