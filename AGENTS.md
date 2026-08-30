# agentic-plugins contributor guide

This repository contains public, reusable Claude plugins. Keep contributions
generic, documented, and free of private project names, private service URLs,
credentials, personal data, or local machine paths.

## Repository shape

- Marketplace metadata lives in `.claude-plugin/marketplace.json`.
- Each plugin lives in its own subdirectory.
- `peer-reviewer-agents` is an agents-only plugin. Its manifest is
  `peer-reviewer-agents/.claude-plugin/plugin.json` and its agents live in
  `peer-reviewer-agents/agents/`.
- `operator-agents` is an agents-only plugin. Its manifest is
  `operator-agents/.claude-plugin/plugin.json` and its agents live in
  `operator-agents/agents/`.

## Contribution rules

- Do not add private paths, private tracker IDs, internal hostnames, secrets, or
  unpublished agent/plugin names.
- Keep agent prompts domain-general unless the agent is explicitly documented as
  product-specific.
- Update the relevant plugin README and changelog when behavior changes.
- Run validation and leak checks before opening a pull request.

## Validation

```bash
claude plugin validate .
gitleaks dir --no-git .
```

Validation warnings are treated as failures in CI.
