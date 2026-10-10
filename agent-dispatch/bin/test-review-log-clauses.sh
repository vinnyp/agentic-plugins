#!/usr/bin/env bash
set -euo pipefail

bin_dir=$(cd "$(dirname -- "$0")" && pwd -P)
plugin_dir=$(cd "$bin_dir/.." && pwd -P)
repo_dir=$(cd "$plugin_dir/.." && pwd -P)
skill=$plugin_dir/skills/running-the-peer-review-gate/SKILL.md
convention=$plugin_dir/skills/running-the-peer-review-gate/references/review-log-convention.md
prds=$repo_dir/operator-agents/skills/writing-prds/SKILL.md
agent_prds=$repo_dir/operator-agents/skills/writing-agent-prds/SKILL.md

fail() { echo "FAIL: $*" >&2; exit 1; }
require() {
  grep -Fq -- "$2" "$1" || fail "$1 lacks: $2"
}

require "$skill" 'review-log-status --archive <log-path>'
require "$skill" "Quote the CLI's"
require "$skill" 'first stdout word'
require "$skill" 'Completion checklist:'
require "$convention" 'Never claim the log was shipped without a'
require "$convention" '`committed` result from `review-log-status`'
for state in committed staged untracked ignored; do
  require "$convention" "- \`$state\`"
done
require "$prds" 'review-log-status'
require "$agent_prds" 'review-log-status'

for file in "$skill" "$convention" \
  "$plugin_dir/skills/running-the-peer-review-gate/references/peer-review-tiers.md" \
  "$plugin_dir/docs/peer-review-gate.md" "$plugin_dir/.claude-plugin/plugin.json"; do
  if grep -Fq 'Commit it to the caller repo' "$file" || grep -Fq 'durable review log' "$file"; then
    fail "$file carries superseded log wording"
  fi
done

echo 'test-review-log-clauses.sh PASS'
