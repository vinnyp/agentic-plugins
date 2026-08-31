---
name: stubbing-external-agents-in-tests
description: Stub agy/codex/claude on PATH before any test that could exec them, so a test never spawns a real external agent (OAuth/browser flow, token cost, network). Use when writing/auditing a test suite that exercises dispatch-adjacent code (run_host.sh, coding-dispatch.sh, ingest paths). Trigger phrases - "stub the agents in tests", "tests are launching real agy/codex", "OAuth prompt during tests", "hermetic agent tests", "PATH-stub for codex".
---

# stubbing-external-agents-in-tests

## Overview

A real `agy` launched under a throwaway `$HOME` finds no credentials and triggers the Antigravity OAuth/Chrome flow. Before the guard existed this spammed the user ~15 times in a single test run. Real `codex` and `claude` cost tokens and hit the network. The stubs make those binaries resolve to an immediate `exit 0`, so dispatch-adjacent code under test (`run_host.sh`, `coding-dispatch.sh`, ingest paths) runs hermetically and side-effect-free.

This is defense in depth, not a replacement for per-test stubbing: a test that builds its own subprocess env from `os.environ` inherits the stub automatically, and a test that pins a bespoke stub still wins because it prepends its own dir ahead of this one.

## pytest (autouse PATH-stub)

Drop the following two files into your test suite. The `conftest.py` fixture is autouse — every test in the session gets the guard without opt-in.

**`tests/conftest.py`** (this conftest is the pattern a real dispatch-adjacent test suite uses):

```python
"""Shared pytest fixtures and safety guards for a dispatch-adjacent test suite.

The load-bearing guard here is `_stub_external_agents`: an autouse fixture that shadows
the real `agy`, `codex`, and `claude` binaries with no-op stubs on `PATH` for every test.

A test must never spawn a real external agent. A real `agy` launched under a throwaway
`$HOME` finds no credentials and triggers the Antigravity OAuth flow (a Chrome prompt) on
every run — this spammed the user ~15x before the guard existed; real `codex`/`claude`
cost tokens and hit the network. The stub makes the binaries resolve to an immediate
`exit 0`, so dispatch-adjacent code under test (run_host.sh, coding-dispatch.sh, the
ingest paths) runs hermetically and side-effect-free.

This is defense in depth, not a replacement for per-test stubbing: a test that builds its
own subprocess env from `os.environ` inherits the stub automatically, and a test that
pins a bespoke stub still wins because it prepends its own dir ahead of this one. A test
that must observe real-binary-*absent* behavior (e.g. a "tool not installed" branch) opts
out with `@pytest.mark.no_agent_stub`.

Scope: this shadows PATH-resolved invocations (bare `agy`/`codex`/`claude`, as run_host.sh
and coding-dispatch.sh use). A test that execs an *absolute* path to a real binary would
bypass it — none do, and the incident was PATH resolution under a throwaway `$HOME`.
"""

import os

import pytest

#: External agent binaries a test must never launch for real. The proof test in
#: test_conftest_agent_stub.py asserts each of these resolves to the inert stub.
STUBBED_AGENTS = ("agy", "codex", "claude")

#: Private, operator-only tests (the ``*_real.py`` suites that assert against the
#: operator's live local stores/binaries) live under ``tests/private/`` and are
#: gitignored — if your suite keeps private fixtures under a gitignored dir, skip
#: them from the default collection so a bare ``pytest`` (and any publish/release
#: gate) runs only the portable suite; run them explicitly with ``pytest tests/private``.
collect_ignore = ["private"]


@pytest.fixture(scope="session")
def _agent_stub_dir(tmp_path_factory):
    """Create a session-scoped bin dir holding no-op stubs for each external agent.

    Each stub ignores its arguments, reads no stdin, and exits 0 immediately, so any
    invocation of `agy`/`codex`/`claude` resolved through this dir is inert. Built once
    per session because the contents never change.

    Args:
        tmp_path_factory: pytest factory for session-scoped temp dirs.

    Returns:
        Path to the bin dir containing the executable stubs.
    """
    bin_dir = tmp_path_factory.mktemp("agent-stubs")
    for name in STUBBED_AGENTS:
        stub = bin_dir / name
        stub.write_text("#!/bin/sh\nexit 0\n")  # ignore args, read no stdin, succeed
        stub.chmod(0o755)
    return bin_dir


@pytest.fixture(autouse=True)
def _stub_external_agents(request, _agent_stub_dir, monkeypatch):
    """Prepend the agent-stub dir to `PATH` for every test (defense in depth).

    Any test that shells out — directly or via run_host.sh / coding-dispatch.sh — and
    inherits the process environment resolves `agy`/`codex`/`claude` to the inert stub
    instead of the real binary, so no real agent is ever spawned. `monkeypatch` restores
    `PATH` after each test, so the prepend never compounds across tests.

    Opt out with `@pytest.mark.no_agent_stub` when a test must see the real binary absent.

    Args:
        request: pytest request, used to read the `no_agent_stub` opt-out marker.
        _agent_stub_dir: Session-scoped dir holding the stub executables.
        monkeypatch: pytest monkeypatch fixture, restores `PATH` after the test.
    """
    if request.node.get_closest_marker("no_agent_stub"):
        return
    monkeypatch.setenv("PATH", f"{_agent_stub_dir}{os.pathsep}{os.environ.get('PATH', '')}")
```

**`tests/test_conftest_agent_stub.py`** (the pattern a real dispatch-adjacent test suite uses):

```python
"""Prove the autouse external-agent stub guard in conftest.py actually shadows binaries.

These are the mutation check on the safety net itself: if the guard regresses, a real
`agy`/`codex`/`claude` could be spawned (Antigravity OAuth spam, token cost, network).
Each test fails loudly if the stub stops winning on `PATH`.
"""

import os
import shutil
import subprocess

import pytest


@pytest.mark.parametrize("agent", ["agy", "codex", "claude"])
def test_stub_shadows_real_agent_on_path(agent):
    """Prove each external agent resolves to the inert session stub, not a real binary.

    `shutil.which` must land inside the session 'agent-stubs' dir, and invoking the
    resolved binary must exit 0 without doing anything — proving a dispatch under test
    cannot reach the real agent. Mutating the autouse fixture to skip the prepend makes
    `which` resolve to the real binary (or None), failing the dir assertion.
    """
    resolved = shutil.which(agent)
    assert resolved is not None, f"{agent} should resolve to the stub, got None"
    assert "agent-stubs" in resolved, f"{agent} resolved to {resolved}, not the stub dir"
    r = subprocess.run([agent, "-p", "anything"], capture_output=True, text=True, timeout=10)
    assert r.returncode == 0


def test_subprocess_inheriting_env_gets_stub():
    """Prove a subprocess inheriting the test env resolves agy to the stub.

    This is the real-world protection path: code that shells out without pinning its own
    stub (inheriting `os.environ`) still cannot reach a real agent.
    """
    r = subprocess.run(["sh", "-c", "command -v agy"], capture_output=True, text=True, timeout=10)
    assert "agent-stubs" in r.stdout, f"inherited PATH did not resolve to the stub: {r.stdout!r}"


def test_stub_active_without_marker():
    """Positive control: the stub dir IS on PATH for an ordinary (un-opted-out) test.

    Pairs with test_opt_out_marker_disables_stub so that test's "absent" assertion is
    meaningful — this proves the stub is present in this session unless the marker fires,
    distinguishing "the marker disabled the stub" from "the guard never ran". Also fails
    directly if the autouse guard is disabled wholesale.
    """
    assert "agent-stubs" in os.environ.get("PATH", "")


@pytest.mark.no_agent_stub
def test_opt_out_marker_disables_stub():
    """Prove `@pytest.mark.no_agent_stub` removes the stub dir from PATH.

    Guards the opt-out path so a future test can exercise real-binary-absent behavior
    without the guard masking it. Read together with test_stub_active_without_marker
    (the positive control) this is a two-directional proof that the marker is the cause.
    """
    assert "agent-stubs" not in os.environ.get("PATH", "")
```

## Go / Make / shell

Run `stub-agents.sh` (shipped alongside this skill) and prepend its printed dir to PATH before invoking any test harness:

```bash
STUB_DIR="$(bash "$CLAUDE_PLUGIN_ROOT/skills/stubbing-external-agents-in-tests/scripts/stub-agents.sh")"
export PATH="$STUB_DIR:$PATH"
```

Or inline with eval:

```bash
eval "export PATH=\"$(bash "$CLAUDE_PLUGIN_ROOT/skills/stubbing-external-agents-in-tests/scripts/stub-agents.sh"):\$PATH\""
```

The script creates a `mktemp -d` dir with inert `agy`/`codex`/`claude` stubs (each `#!/bin/sh\nexit 0`) and prints the path. Prepend it to PATH before your test runner or build step.

For Make:

```makefile
TEST_STUB_DIR := $(shell bash $(CLAUDE_PLUGIN_ROOT)/skills/stubbing-external-agents-in-tests/scripts/stub-agents.sh)
test:
	PATH="$(TEST_STUB_DIR):$(PATH)" go test ./...
```

## Limits

- **PATH-resolved invocations only.** The stub shadows bare `agy`/`codex`/`claude` as `run_host.sh` and `coding-dispatch.sh` use them. An absolute-path exec of the real binary (e.g. `/usr/local/bin/agy`) bypasses the stub entirely.
- **Side-effect guard, NOT a correctness oracle.** The `exit 0` stub proves no real agent was spawned. Do not assert agent *behavior* (output, files written, exit codes beyond 0) against it.
- **A test that scrubs/rebuilds `PATH` from a hardcoded value loses the guard.** The stub only wins if it is prepended to the PATH the subprocess inherits.
- **`stub-agents.sh` uses `mktemp -d` + `chmod 0700`.** No predictable `/tmp` path — symlink/PATH-injection safe. The pytest path uses `tmp_path_factory` with the same property.
