# Notebook CLI — Agent Guide

Notebook is a **private, local-only** note-taking CLI written in Go.

## Local-only — do not push or open PRs

This repo has **no git remote** and **no CI**. Commit directly to `main`; there is nothing to push
and no PR to open. Code review happens locally, not via a pull request.

## Build & test

Run `make test` before every commit.

## Recorded decision

The store stays **file-based** (plain JSON on disk) — no database. This is deliberate, for portability.
Don't add a database without overturning this decision explicitly in this file.

## Current state

For status, what's implemented, and known issues, read `STATUS.md` and the project memory before
changing any component — this guide is the rules, not the live state.
