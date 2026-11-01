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
scenario work. The harness unit test replaces the real scenarios and goldens with a private sample.

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

Each result directory contains `stdout`, `stderr`, `rc`, `argv`, and required `state`, plus
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

Recordings use a 20-second bound per runtime through `bin/lib/timeout-bin.sh`
(`DISPATCH_CONFORMANCE_TIMEOUT` overrides it). Codex runs read-only and Claude
runs in plan mode. The default recording root under `$HOME` makes a real Codex
recording refused by design: its diagnostic includes the private home path.
Set `DISPATCH_CONFORMANCE_ROOT` to a neutral path outside both the home directory
and TMPDIR before recording. Work directories are private (mode 700).

Live checks separate stdout from stderr and require explicit reply markers.
`DISPATCH_LIVE_TIMEOUT` overrides the default 20-second probe bound for tests.
Each probe ignores global and system Git configuration. Silent replies fail.

The edit slice runs with `bash agent-dispatch/test/test-conformance-edit.sh`;
`IMPL_BIN` can select another implementation. Its fixtures use only synthetic
Codex and agy recordings plus a small edit wrapper, never a real runtime. Golden files
come from BASELINE 1.9.5; literal scratch and implementation paths are replaced
with `<SCN_TMP>`, `<RUN>`, and `<IMPL_BIN>` before committing. Metadata uses those
same placeholders so the ordinary comparator still applies. A fixture Python
version reply and a fixed clock for review pins keep host versions and pin ages
out of the observations. All other implementation output remains significant.

`edit-coverage.tsv` maps exact inventory rows to a scenario and an observed exit
or output fragment. `edit-line-exemptions.tsv` enumerates documentation
prose/input rows and out-of-slice flag/environment contracts with individual reasons; new inventory rows fail closed. Exit 4 is a census
artifact from the partial-runner signature, so `edit-partial` proves the actual
exit-2 refusal. Task 2 output rows are exercised by a real three-task phase. `edit-newdir` preserves vinnyp/foundry#275; duplicate
failure verdicts in the scope, newdir, marker, and FM4 captures preserve cutover change
12. These are observations of the frozen contract, not desired behavior.

Before cleanup, `capture-state.py` runs inside the scenario's hermetic environment.
It records HEAD, sorted branches, worktree porcelain, each tree's full status and
result-marker presence, failure patches, line counts and SHA-256 digests of their bytes, and the sorted sibling
`.worktrees` listing. A non-repository scenario records `repository absent`.
The comparator requires state on both sides and shares SHA numbering with all
other observations. Failed in-place captures must restore the fixture base and
leave a clean tree. Empty/unavailable worktrees, interrupted partial edits,
marker-backed TDD commits preserved after gate failure or signal, committed worker salvage, removal overrides, stale bases, timeout, no-gate
and inferred Go gates, marker exemptions, and phase failures have separate cases.
The edit budgets total under 420 seconds, including the signal retry allowance.

The worker slice runs with `bash agent-dispatch/test/test-conformance-worker.sh`
(`IMPL_BIN` optionally selects another implementation). Its 47 scenarios use
synthetic, numbered runtime recordings, including agy's models probe, persona
roster, dispatch and retry. Short codex and Claude reviews preserve their ungated
behavior; agy independently exercises the byte floor, evidence, each requirements
row verdict, dirty brief refusal and opt-outs. Runtime wrappers create real
source-config drift during review and sleep under the dispatcher's timeout.
They never invoke a real agent or search for processes to signal.

Worker goldens were captured with `baseline-tree.sh` at the SHA in `BASELINE`.
Literal scratch, run and implementation paths use the same placeholders as the
edit slice; context-specific temporary review names are normalised too, including
BSD `mktemp -t` prefixes, longer suffixes and trailing punctuation. Stdin is part
of comparison, including the injected preambles and retry's unchanged brief.
The suite also asserts intent independently of golden comparison, and rejects
missing recordings for any runtime with exit 97.

`worker-coverage.tsv` accounts for exact dispatch-worker exit, output, flag and
environment inventory rows. `worker-exemptions.tsv` gives a reason for each
remaining row: documentation context, historical rejected runtime flags,
coding-only census attribution, and state/clone/signal/environment details
reserved for later slices. Both lists are closed: adding an inventory row of
any of the four kinds fails the suite. The worker scenario budgets sum to 394
seconds, with no harness retries.

### Worker known defects

- `worker-pin-fail` stubs `review-pin.sh` to return 3. Both baseline and current
  dispatchers call `review_launch_failure 125`, which unconditionally exits 3;
  the requested exit 125 cannot be captured without changing production code.
  The golden preserves exit 3 and verifies that no reviewer launches.

- `worker-codex-child-env` preserves `CODING_DISPATCH_CHILD_ENV` reaching the
  runtime. The synthetic child prints the received value to make leakage visible.
- `worker-codex-orphan` preserves an orphaned `_coding-result.json` after a
  successful direct worker dispatch. The synthetic child writes the marker;
  automatic repository-state capture proves that it remains.

These local references identify frozen observations, not fixes. No production
entry point is modified by the worker capture task.

The scripts retain Bash 3.2 syntax. The exact Bash job-control race diagnostic
`child setpgid (... to ...): Operation not permitted` is normalised on both
stdout and stderr; other diagnostics remain significant.

Call records compare physical working directories, source/clone placement,
global Git config paths and SHA-256 digests, visible sentinels, and source pin
presence. State capture also checks pin release and the configured review directory.

The state slice runs with `bash agent-dispatch/test/test-conformance-state.sh`
(`IMPL_BIN` optionally selects another implementation). Its 25 scenarios call
only public entry points. Pin status, duplicate pin refusal, release, invalid TTL,
and a two-second clock advance with a one-second TTL exercise the lifecycle.
The pinned coding dispatch must return 9 without invoking a runtime or changing
tracked content. Clone scenarios exercise private content/config/refs, absence
of alternates, guarded removal, filter refusal and unsuitable destinations.

State comparisons snapshot real configuration, hooks and replacement refs;
each change must return critical (2). Touching a tracked file without changing
its bytes is harmless and must return clean (0). Gate scenarios exercise venv
selection and opt-out, command exit propagation, and expected-root refusal.
Long-gate scenarios use only immediate finite commands and synchronously wait
for their completion; pending-log timeout uses an empty log with zero wait.
No full gate or real runtime is launched. The scenario budgets total 300 seconds,
with no retries. `state-coverage.tsv` accounts for exact inventory rows across
all five commands; `state-exemptions.tsv` records individual exemptions for
contextual documentation and interfaces outside this slice. The suite injects
new rows for every command/kind pair to prove that accounting fails closed.

Goldens use BASELINE 1.9.5's full SHA from `BASELINE`. The capture used a read-only
`git archive` export of that tree's entry points and accompanying docs, avoiding
worktree metadata changes. Scratch, run and implementation paths are replaced
literally with the existing harness placeholders. Fixture clocks and tool
version replies keep host differences out of observations. All implementation
verdicts, diagnostics, statuses and automatic Git-state observations remain
significant. Independent assertions check intent before golden comparison.

### State known defects

These local issue records use the same issue-reference convention as the worker
slice; they describe frozen observations and do not change production behavior.

- STATE-001 (`state-compare-filter`): a newly configured `filter.*.clean` actually
  runs during snapshotting, before config comparison reports critical. The
  fixture changes a tracked text file with same-size content and an old mtime
  to force filtering regardless of timestamp resolution. Its filter writes a
  sentinel, and the scenario asserts it exists.
- STATE-002 (`state-compare-deleted`, `state-compare-truncated`): deleting or
  emptying a standalone baseline yields input error 3, rather than critical 2.
  Both are refused; neither is clean. Preserve these observations as known
  defects against the requested critical contract.
- Issue #267 (`state-compare-socket`): a real Unix-domain socket at
  `.git/fsmonitor--daemon.ipc` is classified as nonregular/critical even though
  Git's fsmonitor socket can be legitimate. The fixture binds a relative path
  to avoid platform Unix-socket path-length limits, then closes its own socket.

### Capture mapping

`check-mapping.sh <external-census.csv> [--extra <ids>]` accepts a target only
through `targets.tsv` or `accepted-gaps.tsv`, never both. Accepted gaps require
one of `other-project`, `agent-behaviour`, `test-tooling`, or `test-only` and an
explanation. In-scope census rows must have a nonempty environmental-knowledge
value. Counts report census targets and additional `--extra` targets separately,
then mapped, accepted, and unmapped IDs from their deduplicated union.
An ID selected by both inputs appears in both input counts. The external census is never copied into this repository.

`test-conformance-capture.sh` compares additional baseline captures and asserts
no-edit failure routing, scope refusal, the deprecated `worktree` output alias,
injected prompt cleanup, output symlink protection, and detached finite execution
without `setsid` in PATH. It never runs a full gate or a real agent.

`capture-shared-config` freezes vinnyp/foundry#239: a synthetic worker in a
linked worktree writes the shared Git configuration, yet dispatch succeeds.
Its golden must change when cutover change 7 detects this write.
`capture-limit-file` freezes vinnyp/foundry#263: printing a document containing a
capacity phrase is mistaken for an unavailable service. The existing socket
capture explicitly preserves vinnyp/foundry#267.

`live-smoke.sh --models-only` is an attended metadata-only check. It compares
both agy pins from `bin/lib/agy-models.sh` with `agy models`, then uses Codex's
app-server `config/read` and paginated `model/list` to check its configured
default (or the roster default when unset). It sends no thread or turn request.
Missing tools, failed metadata requests, and absent pins fail the check.
The capture suite tests the Codex protocol with a synthetic server, including
pagination, configured and implicit defaults, and an absent model.

### Repository-state test rewrite

Run `bash agent-dispatch/test/test-conformance-repo-state.sh` for the migrated
repository-state cases. The `repo-state-*` scenarios invoke only
`repo-state-check`, `dispatch-worker`, and `review-pin.sh`; their shared files
contain fixture setup and public-command adapters. Each scenario retains
independent assertions as well as baseline comparison. Configuration cases
check credential values, credentialed keys, ambiguous URL userinfo, salted key
distinction, command argument truncation, and escaped display bytes.

`rewrite-map.tsv` accounts for original cases and assertion locations before
deleting the three old suites. Parameterized rows retain every input in the
listed loop. Public deadline, signal, atomic publication, cleanup, malformed
input, history, hook, worktree and concurrent status cases remain covered.
The obsolete watchdog-only wrapper was also removed. Bash descriptor channels,
function serialization, payload framing, completion tokens, caller shell flags,
and implementation allocation/batching policies are dropped because the spec
removes that transport. Deterministic slow Git substitutes for Git-version
dependent FIFO blocking probes. `source-allowlist.tsv` explains test-helper
sourcing and the small existing producer fault-injection suite.

These goldens are recorded through `baseline-tree.sh` at the pinned BASELINE
SHA. Fixtures use fixed identities and synthetic reviewers; each child is
waited for and no real agent is invoked. The worker bound cases assert exit 10,
an incomplete drift diagnostic, and pin release.

### Probe test rewrite

Run `bash agent-dispatch/test/test-conformance-probes.sh` for the migrated probe
cases. Five `probe-*` scenarios exercise `coding-preflight.sh`,
`agent-dispatch-doctor`, and the existing public `dispatch-worker` flows with
synthetic runtimes. No scenario sources an implementation file. Fixtures keep
independent assertions for model parsing, role defaults and overrides,
authentication, symlink resolution, bare-stdin sentinel validation, timeout
bounds, nonce execution, cache isolation and digest-tool selection. The doctor
case checks both role defaults, missing models, unparseable rosters and failed
metadata requests without launching a turn.

`rewrite-map.tsv` enumerates the original cases and loop inputs. Public missing
binary errors replace the private probes' advisory return codes. Empty model
parser inputs, cached shell variables, caller traps and signals aimed at a
private function subshell are explicitly dropped with reasons; these are not
published command interfaces. The default form timeout is observed at the timer
boundary and with a real eleven-second synthetic reply. Codex bounds include
invalid inputs and all accepted integer units. No real agent or long gate runs.

Goldens are captured through `baseline-tree.sh` at the pinned `BASELINE` SHA.
Each scenario returns zero only after its public-command assertions pass;
its output records the completed cases. All five have finite budgets and no
retry. Scratch and implementation paths use the standard harness placeholders.

### Review clone test rewrite

Run `bash agent-dispatch/test/test-conformance-clone.sh` for the migrated
`bin/test-review-clone.sh` cases. `clone-contract` invokes only the published
`review-clone.sh` interface. Its assertions retain every original case, including
quoted and tabbed attribute paths, large info attributes, linked sources, remote
isolation, destination validation, guarded removal, and symlink CLI usage.
The convergence fixture wraps Git to add a source tag at the first source ref
listing; it calls no implementation functions. Private result variables are
observed through CLI stdout and single-line stderr. No cases are dropped and
no implementation sourcing remains in this group. The baseline golden is
recorded through `baseline-tree.sh` at the SHA in `BASELINE`.

The freshness rewrite runs with `bash agent-dispatch/test/test-conformance-freshness.sh`.
`freshness-contract` retains all six cases from `bin/test-dispatch-freshness.sh`
through `coding-dispatch.sh`: fetched staleness, failed-fetch fallback, current
base, origin fallback without an upstream, stale-base override, and detached
HEAD. Goldens were recorded using `baseline-tree.sh` at the SHA in `BASELINE`.
The scenario locates disposable worktrees with Git's public porcelain output.

`rewrite-map.tsv` also accounts for the retained review-launch FIFO matrix,
allocation and snapshot failures, and portable-stat helper/integration checks.
Their `scenario_id` cells name the retained test paths; reasons live in
`source-allowlist.tsv`. Review-launch sources only test environment reset and
portable timer selection. Portable-stat directly tests helper return values
and invokes mutation verification/sweep commands; it is retained as the small
helper exception and cannot run when mutation tools are prohibited.
The harness suite checks the anchored implementation-sourcing pattern across
all scenarios and migrated suites, requiring an explicit allowlist reason.

### Stock repo-state coverage after suite retirement

The stock skip manifest requires the verified case tokens printed by
`test-conformance-repo-state.sh` after golden comparison succeeds. Clean snapshot
performance, bounded worker comparison, hostile snapshot fallback, slow snapshot
and comparison, and hostile metadata remain mandatory. The former timeout and
watchdog function modes share their public-command replacements; their private
transport distinction was explicitly dropped in `rewrite-map.tsv`.

`repo-state-inputs` checks the FIFO snapshot warning byte for byte against its
fixture path in the scenario, keeping scratch paths out of its stderr golden.
That empty stderr observation was recaptured from the pinned baseline archive;
the remaining observations are unchanged. A comparison failure now prints a
normalized unified diff labelled `expected` and `actual`.
