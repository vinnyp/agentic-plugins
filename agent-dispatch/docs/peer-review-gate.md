# The peer-review gate

A **tiered peer-review gate** is a convention for reviewing a change with more than one lens before
it merges: a couple of reviewers always run, a few more run when their surface is touched, and the
specialist lenses are your call by change-shape. Every finding is then checked against the real code
before it is accepted, and the round leaves a dated record in the repo it reviewed.

The plugin ships two halves of that:

- **The `running-the-peer-review-gate` skill** (`skills/running-the-peer-review-gate/`) — the
  judgment: which lenses fire, how to brief them, how to verify a reviewer, and the ordering rules
  that stop a Bash-capable reviewer eating an uncommitted diff. Its `references/` carry the three
  normative pieces: the tier rules, the different-model recipe, and the review-log convention. It is
  written for a Claude Code session, but the references stand on their own for any orchestrator.
- **The `review-gate` CLI** (`tools/review-gate/`) — the mechanical parts: brief assembly, the
  serialized different-model run, and the log scaffold. It is persona-agnostic and never decides who
  reviews.

The reviewer personas themselves are **not** in this plugin. They come from
[`peer-reviewer-agents`](https://github.com/vinnyp/agentic-plugins) in the same marketplace, and
`review-gate` reads their bodies from wherever that plugin is installed — so a
different-model reviewer gets the same persona text the Claude Agent tool loads, and the resolved
version is stamped into every brief and log header.

```bash
bin/ensure-review-gate.sh            # compiles tools/review-gate → .bin/review-gate (needs Go)
RG=.bin/review-gate

# one brief per lens — paths, never pasted excerpts
"$RG" brief --persona peer-code-reviewer --mode build --for claude \
  --range main..HEAD --source internal/store/schema.go \
  --what "add a --json flag without changing the text output" > /tmp/brief-code.md

# optionally run the same lens on a different model, serialized
"$RG" cross-model --runtime agy --brief /tmp/brief-code-xm.md --timeout 14m

# scaffold the durable record, then fill in findings + dispositions
"$RG" log-new --topic json-flag --mode build \
  --persona peer-code-reviewer --persona peer-test-reviewer
```

See [`review-gate` in the command reference](commands.md#review-gate) for the full command
contract, and the skill's own `references/` for the tier rules, the different-model recipe, and the
review-log convention.

**Two things leave your machine, and one thing lands in your repo:**

- A **cross-model pass sends the brief — and the repo content it names — to the external model
  provider** behind the runtime you pick (`agy` → Google, `codex` → OpenAI), through
  `dispatch-worker`. Same disclosure as any other dispatch; see
  [Data flow](safety-and-data-flow.md#data-flow).
- **`log-new` writes into the repo you are standing in**, and you commit that log alongside the
  change. It only scaffolds an empty file — it never sees the findings, so it cannot scan or strip
  anything. **On a public repo, redact any personal data a reviewer quoted before you commit the
  log.** That is authoring judgment, not a guarantee the tool provides.
