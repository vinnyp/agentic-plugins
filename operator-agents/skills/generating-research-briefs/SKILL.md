---
name: generating-research-briefs
description: "Use when the user asks to create a research brief, research request, or set of research questions on a technical or domain topic to hand to a deep research agent. Triggers include \"generate a research brief\", \"write me questions for a research agent\", \"I need to research X\", \"generate a brief for X\", or \"what should I ask a research agent about X\"."
---

# Generating Research Briefs

Produces a structured deep research brief for a given topic — an organized set
of questions designed to be passed to a deep research agent. The brief is a
handoff artifact: it requires no further editing to be usable, and the research
itself is never run here.

## Behavior at a glance

1. Load project context from AGENTS.md / CLAUDE.md if present
2. Clarify topic, purpose, what's decided, and what's open — before generating
3. Reason about the domain: 8–10 concern areas, 4–6 questions each
4. Assess scope, present a single-brief-or-split recommendation, wait for approval
5. Write the brief using the standard structure
6. Export automatically once the user confirms it's ready — stdout and a local file

## Step 1 — Load project context

Before asking the user anything, check for a project contract — `AGENTS.md`,
`AGENT.md`, or `CLAUDE.md` — in the current working directory or any parent
directory up to the project root. Prefer `AGENTS.md` (newer convention); fall
back to `AGENT.md`, then `CLAUDE.md` (which often just points at one of the
others).

```bash
# Check for a project contract in cwd and parents (prefer AGENTS.md).
# Stop at the repository root; cap the walk at four levels for non-git trees.
dir=.; depth=0
while [ "$depth" -lt 4 ]; do
  for name in AGENTS.md AGENT.md CLAUDE.md; do
    if [ -f "$dir/$name" ]; then echo "== $dir/$name =="; cat "$dir/$name"; break 3; fi
  done
  [ -e "$dir/.git" ] && break
  case "$(cd "$dir" && pwd)" in "$HOME"|/) break ;; esac
  dir="$dir/.."; depth=$((depth + 1))
done
```

If a contract is found and contains useful context (project purpose, what's
been built, what's already decided), use it to ground the brief — it often
answers parts of Step 2 before you have to ask. When you first respond, include
a one-line acknowledgment naming which sections you drew from — e.g. "Grounded
in AGENTS.md sections: Conventions, What's been covered." This confirms the
right context was loaded without cluttering output.

If no contract is found, or it's sparse or not relevant to the topic, say so
and proceed to Step 2.

## Step 2 — Clarify before generating

Do not generate the brief until you have clear answers to all four:

1. **Topic** — what is the brief about? (e.g. "Go CLI best practices", "OTel
   GenAI semantic conventions adoption")
2. **Purpose** — what will the output be used for? (e.g. "writing a pattern
   file", "making an architecture decision", "informing a PRD")
3. **What's already decided** — what should the research agent NOT cover?
   (closed questions, already-chosen libraries, settled design decisions)
4. **What's still open** — the actual gaps the research needs to close

If the user's message already answers all four, proceed directly to Step 3.
Otherwise ask all missing questions in a single message, not one at a time.

## Step 3 — Reason about the domain

Think through what a domain expert would want to know about this topic.
Identify **8–10 concern areas with 4–6 specific questions each**.

Within that shape, aim for:

- Distinct concern areas that don't overlap (e.g. framework selection, error
  handling, output contracts, distribution, testing)
- Within each area, the questions that distinguish good from bad
  implementations
- Questions that surface disagreement or evolving best practice
- Questions that produce **citable, specific answers** — version numbers,
  package names, benchmark data — rather than vague generalities
- Questions specific to agentic / non-interactive use cases where relevant

Prefer specific questions over broad ones. "Which version of Cobra introduced
persistent flags?" is better than "How does Cobra work?"

If the topic genuinely cannot fill 8 concern areas without padding, that is a
signal the topic is too narrow — say so and offer to broaden it, rather than
inventing filler areas. If it overflows 10, that is a signal for Step 4.

## Step 4 — Assess scope and present recommendation

Before writing, evaluate whether the identified concern areas belong in a
single brief or should be split across multiple briefs.

**Recommend splitting if any of the following is true:**
- Two or more concern areas could be handed to entirely different subject
  matter experts — a researcher who knows one area deeply would not need to
  read the other areas to answer its questions
- The concern areas span fundamentally different information sources — e.g.
  one cluster lives in SDK documentation while another lives in academic
  benchmarks or community surveys
- Answering one cluster first would materially change which questions are
  worth asking in another cluster — i.e. the clusters have a natural
  sequencing dependency that makes them better run serially

**Proceed as a single brief if:**
- The concern areas share a common information source or domain such that
  a single researcher would naturally encounter answers to all of them
  together, OR
- The questions are interdependent — context from one area is needed to
  correctly interpret or scope questions in another

Do not default to splitting. The decision must be justified by the nature of
the questions, not their count. A large but coherent brief is better than two
thin, redundant ones. **Each brief produced by a split must independently hold
8–10 concern areas** — if a split forces you to pad a sub-brief to reach 8, the
split is wrong.

**Always present the recommendation and wait for approval before writing.**
Show the user either:
- The proposed split, naming each sub-brief, listing which concern areas
  belong to it, and explaining in one sentence why that grouping is coherent
- The proposed single brief, listing the concern areas and explaining in one
  sentence why splitting would hurt rather than help

Do not proceed to Step 5 until the user confirms. Their confirmation may
include adjustments to the proposed structure — incorporate those before
writing.

## Step 5 — Write the brief

Follow the template in `assets/research-brief-template.md` exactly. Key
requirements:

- **Header** — `# Research Brief: [Topic]`, followed by the date and the line
  "To be passed to a deep research agent."
- **Context block** — 2–4 paragraphs explaining the project, what's already
  decided, what gap this research closes, and why now. Draw from AGENTS.md
  where available. Any factual claim drawn from a source must be cited inline
  using APA author-date style: (Author, Year). Do not cite general knowledge.
- **Questions grouped by concern area** — 8–10 groups, each with a **numbered
  heading** and 4–6 questions beneath it as bullets.
- **Deliverable specification** — the final section telling the research agent
  exactly what format to return its answers in. This section is the primary
  contract with the research agent and must include every requirement listed
  in the template, with no omissions. It must tell the agent to flag inferred
  vs. documented answers, to include source links and version numbers, and to
  close with an opinionated recommendation — not a list of options.
- **Mandatory output requirements imposed on the research agent** — the
  deliverable specification must explicitly require the research agent to
  produce all four of: (1) APA inline citations on every factual claim plus a
  References section, (2) a closing recommendation that is opinionated rather
  than a list of options, (3) a **Question Status** section reproducing every
  question from the brief, grouped under its original concern area heading,
  marked `[x]` or `[ ]`, with a documentation-gap reason and a concrete
  follow-up action for each unanswered one, and (4) an **Unanswered Questions
  — Summary** consolidated flat list.
- **References** — a full APA reference list, alphabetical, for all inline
  citations used. Omit this section if no sources were cited.

See `assets/research-brief-template.md` for the full structure and exact
wording of the deliverable specification.

## Step 6 — Export (automatic)

Once the user confirms the brief is ready, **export immediately — both
destinations, without asking for permission and without waiting for a separate
instruction.**

Finalization means the user has confirmed the brief is ready. That confirmation
is the only gate; do not add another one in front of the export.

### 6a — Print the markdown to stdout

Print the **complete brief as raw markdown** in a fenced code block, so it can
be read in place and copy-pasted anywhere without opening a file. Print the
full text — never a summary, an excerpt, or a "see the file" pointer.

This is what puts the finished brief where it is actually used — a deep
research agent's chat box. The raw markdown IS the handoff mechanism, not a
preview of the file.

### 6b — Save locally

Write the brief to `briefs/research-brief-<slug>.md`. Create the `briefs/`
directory if it does not exist.

Derive `<slug>` by lowercasing the topic, replacing every run of characters
outside ASCII `a-z0-9` with a single `-`, and trimming leading and trailing `-`.
Use ASCII explicitly, not a locale-aware or Unicode character class — a topic
like "API v2 (café)" must produce the same filename on every machine.

If the target file already exists, do not overwrite it — append `-2`, `-3`, …
to the stem.

After writing, report the path.

If the write fails (read-only tree, no permission, `briefs` exists as a file),
say so explicitly, name the path and the reason, and state that the stdout copy
in 6a is the complete artifact.

The brief is a plain markdown file. Routing it into whatever system the project
files documents in — a docs tree, a wiki, an issue tracker, a knowledge base —
is the user's call and outside this skill's scope. State the path and stop.

If the findings come back missing the Question Status or Unanswered Questions —
Summary section, re-prompt the research agent naming that section explicitly
rather than accepting the response as complete.

## Constraints

- Never generate a brief without completing Step 2. A brief with a vague topic
  or unclear purpose is not useful.
- Never proceed past Step 4 without explicit user approval of the
  single-or-split recommendation.
- One brief per request. If the user asks for multiple topics, or if Step 4
  results in a split, handle each brief in a separate response after confirming
  the structure.
- Do not run the research yourself. The brief is a handoff artifact.
- All claims in the Context block that originate from a source require APA
  inline citation. The brief author's own synthesis does not require citation.
- The deliverable specification must always ask for a closing recommendation
  that is a decision, not a list of options.
- The deliverable specification must explicitly require all four mandatory
  outputs (APA citations + References, closing recommendation, Question Status,
  Unanswered Questions Summary). The **Question Status** section and the
  **Unanswered Questions — Summary** are non-negotiable — the brief is
  incomplete without both.
- The deliverable specification must always ask the research agent to flag
  inferred vs. documented answers, and to state the version of any SDK,
  framework, or specification its answer applies to.
- **Export (Step 6) is automatic and mandatory** — do not skip it, and do not
  ask before doing it once the user has confirmed the brief is ready. Both
  destinations are part of the export; the stdout markdown copy (6a) is not an
  optional extra.
- Read `assets/research-brief-template.md` before generating any output. If it
  cannot be read, stop and say so — do not write a brief from this file's
  summary of the template. The Question Status and Unanswered Questions —
  Summary sections come from the template, and a brief without them does not
  satisfy the deliverable contract.
- The Context block paraphrases project context. Never copy personal names,
  email addresses, customer identifiers, internal hostnames, credentials, or
  tracker IDs out of a contract file into the brief.

## Reference files

- `assets/research-brief-template.md` — the exact format to follow when
  writing the brief. Read this before generating any output.
