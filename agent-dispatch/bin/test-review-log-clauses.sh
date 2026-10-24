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

echo 'test-review-log-clauses.sh PASS'
