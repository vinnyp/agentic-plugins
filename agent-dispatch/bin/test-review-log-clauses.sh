#!/usr/bin/env bash
set -euo pipefail

bin_dir=$(cd "$(dirname -- "$0")" && pwd -P)
plugin_dir=$(cd "$bin_dir/.." && pwd -P)
repo_dir=$(cd "$plugin_dir/.." && pwd -P)
skill=$plugin_dir/skills/running-the-peer-review-gate/SKILL.md
convention=$plugin_dir/skills/running-the-peer-review-gate/references/review-log-convention.md
prds=$repo_dir/operator-agents/skills/writing-prds/SKILL.md
agent_prds=$repo_dir/operator-agents/skills/writing-agent-prds/SKILL.md
fences=$repo_dir/operator-agents/skills/writing-agent-prds/assets/fences-template.md
go_main=$plugin_dir/tools/review-gate/main.go
go_lognew=$plugin_dir/tools/review-gate/lognew.go

fail() { echo "FAIL: $*" >&2; exit 1; }
require() {
  [ -f "$1" ] || fail "missing $1"
  grep -Fq -- "$2" "$1" || fail "$1 lacks: $2"
}

tiers=$plugin_dir/skills/running-the-peer-review-gate/references/peer-review-tiers.md
for file in "$skill" "$tiers"; do
  require "$file" 'or what a check proves'
  require "$file" 'what the check emits when it could not evaluate its subject (never PASS)'
  require "$file" 'the positive control or known-verdict set that shows it can fire'
  require "$file" 'no Blocker/Major remains'
done
require "$plugin_dir/docs/commands.md" 'a parallel exit 0 is only as trustworthy as the suite'
require "$plugin_dir/docs/commands.md" 'the one-time serial-equal confirmation must include caught mutants'
require "$plugin_dir/docs/commands.md" 'the canary proves only that the control'
require "$plugin_dir/docs/commands.md" '[--design-round <label|none>]'
require "$plugin_dir/docs/commands.md" 'In copy mode (`--copy-root`) a control is required, which runs first as a canary; a copy-mode or parallel exit 1 or 3 is INCONCLUSIVE until a serial in-place run confirms it. In place, a control remains recommended, not required.'
require "$skill" 'then run the gate in **design** mode on that note'
require "$tiers" 'before the build'
require "$skill" '--design-round none'
require "$skill" 'must state its reason'
require "$convention" 'design → build'
require "$tiers" 'records which round reviewed the design note'
require "$skill" 'records which round reviewed the design note'

require "$skill" 'rc 2/3/9/10 rules take precedence'
require "$skill" '0 bytes at rc 0, 1 or 8, or at any rc not otherwise enumerated'
require "$skill" 'short (non-empty) body at an unlisted rc'
require "$plugin_dir/skills/running-the-peer-review-gate/references/different-model-reviews.md" '[SKILL.md § Dispatch](../SKILL.md#4-dispatch) is the authority for rc handling and the codex re-run'
require "$skill" 'cross-model --runtime codex --brief <same brief>'
require "$skill" 'Codex egress is default DENY; explicit operator approval for this repo is required.'
require "$skill" 'codex (not capability-tested)'
require "$skill" 'per-lens runtime block'
require "$convention" 'per-lens runtime block'
require "$skill" 'A same-model Claude substitution must never be reported as a cross-model pass in the log or a PR body.'

require "$skill" 'review-log-status --archive <log-path>'
require "$skill" "Quote the CLI's"
require "$skill" 'first stdout word'
require "$skill" 'Only `committed` permits a shipped claim or repo link.'
require "$skill" 'Completion checklist: run `review-log-status --archive <log-path>`, quote its first stdout word,'
require "$convention" 'Never claim the log was shipped without a'
require "$convention" '`committed` result from `review-log-status`'
for state in committed staged untracked ignored; do
  require "$convention" "- \`$state\`"
done
require "$prds" 'review-log-status'
require "$agent_prds" 'review-log-status'

for file in "$skill" "$convention" \
  "$plugin_dir/skills/running-the-peer-review-gate/references/peer-review-tiers.md" \
  "$plugin_dir/docs/peer-review-gate.md" "$plugin_dir/.claude-plugin/plugin.json" \
  "$prds" "$agent_prds" "$fences" "$go_main" "$go_lognew"; do
  [ -f "$file" ] || fail "missing $file"
  if grep -Fq 'Commit it to the caller repo' "$file" || \
    grep -Fq 'durable review log' "$file" || grep -Fq 'durable log' "$file" || \
    grep -Fq 'durable peer-review log' "$file" || grep -Fq 'durable review-log' "$file"; then
    fail "$file carries superseded log wording"
  fi
done

for file in "$plugin_dir/bin/mutation-verify.sh" "$skill" "$plugin_dir/docs/commands.md"; do
  if grep -Fqi 'copy-based' "$file"; then
    fail "$file carries misleading copy-based wording"
  fi
done
for file in "$plugin_dir/bin/mutation-verify.sh" "$skill" "$plugin_dir/docs/commands.md" \
  "$plugin_dir/skills/running-the-peer-review-gate/references/peer-review-tiers.md"; do
  for wording in 'fresh copy of the original' 'unmutated copy' 'same mutated copy'; do
    if grep -Fqi "$wording" "$file"; then
      fail "$file carries misleading wording: $wording"
    fi
  done
done

for wording in 'CONTROL STAYED GREEN IN THE COPY' 'INCONCLUSIVE in copy mode' \
  'MUTATION_VERIFY_SWEEP_JOBS' '## mutation-sweep.sh'; do
  require "$plugin_dir/docs/commands.md" "$wording"
done

echo 'test-review-log-clauses.sh PASS'
