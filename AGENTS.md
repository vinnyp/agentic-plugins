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
- `agent-dispatch` is a `bin/` + `skills/` plugin. Its
  manifest is `agent-dispatch/.claude-plugin/plugin.json`; its bare-PATH CLIs
  live in `agent-dispatch/bin/` (with shared helpers under `agent-dispatch/bin/lib/`
  and their tests as `agent-dispatch/bin/test-*.sh`), its one skill lives in
  `agent-dispatch/skills/driving-agent-sessions/`, and its own test fixtures
  live in `agent-dispatch/test/`.

## Agent frontmatter contract

Every agent in `peer-reviewer-agents/agents/` and `operator-agents/agents/`
declares `name` (matching its filename), `description`, `disallowedTools`,
`mainAgent`, and `subagent` — and **no `tools` key**. A `tools` key silently
excludes the agent under `agy` while both validators still report success, so
CI asserts its absence, that each `name` matches its filename, that names are
unique, and that every `peer-*-reviewer` named in the published docs resolves
to a real agent.

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
