#!/usr/bin/env bash
# Watchdog-mode half of test-repo-state-cli.sh. It is a separate suite so the
# runner runs the timeout and watchdog modes in parallel.
REPO_STATE_CLI_MODES=watchdog exec bash "$(cd "$(dirname "$0")" && pwd)/test-repo-state-cli.sh"
