# Bash can emit this harmless job-control race under load.
/^.*: child setpgid \([0-9]+ to [0-9]+\): Operation not permitted$/d
:again
s/(^|[^[:alnum:]_-])cd-[0-9]{14}-[0-9]+([^[:alnum:]_-]|$)/\1cd-<TS>-<PID>\2/g
s/(^|[^[:alnum:]_-])phase-([[:alnum:]_-]+)-[0-9]{14}-[0-9]+([^[:alnum:]_-]|$)/\1phase-\2-<TS>-<PID>\3/g
s/(^|[[:space:]])pid=[0-9]+([[:space:]]|$)/\1pid=<PID>\2/g
s/(^|[[:space:]])pinned_at=[0-9]+([[:space:]]|$)/\1pinned_at=<TS>\2/g
s/(^|[[:space:]])elapsed=[0-9]+(\.[0-9]+)?s([[:space:]]|$)/\1elapsed=<ELAPSED>\3/g
# dispatch-worker's own mktemp review file, including BSD's longer suffix.
s@^(REVIEW_OUTFILE=)(/[^[:space:]]*/|<SCN_TMP>/([^[:space:]]*/)?)dispatch-review\.(XXXXXX\.)?[[:alnum:]]{6,}(\.md)?( \(rc=)@\1<REVIEW_TMP>\6@
# Both coding entrypoints hash the absolute repo path into this namespace.
s@(\/\.worktrees\/[[:alnum:]_-]+)_[[:xdigit:]]{8}(/|$)@\1_<HASH>\2@g

# Review worktree scratch directory names.
s@(^|[^[:alnum:]_.-])dispatch-review-wt\.(XXXXXX\.)?[[:alnum:]]{6,}([^[:alnum:]_-]|$)@\1dispatch-review-wt.<TMP>\3@g

s@^(repo_?)_[[:xdigit:]]{8}(/|$)@\1_<HASH>\2@
t again
