# peer-reviewer-agents

`peer-reviewer-agents` is a reusable set of independent second-opinion lenses for
software work. Each reviewer has a named domain boundary, severity model, and
clear ownership of what it does and does not judge.

This plugin pairs with `operator-agents`: do the work with the relevant senior-role
operator, then review it with the matching `peer-*` lens.

## Runtime Support

All 18 lenses are defined once and run under both **Claude Code** and the
**Antigravity CLI** (`agy`) from the same frontmatter. Install for agy directly
from the plugin directory (no marketplace/registry flow exists for Antigravity
yet):

```bash
agy plugin install /path/to/peer-reviewer-agents
```

Installed agents then show up in `agy agent`. The top-level `plugin.json` is
the Antigravity manifest; `.claude-plugin/plugin.json` is the Claude one — both
point at the same agent definitions.

One difference to know about: the read-only contract is enforced differently
per runtime. Every lens declares a `disallowedTools` frontmatter field — 14
deny `Write`, `Edit`, `NotebookEdit`; the 4 local-evidence-only lenses
(`peer-code-reviewer`, `peer-database-reviewer`, `peer-plan-reviewer`,
`peer-test-reviewer`) also deny `WebSearch` and `WebFetch`. Claude Code
enforces that denylist at the tool layer. Antigravity does not enforce it —
under `agy` the read-only contract is stated in each reviewer's prompt but not
tool-blocked. `peer-test-reviewer` additionally carves out one sanctioned,
self-restoring exception to "read-only": its mutation check may temporarily
break/revert code under test via shell edits, provided the tree is restored to
its exact pre-check state before the review is returned.

## Lenses

| Lens | What it is for |
| --- | --- |
| `peer-apps-script-reviewer` | Google Apps Script and Workspace platform correctness: execution identity, triggers, quotas, scopes, and blast radius. |
| `peer-architecture-reviewer` | Architecture structure, boundaries, coupling, and design risk. |
| `peer-code-reviewer` | Code correctness, maintainability, and implementation risk. |
| `peer-database-reviewer` | Data modeling, migrations, query behavior, and storage risk. |
| `peer-devops-reviewer` | CI/CD, deployment, operations, and infrastructure review. |
| `peer-interface-reviewer` | Public contracts, API/CLI/docs interfaces, and usability of integration surfaces. |
| `peer-performance-reviewer` | Latency, throughput, cost, resource use, and scaling behavior. |
| `peer-plan-reviewer` | Plan completeness, sequencing, risk, evidence, and execution readiness. |
| `peer-privacy-reviewer` | Privacy, data minimization, retention, disclosure, and user trust. |
| `peer-product-manager-reviewer` | Product fit, requirements quality, user journeys, and success metrics. |
| `peer-product-marketing-manager-reviewer` | Positioning, audience, claims, messaging, and launch story. |
| `peer-release-reviewer` | Release-management quality, readiness, communications, and go/no-go reasoning. |
| `peer-reliability-reviewer` | Failure modes, recovery, observability, and operational resilience. |
| `peer-resume-reviewer` | Truthfulness of a candidate's claims, screener readability, evidence quality, tailoring, and applicant-tracking-system parseability. |
| `peer-retrieval-reviewer` | Retrieval/RAG domain correctness, diagnosis, chunking, embedding, fusion, reranking, and gates. |
| `peer-security-reviewer` | Security design, exploitability, secrets, auth, and abuse paths. |
| `peer-standards-reviewer` | Consistency with stated standards and whether standards are clear and enforceable. |
| `peer-test-reviewer` | Test strategy, coverage gaps, regression risk, and verification quality. |

## Pairing With Operators

Most role operators have a matching peer-review lens:

| Do the work with | Review it with |
| --- | --- |
| `operator-agents:devops-engineer` | `peer-reviewer-agents:peer-devops-reviewer` |
| `operator-agents:product-manager` | `peer-reviewer-agents:peer-product-manager-reviewer` |
| `operator-agents:product-marketing-manager` | `peer-reviewer-agents:peer-product-marketing-manager-reviewer` |
| `operator-agents:release-manager` | `peer-reviewer-agents:peer-release-reviewer` |
| `operator-agents:resume-writer` | `peer-reviewer-agents:peer-resume-reviewer` |
| `operator-agents:retrieval-engineer` | `peer-reviewer-agents:peer-retrieval-reviewer` |
| `operator-agents:standards-designer` | `peer-reviewer-agents:peer-standards-reviewer` |

Use additional lenses when the work crosses domains. For example, a retrieval
change may also need performance, architecture, database, or interface review.

## Pairing Lenses With Each Other

Some lenses are meant to run *alongside* another rather than instead of it.
`peer-apps-script-reviewer` is the clearest case: dispatch it together with
`peer-code-reviewer` on any Apps Script change. The code lens owns general
correctness; the Apps Script lens owns the platform contract the code runs
inside — who it executes as, which triggers fire, which quotas and execution
walls it must live within, and what its OAuth scopes expose. Because the two
always run together, that lens reports what it deliberately did not judge in a
`## Deferred` section — the target shape for handoffs, which other lenses state
inline today.

## Method

Use a tiered review model. Start with the narrowest lens that owns the risk.
Add adjacent lenses only when the change crosses their boundary.

### Always

Run the direct-owner lens when one domain clearly carries the decision: code
changes go to `peer-code-reviewer` (plus `peer-apps-script-reviewer` when the
change is Apps Script), schema/storage changes go to
`peer-database-reviewer`, release readiness goes to `peer-release-reviewer`,
retrieval/RAG changes go to `peer-retrieval-reviewer`, and product artifacts go
to `peer-product-manager-reviewer`.

### By Trigger

Add a neighbor pass when the direct owner touches another domain: a retrieval
model change may need `peer-performance-reviewer` for cost and latency; a public
CLI change may need `peer-interface-reviewer`; a deployment change with customer
impact may need `peer-release-reviewer`.

### By Change Shape

Add security, privacy, reliability, or architecture when the change affects
trust boundaries, personal data, recovery behavior, system boundaries, or
long-lived coupling.

## Dispatching a Lens

Name the lens, the artifact, and the claim it should evaluate. Include paths,
diff ranges, user or workload context, and the quality bar. Good dispatches are
specific:

```text
Use peer-reviewer-agents:peer-release-reviewer on this release plan and changelog.
Evaluate whether the go/no-go call, known issues, rollback plan, and customer
communications are strong enough for a public patch release.
```

```text
Use peer-reviewer-agents:peer-retrieval-reviewer on the retriever changes in this
diff. The workload is support-search over a small documentation corpus. The
claim is that the new reranker improves answer relevance without hurting
no-answer precision.
```

## Reading a Finding

Findings use severity to describe decision impact:

- `Blocker`: the change is unsafe, wrong, or not ready to ship until fixed.
- `Major`: a real user or operator will hit the problem under a realistic path.
- `Minor`: useful improvement, but not usually release-blocking.
- `Nit`: wording, style, or low-risk cleanup.

Treat file and line references as evidence anchors, not as the whole argument.
The important parts are the failed scenario, why it matters, and the concrete
fix. A good review also names what it is not judging so that ownership stays
clear across lenses.
