# Contributing

Contributions are welcome. This repository is public, so every contribution must
be safe to publish: no secrets, personal data, private paths, private workspace
names, unpublished agent names, or internal service URLs.

## Pull request flow

1. Fork the repository and create a branch.
2. Make a focused change.
3. Update the relevant README or changelog when behavior changes.
4. Run local checks when available:

   ```bash
   claude plugin validate .
   gitleaks dir --no-git .
   ```

5. Open a pull request with a clear summary and testing notes.

## CI

Pull requests from forks run without repository secrets. CI runs:

- `claude plugin validate .`, with warnings treated as failures.
- `gitleaks` in directory mode.
- `commitlint` against pull request commits.

Maintainers may run additional model-backed evaluation before merging behavior
changes. That evaluation is not a fork-PR gate because it requires credentials.

## Versioning

Each plugin is versioned from its own `.claude-plugin/plugin.json` file.
Removing or renaming an agent is a breaking change. Changing an agent's behavior
can also be breaking if callers would need to change how they dispatch or
interpret it.
