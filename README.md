# agentic-plugins

`agentic-plugins` is a public marketplace for reusable agentic plugins.
All 27 agents across the two agent plugins (`peer-reviewer-agents`,
`operator-agents`) are defined once and run under both **Claude Code** and
the **Antigravity CLI** (`agy`) from the same dual-runtime frontmatter.
[Contributions welcome](CONTRIBUTING.md).

- `peer-reviewer-agents`: independent peer-review lenses for software development
- `operator-agents`: hands-on engineering & product senior-role agents, plus
  the writing-prds skill for template-based PRD authoring
- `agent-dispatch`: dispatch coding work and peer reviews to external agent CLIs

The plugins pair naturally: do the work with an operator, then review it with
the matching peer-review lens — or hand either job to `agent-dispatch` to run
against codex, agy/Gemini, or claude instead of the current session.

## Install

### Claude Code

Add the marketplace:

```bash
claude plugin marketplace add vinnyp/agentic-plugins
```

Then install either plugin, or both:

```bash
claude plugin install peer-reviewer-agents@agentic-plugins
claude plugin install operator-agents@agentic-plugins
claude plugin install agent-dispatch@agentic-plugins
```

### Antigravity CLI (agy)

Install a plugin directly from its directory (no marketplace/registry flow
exists for Antigravity yet):

```bash
agy plugin install /path/to/agentic-plugins/peer-reviewer-agents
agy plugin install /path/to/agentic-plugins/operator-agents
```

Each plugin ships a top-level `plugin.json` (the Antigravity manifest)
alongside `.claude-plugin/plugin.json` (the Claude manifest), so the same
agent definitions load under both runtimes. Installed agents show up in
`agy agent` and are invocable as subagents. One difference to know about:
the peer reviewers' read-only contract is enforced by Claude Code via
`disallowedTools`; under Antigravity it's stated in each reviewer's prompt
but not tool-enforced.

## What The Plugins Provide

`peer-reviewer-agents` contains 19 reviewer lenses:

- Apps Script (Google Workspace), architecture, code, database, DevOps,
  interface, performance, planning, privacy, product, product marketing,
  release, reliability, resume, retrieval, security, staff software engineer,
  standards, and testing.

See [peer-reviewer-agents/README.md](peer-reviewer-agents/README.md) for the
full reviewer roster and review method.

`operator-agents` contains 8 senior-role agents plus the `writing-prds` skill:

- DevOps engineer, product manager, product marketing manager, release manager,
  resume writer, retrieval engineer, staff software engineer, and standards
  designer.
- `writing-prds` drives template-based PRD authoring through an
  owner-adjudicated, peer-review-gated loop.

See [operator-agents/README.md](operator-agents/README.md) for the operator
roster, the skill, and the guardrail pattern.

`agent-dispatch` sends a coding task or a peer review to an external agent CLI
(codex, agy/Gemini, or claude) instead of running it in the current session:

- Coding work goes through a preflight → external timeout → completion-marker
  → hard-revert safety net, so a failed dispatch either leaves reviewable
  changes or resets cleanly — never a half-applied edit.
- Peer reviews run the same way, judged for evidence before they count as a
  real review.
- It can also drive a live, watchable agent TUI session over tmux or cmux, and
  ships a `doctor` command to check the runtimes it depends on are ready.

See [agent-dispatch/README.md](agent-dispatch/README.md) for the full CLI
reference and safety contract.

## Updates

Plugin updates apply at the next session boundary. Running
`claude plugin update` fetches the new version, but Claude must be restarted
before that version is active in a session.

Consumers who want automatic marketplace refreshes can opt in with:

```json
{
  "extraKnownMarketplaces": {
    "agentic-plugins": {
      "source": {
        "source": "github",
        "repo": "vinnyp/agentic-plugins"
      },
      "autoUpdate": true
    }
  }
}
```

## License

MIT. See [LICENSE](LICENSE).
