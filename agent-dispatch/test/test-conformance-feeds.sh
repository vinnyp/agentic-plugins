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
for stage in config records commits; do
  (
    _repo_state_pairs() {
      if [ "$1" = "$stage" ]; then
        if [ "$1" = config ]; then
          builtin printf 'local\tfixture\tcore.hookspath\told\tnew\n'
        elif [ "$1" = records ]; then
          builtin printf 'hooks\tfixture\told\tnew\n'
        fi
      elif [ "$stage" = commits ] && [ "$1" = records ]; then
        builtin printf 'ref\trefs/heads/fixture\told\tnew\n'
      fi
    }
    _repo_state_git() {
      case " $* " in
        *' cat-file '*) cat >/dev/null ;;
        *' rev-list '*) cat >/dev/null; builtin printf '%s\n' fixture-commit ;;
        *' --format=%cn '*) builtin printf '%s\n' fixture-name ;;
        *' --format=%ce '*) builtin printf '%s\n' fixture-email ;;
        *) return 1 ;;
      esac
    }
    # Prove the commit-history path is reachable before breaking its producer.
    if [ "$stage" = commits ]; then
      rc=0
      repo_state_compare_memory "$before" "$after" > /dev/null || rc=$?
      [ "$rc" = 2 ] || { echo 'FAIL: commit-history control did not detect drift'; exit 1; }
    fi
    printf() {
      case "${2:-}" in
        local$'\t'fixture$'\t'core.hookspath*|hooks$'\t'fixture*|fixture-commit) return 1 ;;
      esac
      builtin printf "$@"
    }
    rc=0
    repo_state_compare_memory "$before" "$after" >/dev/null || rc=$?
    [ "$rc" = 3 ] || { echo "FAIL: $stage feed failure returned $rc"; exit 1; }
  )
done
echo 'PASS conformance verdict feed failures'
