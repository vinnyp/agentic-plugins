#!/usr/bin/env bash
# stub-agents.sh — create a private dir of inert agy/codex/claude stubs and print its path.
#
# Put them on PATH for the current shell:
#     export PATH="$(bash stub-agents.sh):$PATH"
# or capture the dir and prepend it yourself. Each stub ignores its args, reads no stdin,
# and exits 0 — a SIDE-EFFECT GUARD so a test can never spawn a real external agent
# (a real `agy` triggers an OAuth/browser flow; real `codex`/`claude` cost tokens + network).
#
# Security: `mktemp -d` (no predictable /tmp path → no symlink/PATH-injection race) + 0700.
# Limits: this shadows PATH-resolved invocations ONLY — an absolute-path exec of a real
# binary bypasses it. It is NOT a correctness oracle: do not assert agent *behavior* on the
# exit-0 stub.
set -euo pipefail

tmpbase="${TMPDIR:-/tmp}"
dir="$(mktemp -d "${tmpbase%/}/agent-stubs.XXXXXX")"
chmod 0700 "$dir"
for a in agy codex claude; do
  printf '#!/bin/sh\nexit 0\n' > "$dir/$a"
  chmod 0755 "$dir/$a"
done
printf '%s\n' "$dir"
