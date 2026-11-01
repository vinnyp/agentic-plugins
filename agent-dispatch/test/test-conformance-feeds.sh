#!/usr/bin/env bash
# Verdict producers that cannot feed a consumer must fail closed.
set -eu
here=$(CDPATH='' cd "$(dirname "$0")" && pwd -P)
# shellcheck source=agent-dispatch/bin/lib/repo-state.sh
. "$here/../bin/lib/repo-state.sh"
before=$(builtin printf 'repo\tfixture\nconfig\tlocal\tfile:fixture\tcore.hookspath\told\n')
after=$(builtin printf 'repo\tfixture\nconfig\tlocal\tfile:fixture\tcore.hookspath\tnew\n')
rc=0
repo_state_compare_memory "$before" "$after" >/dev/null || rc=$?
[ "$rc" = 2 ] || { echo 'FAIL: control did not detect drift'; exit 1; }
# case: verdict-feed-failure
for stage in config records; do
  (
    _repo_state_pairs() {
      if [ "$1" = "$stage" ]; then
        if [ "$1" = config ]; then
          builtin printf 'local\tfixture\tcore.hookspath\told\tnew\n'
        else
          builtin printf 'hooks\tfixture\told\tnew\n'
        fi
      fi
    }
    printf() {
      case "${2:-}" in
        local$'\t'fixture$'\t'core.hookspath*|hooks$'\t'fixture*) return 1 ;;
      esac
      builtin printf "$@"
    }
    rc=0
    repo_state_compare_memory "$before" "$after" >/dev/null || rc=$?
    [ "$rc" = 3 ] || { echo "FAIL: $stage feed failure returned $rc"; exit 1; }
  )
done
echo 'PASS conformance verdict feed failures'
