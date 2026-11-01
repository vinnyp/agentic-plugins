# Differential conformance harness

Run `bash run.sh --impl /path/to/entrypoints --out /path/to/results`.
The implementation directory contains the command entry points, so it can be a
baseline's `bin/` directory or a binary's shim directory. `--only <prefix>`
selects scenario IDs. Run `bash compare.sh <results-a> <results-b>` to compare;
the first differing scenario and observation file is printed on failure.

Each `scenarios/<id>/scenario.sh` receives an absolute `IMPL_BIN`, a fresh
`SCN_TMP` and `SCN_REPO=$SCN_TMP/repo`. PATH contains the implementation,
replay stubs, a per-run symlink farm for bash/git/jq/perl/python3, then
`/usr/bin:/bin`. Invoke implementation entry points
through `IMPL_BIN`. Scratch directories are removed after each attempt; use them only for disposable
scenario work. This scaffold includes no capture
scenarios; the unit test creates its sample in an isolated copy.

Every scenario must have exactly one row in `goldens.tsv`, with tab-separated
columns `id`, `tag`, `issue`, `budget_s`, and `retry`. Tags are `preserve` or
`known-defect`; the latter requires an issue reference. Budgets are positive
integer seconds. Set retry to `1` only for signal or timing scenarios, otherwise
`0`. A timed-out attempt with retry enabled gets one fresh attempt, recorded in
stderr and `<out>/<id>/retry.log`. Review this classification when adding rows.

The runner uses `bin/lib/timeout-bin.sh`'s `dispatch_timeout_bin`, including its
portable fallback when neither GNU timer is available. Each attempt has the
listed budget and a one-second kill grace. A budget timeout (124 or 137 from the timer) fails the harness;
Timer failure (125 without scenario completion) also fails the harness; application exit codes are observations for comparison.

Each result directory contains `stdout`, `stderr`, `rc`, and `argv`, plus
`scn_tmp`, which records the exact scratch path for literal normalisation.
Stubs for `codex`, `agy`, and `claude` append shell-escaped command names and
arguments to `$SCN_TMP/argv`. Set `STUB_RECORDING` to a directory containing
`stdout`, `stderr`, and `rc` to replay. Recordings must contain public data only.

Comparison replaces the exact recorded scratch path, then applies
Perl SHA numbering shared across each scenario’s files (`<SHA1>`, `<SHA2>`,
with unambiguous `base_sha` prefixes sharing their full SHA token), then
`normalise.sed` for
`cd-<timestamp>-<pid>` and `phase-<name>-<timestamp>-<pid>` slugs, and whitespace-delimited
`pid=`, epoch `pinned_at=`, and `elapsed=<seconds>s` fields. No lines are
dropped. Generated `REVIEW_OUTFILE` paths named `dispatch-review.<random>`
and eight-digit namespace hashes under `/.worktrees/` also normalise; the
latter depend on the fresh scratch repo's absolute path. Brief fingerprints
remain significant because they are derived from the input brief's contents.
The `base_sha` rule also accepts the colon in `DISPATCH=ok-noop` output.
Exit digits, dispatch verdicts, and flags remain significant. Extend
normalisation only with a context-specific regression test.

`bash baseline-tree.sh <dir>` creates a detached worktree at the full SHA in
the `sha=` field of `BASELINE` (populated by the baseline release task). Use
`bash baseline-tree.sh --remove <dir>` to remove it; dirty worktrees are refused.

Run the focused checks with `bash agent-dispatch/test/test-conformance-harness.sh`
from the repository root. All scripts target Bash 3.2 and stock macOS tools.

The scenario’s own exit status is recorded in `rc`. End the scenario with the
implementation call, or capture that call’s status and explicitly `exit` with it.
Scenarios run with an empty environment plus the harness allowlist; caller agent
settings are excluded. Scratch roots use `DISPATCH_CONFORMANCE_ROOT` or
`$HOME/.cache/agent-dispatch-conformance`, physically resolved outside `TMPDIR`.
Output directories must be empty. `impl_bin` records the implementation path;
comparison replaces it literally with `<IMPL_BIN>`. Stubs also record `stdin.*`.
For multiple calls, use numbered recording directories (`1/`, `2/`, …); missing
steps exit 97. Flat recordings remain supported when no numbered entries exist.
Final timeouts write `harness-timeout` and are always refused by comparison.

The contract inventory attributes environment-table rows to entry points named
in `Read by`. The inventory test checks parser flags and literal exit statuses
one way against `inventory.tsv`; compatibility and record-only flags omitted
from the public prose are explained in `contract/undocumented.tsv`. The five
safe help probes are compared byte for byte with their ordered snapshots.

Runs live in `<root>/run.XXXXXX/<id>/tmp`, with isolated HOME, XDG directories,
and a writable empty global git config. Git identity and dates are fixed.
EXIT, INT, and TERM remove the run directory; startup sweeps runs older than a day.
Runtime recordings resolve `<runtime>/<n>/`, then `<n>/`, then flat files.
A retry.log on only one side prints a warning; other observations still compare.
Literal exit contracts live in `contract/exits.tsv`, independently of script
extraction, so new implementation exits require an explicit contract update.
