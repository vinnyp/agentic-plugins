# Research Brief: [Topic]

_[Date]. To be passed to a deep research agent._

---

## Context

[2–4 paragraphs explaining:]
[- What project or system this research supports]
[- What has already been decided and should not be re-litigated]
[- What gap this research is closing and why it matters now]
[- Any relevant constraints: language, platform, audience, existing patterns]

[Include APA inline citations for any claims drawn from sources: (Author, Year)]

---

## Questions

### 1. [Concern Area — e.g. Framework Selection]

- [Specific, answerable question with enough context to rule out vague answers]
- [Question targeting version numbers, package names, or benchmark data where
  applicable]
- [Question that surfaces disagreement or evolving best practice]
- [Question specific to the use case — agentic, non-interactive, production, etc.]
- [Question that distinguishes good from bad implementations]

### 2. [Concern Area — e.g. Output Contracts]

- [Question]
- [Question]
- [Question]
- [Question]

### 3. [Concern Area]

- [Question]
- [Question]
- [Question]
- [Question]

[Continue numbering through 8–10 concern areas in total. Each section must
have 4–6 questions; sections with fewer than 4 questions probably belong inside
an adjacent section. If the topic cannot fill 8 areas without padding, it is
too narrow — broaden it rather than inventing filler areas.]

---

## Deliverable Requested

For each question, provide the answer with:
- Source links, version numbers, and package names where applicable
- Side-by-side comparison tables where the question spans multiple options
- A clear statement of which position is most commonly held in recent
  (2024–2025) sources when community opinion is divided

Flag any answer that is inferred from indirect evidence rather than explicit
documentation. State the version of any SDK, framework, or specification the
answer applies to.

**Citation requirements — mandatory throughout your response:**
Every factual claim in your answers that originates from a source must be
cited inline using APA author-date style: (Author, Year) or
(Organization, Year). Do not cite general knowledge. Do not use footnotes
or numbered references inline — use author-date only. At the end of your
response, include a References section with a full APA reference list,
alphabetical by first author or organization, covering every source cited
inline. The response is considered incomplete without inline citations and
the References section.

**Closing recommendation — mandatory:**
At the end of your response and before the References section, provide an
opinionated closing recommendation. The recommendation should take whichever
form best fits the topic — a framework choice, an architectural verdict, a
synthesized position on a contested question, or a prioritized list of
actions — but it must be a decision, not a list of options. Cite the key
sources that informed the recommendation inline.

**The following two sections are also mandatory. The response is considered
incomplete without all five of: answers with inline citations, closing
recommendation, Question Status, Unanswered Questions Summary, and References.**

**Question Status** — reproduce every question from this brief, grouped under
its original concern area heading. Mark each [x] only if FULLY answered, or
[ ] if partially or completely unanswered — a partial answer is unanswered, and
its gap belongs in the summary. Do not invent other marks such as [-].
For every unanswered question, provide: (1) the reason it was not answered,
citing the specific gap in available documentation or sources, and (2) a
concrete, specific follow-up action the reader can take to close the gap.
"Needs more research" is not an acceptable follow-up. "Run the SDK against a
multi-tool task and inspect `context.usage` before and after each call" is.

**Unanswered Questions — Summary** — a consolidated flat list of all
unanswered questions extracted from the Question Status section. Each entry
must include a one-line reason and one-line follow-up. If all questions were
answered, write "All questions answered." explicitly.

---

## Question Status

[This section is mandatory. The research agent must complete it for every
brief. It is a full accounting of every question asked, marked as answered
or unanswered, with explanation and follow-up for all gaps.]

[Format each question as a single line using the checkbox convention below.
Group questions under their original concern area headings. Do not omit any
question — every question asked must appear here.]

### 1. [Concern Area]

- [x] [Question text] — answered in full
- [x] [Question text] — answered; note: answer applies to v2.x only
- [ ] [Question text] — not answered. _Reason: documentation does not address
  this case; only the general pattern is described._ Suggested follow-up:
  [specific action the reader can take — e.g. "test empirically with a
  multi-tool run and inspect context.usage before and after each call" or
  "open the SDK changelog and search for 'batch' across all releases since
  v1.0"]
- [ ] [Question text] — not answered. _Reason: conflicting information found
  across sources; could not determine which is authoritative._ Suggested
  follow-up: [specific action]

### 2. [Concern Area]

[Continue for all concern areas]

---

## Unanswered Questions — Summary

[A consolidated list of only the unanswered questions, extracted from the
Question Status section above. This exists so the reader can scan gaps quickly
without reading the full status table.]

[Format:]

1. [Question text] — [one-line reason] → [one-line follow-up action]
2. [Question text] — [one-line reason] → [one-line follow-up action]

[If all questions were answered, write: "All questions answered." and omit
the list.]

---

## References

[This section serves double duty:]

[1. Brief author citations — sources cited inline in the Context section above.
   Include only if the Context block contains APA inline citations.]

[2. Research agent citations — every source the research agent cited inline
   in its answers. This is mandatory if any answers contain inline citations,
   which they must (see Deliverable Requested).]

[Full APA reference list, alphabetical by first author or organization.]
[Format:]

Author, A. A., & Author, B. B. (Year). Title of work: Capital letter also for
    subtitle. Publisher. https://doi.org/xxxxx

Organization Name. (Year). Title of document. Retrieved from https://url

[The research agent must not omit this section. A response with inline
citations but no References list is incomplete.]
