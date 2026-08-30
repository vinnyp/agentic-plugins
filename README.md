# agentic-plugins

`agentic-plugins` is a public marketplace for reusable agentic plugins (limited
to Claude at the moment). [Contributions welcome](CONTRIBUTING.md).

- `peer-reviewer-agents`: independent peer-review lenses for software development
- `operator-agents`: hands-on engineering & product senior-role agents
- `agent-dispatch`: dispatch coding work and peer reviews to external agent CLIs

The plugins pair naturally: do the work with an operator, then review it with
the matching peer-review lens — or hand either job to `agent-dispatch` to run
against codex, agy/Gemini, or claude instead of the current session.

## Install

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

## What The Plugins Provide

`peer-reviewer-agents` contains 16 reviewer lenses:

- Architecture, code, database, DevOps, interface, performance, planning,
  privacy, product, product marketing, release, reliability, retrieval,
  security, standards, and testing.

See [peer-reviewer-agents/README.md](peer-reviewer-agents/README.md) for the
full reviewer roster and review method.

`operator-agents` contains 6 senior-role agents:

- DevOps engineer, product manager, product marketing manager, release manager,
  retrieval engineer, and standards designer.

See [operator-agents/README.md](operator-agents/README.md) for the operator
roster and guardrail pattern.

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
