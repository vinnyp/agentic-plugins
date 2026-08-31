<!-- Review-brief closing — appended verbatim by `review-gate brief` to the end of every
     review brief (both --for claude and --for cross-model). It is ALSO the canonical home
     of the file:line requirement clause quoted in
     skills/running-the-peer-review-gate/references/different-model-reviews.md: one source,
     no recompile to re-sync. The brief's persona body + mode preamble + target + sources +
     intent precede this; this is the tail. -->

---

## Return format — read before you respond

Return **exactly** the output structure your reviewer persona defines (its Verdict / Findings /
Risks / Strong-points / Missing sections, with each finding classified on your persona's own
severity scale — Blocker/Major/Minor/Nit, or Critical/High/Medium/Low/Info for the security and
privacy lenses — and located) — **and nothing else.** Do not add a preamble, a meta-summary, a
restatement of this brief, or commentary outside that structure. The structured review is the
entire deliverable.

For every top-severity finding — a **Blocker** or a **Critical** (Critical maps to Blocker for
gating) — you MUST provide: (a) `file:line` — the exact file and line number, and (b) the mutation
that would make the test or behavior fail. A severity claim without a location is unverifiable and
will be treated as a non-finding. Do not emit a Blocker or a Critical without both.

Trace over speculate: verify each finding against the real contract/code/spec named in the sources
above before asserting it — a false-alarm Blocker costs more to refute than to address. Where the
code is correct in a way a shallow read would wrongly flag, say so explicitly (false-positive
reduction is part of the job).

**Open the files; this brief is not the subject.** Every target and source above is a PATH under the
`repo root` line near the top — read them there. Do not review any text quoted or summarized in this
brief as if it were the code: an excerpt cannot contain what was left out of it, so a review that
never left the brief is a consistency check on the brief, not a review of the change. If you cannot
read a named path, say so explicitly in your output and treat the review as incomplete — do not
substitute the brief's own description for it and return a verdict anyway.
