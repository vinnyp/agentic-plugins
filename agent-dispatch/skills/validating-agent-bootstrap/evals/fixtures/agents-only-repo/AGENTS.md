# Ledger CLI — Agent Guide

Ledger is a **private, local-only** personal-finance CLI.

## Local-only — do not push or open PRs

No git remote, no CI. Commit directly to `main`; review locally. Don't run `git push` or `gh pr create`.

## Build & test

Run `make check` before committing.

## Recorded decision

Amounts are stored as integer cents, never floats. Don't change this without overturning it here.
