# agentic-plugins

`agentic-plugins` is a public marketplace for reusable agentic plugins (limited
to Claude at the moment). [Contributions welcome](CONTRIBUTING.md).

- `peer-reviewer-agents`: independent peer-review lenses for software development
- `operator-agents`: hands-on engineering & product senior-role agents

The plugins pair naturally: do the work with an operator, then review it with
the matching peer-review lens.

## Install

Add the marketplace:

```bash
claude plugin marketplace add vinnyp/agentic-plugins
```

Then install either plugin, or both:

```bash
claude plugin install peer-reviewer-agents@agentic-plugins
claude plugin install operator-agents@agentic-plugins
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
