# operator-agents

`operator-agents` is a reusable set of hands-on senior-role agents for software,
product, release, retrieval, standards, and operations work.

These are senior-role agents, not Kubernetes-style operators or automation
controllers. The word is used in the sense of "the person who does the work."

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
| `retrieval-engineer` | Retrieval/RAG diagnosis, eval-driven tuning, chunking, embedding, reranking, gates, and reversible change sets. |
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
| `operator-agents:retrieval-engineer` | `peer-reviewer-agents:peer-retrieval-reviewer` |
| `operator-agents:standards-designer` | `peer-reviewer-agents:peer-standards-reviewer` |

Use adjacent reviewer lenses when the output crosses boundaries. For example,
release work that changes a public API may also need interface review, and
retrieval work that changes model cost may also need performance review.
