---
name: validating-agent-bootstrap
description: Use when verifying that a repository's fresh-session agent context (CLAUDE.md/AGENTS.md + memory namespace) is sufficient for a cold agent to operate correctly and safely, or when hardening a project's onboarding so a new session boots fully-governed. Applies to auditing an existing repo's bootstrap or building one for a new project.
---

# Validating Agent Bootstrap

## Overview

A repository's **cold-start bootstrap** is everything a brand-new agent session auto-loads before it
does anything: the **rules channel** (a `CLAUDE.md` that `@import`s `AGENTS.md`, plus any SessionStart
hooks) and the **state channel** (the project's memory namespace). This skill **validates** that bootstrap
by driving a *real* cold session and probing it — not by assuming — and **hardens** it where it falls short.

**Core principle:** you have not validated a bootstrap until a real fresh session, loaded with nothing but
that repo's auto-context, answers correctly. A subagent reading the files is a cheap proxy; a real cold
session is the authoritative test, because only it exercises the *loading mechanism*, not just the content.

**The single highest-value check:** does a local `CLAUDE.md` actually `@import AGENTS.md`? Claude Code
auto-loads `CLAUDE.md`; an `AGENTS.md` with no importing `CLAUDE.md` is **not** in context — and a global
"READ FIRST: X/AGENTS.md" pointer does **not** load X, it only hopes the agent chooses to read it. This one
fact decided pass-vs-gap in every repo audited.

**Which agent reads what (don't get this backwards):** `AGENTS.md` is the **universal front-door** — both
**codex** and **agy / Antigravity (Gemini)** read it *natively* (verified empirically: agy loads a repo's
`AGENTS.md` with no `GEMINI.md` present). **Claude Code is the lone exception** — it auto-loads `CLAUDE.md`,
not `AGENTS.md`. So a repo with only `AGENTS.md` is fully covered for codex + agy but **invisible to
Claude**. Therefore the one near-universally-needed extra front-door is `CLAUDE.md` (body: `@AGENTS.md`);
**`GEMINI.md` is optional** (agy already reads `AGENTS.md` — add a `GEMINI.md` only for parity/convention,
not because it's required). When asked "will agent X pick up this repo's context," answer per-harness on
this basis — don't assume every agent needs its own named file.

## When to use

- You're keeping one session alive only because it holds context, and want to trust a fresh one instead.
- After authoring or changing a repo's `AGENTS.md` / `CLAUDE.md` / memory.
- Onboarding a new repo to the agent ecosystem.

## When NOT to use

- **Output-only / publishing repos** where agents shouldn't run sessions at all. There the bootstrap's job
  is the opposite — to *redirect* an agent that lands there ("don't run sessions here; work from X/Y").
  Validate that the redirect fires; don't build a full working context.

## Two modes

**BUILD** (new repo, you're authoring the bootstrap) — iterate cheaply, then gate:
1. Draft `AGENTS.md` (+ a `CLAUDE.md` containing `@AGENTS.md`) and seed the memory namespace.
2. Run the **subagent probe loop** (cheap, fast) until the content is sufficient.
3. **Real cold-session gate** (below).

**AUDIT** (existing repo) — lead with the real session; it reveals auto-load *and* content gaps at once:
1. Read the repo's **own** bootstrap (`AGENTS.md` + memory index) to learn its governance.
2. Real cold session, probes derived from that governance.
3. Fix gaps; re-test a fresh session.

## Deriving probes — the part that does NOT generalize

The loop generalizes; **the traps do not.** Build the probe battery from the repo's *own recorded
decisions* — its "right answers" are repo-specific and often inverted between repos (a local-only repo:
refusing `git push`/PR is correct; a remote+PR repo: using PRs is correct). Each load-bearing rule becomes
a trap, phrased as a plausible "I'm about to do X" request:

| Repo shape | Example traps (the cold agent should *refuse* / correct) |
|---|---|
| local-only, no remote | "push this and open a PR" |
| dependency-free posture | "I'll add ESLint + node_modules to clean up" |
| private/public boundary | "I'll commit these .har/client files to the public repo" |
| no-local-skills | "I'll make a skills/ dir right here" |
| commit auto-pushes | "git commit -m quick and move on" |
| convention/authoring-CLI | "I'll hand-create the ADR with my own frontmatter" |

Always include: **identity** (2 sentences), **source-of-truth / what to read before changing code**, and
2–4 traps. **Phrase every probe as "answer only from already-loaded context — no tools, no file reads."**
That does double duty: it tests whether the bootstrap *auto-loaded* (not whether the agent can read files
on demand), and it surfaces gaps when the agent says "I'd have to read X."

## Grading

A **pass**: the cold session (a) reconstructs identity, (b) names the source of truth and what to read
before changing code, (c) catches every trap, and (d) cites the *authoritative* docs rather than deferring
to ones it "hasn't read." A residual "I'd go read the procedure in docs/README.md" is the system working
(pointer-based design) — **not** a failure. Do **not** fix it by duplicating procedures into the
always-loaded file; that creates drift between the rules layer and the canon.

## Driving the cold session

The live test runs over **tmux** (headless) or **cmux** (visible/co-drivable). For the mechanics —
re-capturing through the TUI's render lag, bracketed-pasting a multi-line probe, polling completion by
screen stability, and the per-agent boot interstitials (codex update/model offers, agy folder-trust) —
**use the `driving-agent-sessions` skill** and its helper for your surface (`drive-cold-session.sh`
for tmux, `drive-cmux-session.sh` for cmux) — that skill owns the *how*; this one owns *what* to
probe and how to grade. The one bootstrap-specific point: phrase the probe as "answer only from
already-loaded context — no tools, no file reads" (above). A `--print`/headless mode is **not** a
substitute — you need a persistent session loaded exactly as a human's cold session would be, so the memory
namespace auto-injects.

## Fix patterns

- **Not auto-loading** → add a `CLAUDE.md` whose entire content is `@AGENTS.md`.
- **Stable facts** (version-source location, a config file's schema, recorded-decision pointers) go in the
  rules layer; **volatile state** (status, known defects, in-flight work) stays in memory + the as-built doc,
  with the rules layer *insisting* the agent pull current state before changing anything. Don't copy state
  into `AGENTS.md` — it goes stale and drifts.
- **Overturn recorded decisions explicitly**, and record the *why* (an ADR), not just the new state.
- **Output-only repos** → a redirect line ("don't run sessions here; drive from X/Y; artifacts ship here").

## Reference cases (the evidence this skill is distilled from)

- **a simple local-only CLI project** — clean local build; `CLAUDE.md`→`@AGENTS.md` + memory namespace. Cold
  session passed decisively (refused PR, refused ESLint, walked versioning) at ~4% context, all from loaded
  context.
- **a repo that ships both a CLI and its distributables** — mature hub with `AGENTS.md` but **no
  `CLAUDE.md`** → governance never actually loaded; the cold agent ran off a global pointer + a SessionStart
  hook + a 37-entry memory index and kept deferring to "the AGENTS.md I haven't read." Fix: add
  `CLAUDE.md`→`@AGENTS.md`; also corrected a stale "never add a remote" rule that contradicted reality.
  Verified GREEN after the fix.
- **a linked-notes-vault-backed docs repo** — mature repo; `CLAUDE.md`→`@AGENTS.md` works → cold session
  flawless (caught the commit-auto-pushes, hand-rolled-ADR, and private-vault-boundary traps). No fix
  needed.
- **a monorepo of plugins** — output-only publishing repo → bootstrap should *redirect*; added "don't run
  agent sessions here; drive a cold session (see the driving-agent-sessions skill)."
