# operator-agents

`operator-agents` is a reusable set of hands-on senior-role agents for software,
engineering design, product, release, retrieval, standards, career, and
operations work.

These are senior-role agents, not Kubernetes-style operators or automation
controllers. The word is used in the sense of "the person who does the work."

## Runtime Support

All 8 operators are defined once and run under both **Claude Code** and the
**Antigravity CLI** (`agy`) from the same frontmatter. Install for agy directly
from the plugin directory (no marketplace/registry flow exists for Antigravity
yet):

```bash
agy plugin install /path/to/operator-agents
```

Installed agents then show up in `agy agent`. The top-level `plugin.json` is
the Antigravity manifest; `.claude-plugin/plugin.json` is the Claude one — both
point at the same agent definitions.

The `writing-prds` skill (below) is runtime-neutral rather than dual-defined:
structured adjudication and subagent dispatch use Claude Code tools
(`AskUserQuestion`, the Agent tool) where available, and fall back to
plain-text adjudication plus the peer-review gate's pluggable-runtime dispatch
path on other runtimes. It is validated end-to-end on Claude Code.

## Skills

| Skill | What it is for |
| --- | --- |
| `writing-prds` | Turns a product idea or an existing scaffold into a locked, review-aligned PRD — template-based authoring, an owner-adjudication loop, and a multi-round peer-review gate that runs until every row is aligned and the document is safe to hand to engineering. The skill drives; the owner decides all WHAT/WHY. |

`writing-prds` requires the `agent-dispatch` plugin (>= the release carrying
`--mode requirements`) from the same marketplace — it calls
`agent-dispatch:running-the-peer-review-gate` in `requirements` mode for each
review round.

## Guardrail Pattern

Each operator acts like a senior practitioner: it investigates, drafts, edits,
runs safe checks, and produces concrete artifacts or change sets. It does the
work directly where the action is reversible and local.

Before anything irreversible, destructive, billable, or outward-facing, the
operator stops and returns the proposed change set for approval. Examples
include publishing, deploying, sending external communications, rotating
credentials, changing DNS, bulk tracker edits, tagging a release, or ratifying a
standard.

## Role Agents

| Agent | What it is for |
| --- | --- |
| `devops-engineer` | Hands-on infrastructure, CI, deployment, hosting, DNS, monitoring, access, and operational work. |
| `product-manager` | Product requirements, problem framing, user journeys, prioritization, success metrics, and product decisions. |
| `product-marketing-manager` | Positioning, messaging, launch narrative, audience fit, naming, and user-facing product copy. |
| `release-manager` | Release coordination, readiness, risk, notes, stakeholder communications, and go/no-go decisions. |
| `resume-writer` | Resume, cover letter, and profile copy built from a candidate's real record, tailored to a target role. |
| `retrieval-engineer` | Retrieval/RAG diagnosis, eval-driven tuning, chunking, embedding, reranking, gates, and reversible change sets. |
| `staff-software-engineer` | End-to-end technical ownership: PRD engineering-readiness and clarifying questions, technical specs/designs that fit the existing system, risk-first implementation plans, direction calls, derisking spikes, and test-first builds. |
| `standards-designer` | Normative specs, schemas, conformance fixtures, compatibility policy, extension models, and governance process. |

## Pairing With Reviewers

This plugin pairs with `peer-reviewer-agents`: do the work with an operator, then
review it with the matching independent lens.

| Do the work with | Review it with |
| --- | --- |
| `operator-agents:devops-engineer` | `peer-reviewer-agents:peer-devops-reviewer` |
| `operator-agents:product-manager` | `peer-reviewer-agents:peer-product-manager-reviewer` |
| `operator-agents:product-marketing-manager` | `peer-reviewer-agents:peer-product-marketing-manager-reviewer` |
| `operator-agents:release-manager` | `peer-reviewer-agents:peer-release-reviewer` |
| `operator-agents:resume-writer` | `peer-reviewer-agents:peer-resume-reviewer` |
| `operator-agents:retrieval-engineer` | `peer-reviewer-agents:peer-retrieval-reviewer` |
| `operator-agents:staff-software-engineer` | `peer-reviewer-agents:peer-staff-software-engineer-reviewer` |
| `operator-agents:standards-designer` | `peer-reviewer-agents:peer-standards-reviewer` |

`staff-software-engineer`'s PRD-readiness, spec, and plan output goes to its paired lens; its
*build* output is a diff and goes through the build-mode gate (`peer-code-reviewer` +
`peer-test-reviewer`) like any other code.

Use adjacent reviewer lenses when the output crosses boundaries. For example,
release work that changes a public API may also need interface review, and
retrieval work that changes model cost may also need performance review.
