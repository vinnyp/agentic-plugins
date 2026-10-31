#!/usr/bin/env bash
# Sourceable repository config snapshots. No caller shell options are changed.
[ -r "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portable-stat.sh" ] || {
  echo "repo-state.sh: broken install: portable-stat.sh not readable" >&2
  return 2 2>/dev/null || exit 2
}
# shellcheck source=portable-stat.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portable-stat.sh"
_REPO_STATE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/repo-state.sh"
# Cancel state belongs to one invocation: never inherit it, never export it.
unset REPO_STATE_BOUND_PID REPO_STATE_BOUND_WATCHDOG REPO_STATE_BOUND_PRIVATE
REPO_STATE_BOUND_PID='' REPO_STATE_BOUND_WATCHDOG='' REPO_STATE_BOUND_PRIVATE=''
unset REPO_STATE_BOUND_SAVE7 REPO_STATE_BOUND_SAVE8 REPO_STATE_BOUND_CHANNEL_ACTIVE

_repo_state_git() (
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_PREFIX
  # Git supplies the whitespace-separated names of its repository-local variables.
  # shellcheck disable=SC2046
  unset $(git rev-parse --local-env-vars 2>/dev/null)
  export GIT_OPTIONAL_LOCKS=0
  if [ "${1:-}" = --history ]; then
    shift
    export GIT_GRAFT_FILE=/dev/null GIT_NO_REPLACE_OBJECTS=1
    git --no-replace-objects -c core.commitGraph=false "$@"
  else
    git "$@"
  fi
)

_repo_state_sha256() (
  set -o pipefail
  local digest input
  # Retain bytes in memory so a failed primary hash can retry the same input.
  # Base64 preserves binary hook content and trailing newlines in shell memory.
  input=$(base64) || return 1
  if ! command -v shasum >/dev/null 2>&1 || ! digest=$(printf '%s' "$input" | base64 -d | shasum -a 256); then
    digest=$(printf '%s' "$input" | base64 -d | sha256sum) || return 1
  fi
  digest=${digest%% *}
  [ -n "$digest" ] || return 1
  printf '%s\n' "$digest"
)

repo_state_digest() {
  _repo_state_sha256
}

_repo_state_encode() {
  local value=$1
  value=${value//%/%25}
  value=${value//$'\t'/%09}
  value=${value//$'\n'/%0A}
  printf '%s' "$value"
}

_repo_state_configs() {
  local scope origin kv key value lower prefix rest userinfo digest
  while IFS= read -r -d '' scope || [ -n "$scope" ]; do
    IFS= read -r -d '' origin && IFS= read -r -d '' kv || return 3
    case "$kv" in
      *$'\n'*) key=${kv%%$'\n'*}; value=${kv#*$'\n'} ;;
      *) key=$kv; value='(novalue)' ;;
    esac
    lower=$(printf '%s' "$key" | LC_ALL=C tr '[:upper:]' '[:lower:]') || return 3
    case "${lower%%.*}" in
      credential|*extraheader*|*token*|*pass*|*secret*|*proxy*) lower=extraheader ;;
      *) lower=${lower##*.} ;;
    esac
    case "$lower" in
      *extraheader*|*token*|*pass*|*secret*|*proxy*)
        digest=$(printf '%s' "$value" | _repo_state_sha256) || return 1
        value="sha256:$digest" ;;
      *)
        if [[ "$value" =~ //.*@ ]]; then
          digest=$(printf '%s' "$value" | _repo_state_sha256) || return 1
          value="sha256:$digest"
        fi ;;
    esac
    # Hash URL userinfo in keys while preserving distinct credentialed keys.
    # A slash in a password is malformed URL syntax, but still sensitive.
    # Conservatively hash through the last @ even in that malformed shape.
    if [[ "$key" =~ //.*@ ]] && ! [[ "$key" =~ //[^/]*@ ]]; then
      digest=$(printf '%s%s' "$REPO_STATE_SALT" "$key" | _repo_state_sha256) || return 1
      key="redacted.${digest:0:12}"
    fi
    rest=$key
    key=''
    while [[ "$rest" =~ (//)([^/]*)@ ]]; do
      prefix=${rest%%"${BASH_REMATCH[0]}"*}
      userinfo=${BASH_REMATCH[2]}
      digest=$(printf '%s%s' "$REPO_STATE_SALT" "$userinfo" | _repo_state_sha256) || return 1
      key="$key$prefix${BASH_REMATCH[1]}${digest:0:12}@"
      rest=${rest#*"${BASH_REMATCH[0]}"}
    done
    key="$key$rest"
    # An earlier malformed authority may precede a later well-formed one.
    if [[ "$key" =~ //[^@]*/[^@]*@ ]]; then
      digest=$(printf '%s%s' "$REPO_STATE_SALT" "$key" | _repo_state_sha256) || return 1
      key="redacted.${digest:0:12}"
    fi
    printf 'config\t%s\t%s\t%s\t%s\n' "$(_repo_state_encode "$scope")" \
      "$(_repo_state_encode "$origin")" "$(_repo_state_encode "$key")" "$(_repo_state_encode "$value")"
  done
}

_repo_state_decode() {
  local value=$1
  value=${value//%0A/$'\n'}
  value=${value//%09/$'\t'}
  printf '%s' "${value//%25/%}"
}

_repo_state_hooks() {
  local dir=$1 prefix=$2 file mode digest target content
  [ -d "$dir" ] || return 0
  for file in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    if [ -L "$file" ]; then
      [ ! -d "$file" ] || continue
      target=$(readlink "$file" || exit 1; printf '.') || return 3
      target=${target%.}
      target=${target%$'\n'}
      content=dangling
      if [ -f "$file" ]; then
        content=$(_repo_state_sha256 < "$file") || return 3
      fi
      if [ -x "$file" ]; then mode=link-exec; else mode=link-noexec; fi
      digest=$(printf '%s\0%s\0%s' "$target" "$content" "$mode" | _repo_state_sha256) || return 3
    else
      [ -f "$file" ] || continue
      mode=$(pstat_mode "$file") || return 3
      digest=$(_repo_state_sha256 < "$file") || return 3
    fi
    printf 'hooks\t%s\t%s\t%s\n' "$(_repo_state_encode "$prefix${file##*/}")" "$mode" "$digest"
  done
}

_repo_state_dirty() {
  local wt=$1 record path skip
  while IFS= read -r -d '' record; do
    case "$record" in
      '1 '*) skip=8 ;; '2 '*) skip=9 ;; 'u '*) skip=10 ;;
      '? '*) skip=1 ;; *) continue ;;
    esac
    path=$record
    while [ "$skip" -gt 0 ]; do path=${path#* }; skip=$((skip - 1)); done
    printf 'dirty\t%s\t%s\n' "$(_repo_state_encode "$wt")" "$(_repo_state_encode "$path")" || return 3
    case "$record" in '2 '*) IFS= read -r -d '' path || return 3 ;; esac
  done
}

_repo_state_tree() (
  set -o pipefail
  local wt=$1 status digest dirty
  if [ "${metadata_unsafe:-0}" = 1 ] || [ ! -d "$wt" ] ||
     ! status=$(_repo_state_git -C "$wt" -c core.fsmonitor=false status --porcelain=v2 -z --untracked-files=all 2>/dev/null | base64); then
    printf 'tree\t%s\tunreadable\n' "$(_repo_state_encode "$wt")"
    return
  fi
  digest=$(printf '%s' "$status" | base64 -d | _repo_state_sha256) || return 3
  dirty=$(printf '%s' "$status" | base64 -d | _repo_state_dirty "$wt") || return 3
  printf 'tree\t%s\t%s\n' "$(_repo_state_encode "$wt")" "$digest"
  [ -z "$dirty" ] || printf '%s\n' "$dirty"
)

# Inspect metadata without opening the special files themselves.
_repo_state_nonregular_text() (
  set -o pipefail
  local dir existing duplicate
  local dirs=()
  for dir in "$@"; do
    duplicate=0
    for existing in ${dirs[@]+"${dirs[@]}"}; do
      [ "$existing" != "$dir" ] || duplicate=1
    done
    [ "$duplicate" = 0 ] || continue
    dirs[${#dirs[@]}]=$dir
  done
  [ "${#dirs[@]}" -gt 0 ] || return 0
  find -P "${dirs[@]}" \( -type p -o -type c -o -type b -o -type s \) -print0 |
    while IFS= read -r -d '' file; do
      printf 'unsafe\t%s\n' "$(_repo_state_encode "$file")" || exit 3
    done
)

repo_state_nonregular_sweep_memory() {
  local result=0
  REPO_STATE_BOUND_OUT=$(_repo_state_nonregular_text "$@"; result=$?; printf x; exit "$result") || result=3
  REPO_STATE_BOUND_OUT=${REPO_STATE_BOUND_OUT%x}
  return "$result"
}

repo_state_nonregular_sweep() {
  local out=$1 result=0
  shift
  repo_state_nonregular_sweep_memory "$@" || result=$?
  (umask 077; printf '%s' "$REPO_STATE_BOUND_OUT" > "$out" && chmod 600 "$out") || return 3
  return "$result"
}

_repo_state_worktree_configs() (
  local pipe
  _repo_state_git -C "$1" config --list --show-scope --show-origin -z --worktree 2>/dev/null | _repo_state_configs
  pipe=("${PIPESTATUS[@]}")
  [ "${pipe[1]}" = 0 ] || return 3
  case "${pipe[0]}" in 0|128) return 0 ;; *) return 3 ;; esac
)

# File callers explicitly supply the directory holding their shared private salt.
_repo_state_salt() {
  local saltfile=$1/salt
  [ -z "${REPO_STATE_SALT:-}" ] || return 0
  [ -n "$1" ] || return 3
  (umask 077; mkdir -p "$1" && chmod 700 "$1") || return 3
  if [ ! -f "$saltfile" ]; then
    (set -o pipefail; set -C; od -An -tx1 -N16 /dev/urandom | tr -d ' \n' > "$saltfile") || return 3
  fi
  REPO_STATE_SALT=$(cat "$saltfile") || return 3
  [ -n "$REPO_STATE_SALT" ]
}

repo_state_snapshot_memory() {
  local result=0 REPO_STATE_SALT=${REPO_STATE_SALT:-}
  _repo_state_salt "${2:-}" || return 3
  REPO_STATE_BOUND_OUT=$(_repo_state_snapshot_text "$1"; result=$?; printf x; exit "$result") || result=$?
  REPO_STATE_BOUND_OUT=${REPO_STATE_BOUND_OUT%x}
  return "$result"
}

repo_state_snapshot() {
  local result=0
  repo_state_snapshot_memory "$1" "$(dirname "$2")/.repo-state-private" || result=$?
  (umask 077; printf '%s' "$REPO_STATE_BOUND_OUT" > "$2" && chmod 600 "$2") || return 3
  return "$result"
}

_repo_state_snapshot_text() (
  set -o pipefail
  umask 077
  local repo=${1:-} top ident name email config refs wt hooks custom head branch record unsafe worktrees
  _repo_state_sha256 </dev/null >/dev/null || return 3
  case "$repo" in /*) ;; *) return 3 ;; esac
  local path file digest target kind metadata_unsafe=0 common gitdir
  common=${REVIEW_GIT_COMMON_DIR:-}
  gitdir=${REVIEW_GIT_DIR:-}
  if [ -z "$common" ] || [ -z "$gitdir" ]; then
    common=$(_repo_state_git -C "$repo" rev-parse --path-format=absolute --git-common-dir) || return 3
    gitdir=$(_repo_state_git -C "$repo" rev-parse --absolute-git-dir) || return 3
  fi
  repo_state_nonregular_sweep_memory "$common" "$gitdir" || return 3
  unsafe=$REPO_STATE_BOUND_OUT
  [ -z "$unsafe" ] || metadata_unsafe=1
  top=$(_repo_state_git -C "$repo" rev-parse --path-format=absolute --show-toplevel 2>/dev/null) || return 3
  config=$(_repo_state_git -C "$repo" config --list --show-scope --show-origin -z | _repo_state_configs) || return 3
  refs=$(_repo_state_git -C "$repo" for-each-ref --format='ref%09%(refname)%09%(objectname)') || return 3
  worktrees=$(_repo_state_git -C "$repo" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || return 3
  {
    printf 'repo\t%s\n' "$(_repo_state_encode "$top")"
    ident=$(_repo_state_git -C "$repo" var GIT_COMMITTER_IDENT 2>/dev/null) || ident=''
    ident=${ident% *}; ident=${ident% *}
    name=${ident% <*}; email=${ident##*<}; email=${email%>}
    printf 'identity\t%s\t%s\n' "$(_repo_state_encode "$name")" "$(_repo_state_encode "$email")"
    [ -z "$refs" ] || printf '%s\n' "$refs"
    hooks="$common/hooks"
    _repo_state_hooks "$hooks" '' || return 3
    custom=$(_repo_state_git -C "$repo" rev-parse --path-format=absolute --git-path hooks) || return 3
    if [ "$custom" != "$hooks" ]; then _repo_state_hooks "$custom" 'core.hooksPath/' || return 3; fi
    [ -z "$unsafe" ] || printf '%s\n' "$unsafe"
    for path in info/exclude info/attributes objects/info/alternates info/grafts shallow; do
      file="$common/$path"
      digest='(absent)'
      if [ -L "$file" ]; then
        target=$(readlink "$file") || return 3
        digest="link:$target"
        if [ -f "$file" ]; then
          digest="$digest:$(_repo_state_sha256 < "$file")" || return 3
        else
          metadata_unsafe=1
        fi
      elif [ -f "$file" ]; then
        digest=$(_repo_state_sha256 < "$file") || return 3
      elif [ -e "$file" ]; then
        kind=$(stat -f '%HT' "$file" 2>/dev/null) || kind=$(stat -c '%F' "$file") || return 3
        digest="nonregular:$kind"
        metadata_unsafe=1
      fi
      digest=$(_repo_state_encode "$digest")
      printf 'metadata\t%s\t%s\n' "$path" "$digest"
    done
    wt='' head='' branch=''
    printf '%s\n\n' "$worktrees" | while IFS= read -r record || [ -n "$record" ]; do
      case "$record" in
        'worktree '*) wt=${record#worktree } ;;
        'HEAD '*) head=${record#HEAD } ;;
        'branch '*) branch=${record#branch } ;;
        '')
          [ -n "$wt" ] || continue
          printf 'worktree\t%s\t%s\t%s\n' "$(_repo_state_encode "$wt")" "$head" "$branch"
          _repo_state_tree "$wt" || return 3
          wt='' head='' branch='' ;;
      esac
    done || return 3
    [ -z "$config" ] || printf '%s\n' "$config"
    printf '%s\n' "$worktrees" | while IFS= read -r wt; do
      case "$wt" in 'worktree '*) wt=${wt#worktree } ;; *) continue ;; esac
      [ "$wt" != "$top" ] && [ -d "$wt" ] || continue
      _repo_state_worktree_configs "$wt" || return 3
    done || return 3
  }

  return 0
)

repo_state_mark_unreadable() (
  umask 077
  printf 'unreadable\n' > "$1"
  chmod 600 "$1"
)

_repo_state_display() {
  local key=$1 value
  value=$(_repo_state_decode "$2")
  if [ "$value" = '(absent)' ]; then printf '%s' "$value"; return; fi
  case "$key" in
    core.editor|core.pager|core.fsmonitor)
      if [[ "$value" =~ ^[[:space:]]*([^[:space:]]+)([[:space:]]+.*)?$ ]]; then
        value=${BASH_REMATCH[1]}${BASH_REMATCH[2]:+…}
      fi ;;
    core.hookspath) case "$value" in true|false|/*) ;; *) value='<changed>' ;; esac ;;
    core.*) case "$value" in true|false) ;; *) value='<changed>' ;; esac ;;
    commit.gpgsign|tag.gpgsign) ;;
    *) value='<changed>' ;;
  esac
  value=$(printf '%s' "$value" | sed -E 's#(//)[^/]*@#\1#g; s#[?].*#?<redacted>#')
  _repo_state_escape_value "$value"
}

# Record that compare could not finish; every caller then returns 3.
_repo_state_compare_failed() {
  printf 'state: compare could not complete (%s failed)\n' "$1"
}

# Run an awk "found" probe: 0 found, 1 not found, 3 for any other status.
_repo_state_found() {
  local status=0
  awk "$@" || status=$?
  [ "$status" -le 1 ] || return 3
  return "$status"
}

# A failed producer is an input error, never an awk "not found" result.
_repo_state_probe() (
  set -o pipefail
  local text=$1
  local statuses=()
  shift
  printf '%s\n' "$text" | _repo_state_found "$@"
  statuses=("${PIPESTATUS[@]}")
  [ "${statuses[0]}" = 0 ] || return 3
  return "${statuses[1]}"
)

# A tagged stream makes input identity independent of filenames and empty passes.
_repo_state_tagged() (
  set -o pipefail
  local line tag text
  for tag in O N; do
    if [ "$tag" = O ]; then text=$1; else text=$2; fi
    [ -n "$text" ] || continue
    printf '%s\n' "$text" | while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      printf '%s\t%s\n' "$tag" "$line" || return 1
    done || return 3
  done
)

_repo_state_pairs() (
  set -o pipefail
  _repo_state_tagged "$2" "$3" | LC_ALL=C awk -F '\t' -v mode="$1" '
    mode=="config" && $2!="config" {next}
    mode!="config" && $2!="metadata" && $2!="hooks" && $2!="ref" && $2!="worktree" && $2!="tree" {next}
    {
      tag=$1; line=$2; for(i=3;i<=NF;i++) line=line FS $i
      if(!(line in seen)) {seen[line]=1; order[++n]=line}
      if(tag=="O") no[line]++; else nn[line]++
    }
    END {
      for(j=1;j<=n;j++) {
        line=order[j]; delta=no[line]-nn[line]; split(line,f,FS)
        if(mode=="config") {k=f[2] FS f[3] FS f[4]; v=f[5]}
        else {k=f[1] FS f[2]; v=f[3]; for(i=4;i<=split(line,f,FS);i++) v=v " " f[i]}
        if(!(k in keys)) {keys[k]=1; ks[++nk]=k}
        while(delta>0) {old[k,++oc[k]]=v; delta--}
        while(delta<0) {newer[k,++nc[k]]=v; delta++}
      }
      for(j=1;j<=nk;j++) {
        k=ks[j]; nmax=oc[k]>nc[k]?oc[k]:nc[k]
        for(i=1;i<=nmax;i++) print k FS (i<=oc[k]?old[k,i]:"(absent)") FS (i<=nc[k]?newer[k,i]:"(absent)")
      }
    }'
)

repo_state_compare_memory() {
  local result=0 text
  text=$(_repo_state_compare_text "$@"; result=$?; printf x; exit "$result") || result=$?
  text=${text%x}
  REPO_STATE_BOUND_OUT=$(printf '%s' "$text" | _repo_state_escape_output; result=$?; printf x; exit "$result") || {
    REPO_STATE_BOUND_OUT=$'state: compare could not complete (escape failed)\n'
    return 3
  }
  REPO_STATE_BOUND_OUT=${REPO_STATE_BOUND_OUT%x}
  return "$result"
}

# Read an input exactly once, preserving trailing newlines. FIFOs are valid inputs.
_repo_state_read_file() (
  set -o pipefail
  local encoded bytes
  local LC_ALL=C
  [ -r "$1" ] && [ ! -d "$1" ] || return 1
  encoded=$(base64 < "$1") || return 1
  bytes=$(printf '%s' "$encoded" | base64 -d | wc -c) || return 1
  REPO_STATE_READ=$(printf '%s' "$encoded" | base64 -d || exit 1; printf x) || return 1
  REPO_STATE_READ=${REPO_STATE_READ%x}
  [ "$bytes" -eq "${#REPO_STATE_READ}" ] || return 1
  printf '%s' "$REPO_STATE_READ"
)

repo_state_compare_files() {
  local before after result=0
  if ! before=$(_repo_state_read_file "$1"; result=$?; printf x; exit "$result"); then
    REPO_STATE_BOUND_OUT=$'state: <unreadable before snapshot>\n'; result=3
  else
    before=${before%x}
    if ! after=$(_repo_state_read_file "$2"; result=$?; printf x; exit "$result"); then
      REPO_STATE_BOUND_OUT=$'config: <unreadable after review>\n'; result=2
    else
      after=${after%x}
      repo_state_compare_memory "$before" "$after" || result=$?
    fi
  fi
  return "$result"
}

repo_state_compare() {
  local result=0
  repo_state_compare_files "$1" "$2" || result=$?
  printf '%s' "$REPO_STATE_BOUND_OUT" > "$3" || return 3
  return "$result"
}

_repo_state_compare_text() (
  set -o pipefail
  local before=$1 after=$2 first='' scope origin key old new rc=0 remote line found
  local feed_status=()
  local diff records exclude='' exclude_ready=0 commits dirty
  case "${before%%$'\n'*}" in repo$'\t'*|unreadable) ;; *) printf 'state: invalid before snapshot\n'; return 3 ;; esac
  case "${after%%$'\n'*}" in repo$'\t'*|unreadable) ;; *) printf 'state: invalid after snapshot\n'; return 2 ;; esac
  found=0
  _repo_state_probe "$before" -F '\t' '$1=="unsafe" {found=1} END {exit !found}' || found=$?
  [ "$found" -le 1 ] || { _repo_state_compare_failed awk; return 3; }
  if [ "$found" = 0 ]; then
    printf '%s\n' "$before" | while IFS=$'\t' read -r kind key; do
      [ "$kind" = unsafe ] || continue
      printf 'nonregular %s: critical\n' "$(_repo_state_escape_value "$(_repo_state_decode "$key")")"
    done || { _repo_state_compare_failed feed; return 3; }
    return 2
  fi
  first=${before%%$'\n'*}
  if [ "$first" = unreadable ]; then
    printf 'state: <unreadable before snapshot>\n'
    return 3
  fi
  first=${after%%$'\n'*}
  if [ "$first" = unreadable ]; then
    printf '%s\n' "$after" | while IFS=$'\t' read -r kind key; do
      [ "$kind" = unsafe ] || continue
      printf 'nonregular %s: critical\n' "$(_repo_state_escape_value "$(_repo_state_decode "$key")")"
    done || { _repo_state_compare_failed feed; return 3; }
    printf 'config: <unreadable after review>\n'
    return 2
  fi
  diff=$(_repo_state_pairs config "$before" "$after") || { _repo_state_compare_failed awk; return 3; }
  rc=0
  if printf '%s\n' "$diff" | { while IFS= read -r line; do
    scope=${line%%$'\t'*}; line=${line#*$'\t'}
    origin=${line%%$'\t'*}; line=${line#*$'\t'}
    key=${line%%$'\t'*}; line=${line#*$'\t'}
    old=${line%%$'\t'*}; new=${line#*$'\t'}
    [ -n "$key" ] || continue
    [ "$rc" -ge 1 ] || rc=1
    case "$key" in
      branch.*.pushremote) rc=2 ;;
      branch.*.remote)
        remote=$(_repo_state_decode "$new")
        if [ "$remote" = . ]; then
          found=0
          REPO_STATE_MERGE="${key%.remote}.merge" _repo_state_probe "$diff" -F '\t' '$3==ENVIRON["REPO_STATE_MERGE"] {found=1} END {exit !found}' || found=$?
          case "$found" in 0) rc=2 ;; 1) ;; *) _repo_state_compare_failed awk; return 3 ;; esac
        fi
        # Local repository sentinel and pre-existing remote names are benign.
        if [ "$remote" != . ] && [ "$new" != '(absent)' ]; then
          found=0
          REPO_STATE_REMOTE="$remote" _repo_state_probe "$before" -F '\t' '$1=="config" && $4 ~ /^remote\./ {name=$4; sub(/^remote\./,"",name); sub(/\.[^.]*$/,"",name); if(name==ENVIRON["REPO_STATE_REMOTE"]) found=1} END {exit !found}' || found=$?
          case "$found" in 0) ;; 1) rc=2 ;; *) _repo_state_compare_failed awk; return 3 ;; esac
        fi ;;
      branch.*.*|remote.*.fetch|remote.*.gh-resolved|gc.*|maintenance.*|extensions.worktreeconfig|core.sparsecheckout|core.sparsecheckoutcone) ;;
      remote.*.*)
        remote=${key#remote.}; remote=${remote%.*}
        found=0
        REPO_STATE_REMOTE="$remote" _repo_state_probe "$before" -F '\t' '$1=="config" && $4 ~ /^remote\./ {name=$4; sub(/^remote\./,"",name); sub(/\.[^.]*$/,"",name); if(name==ENVIRON["REPO_STATE_REMOTE"]) found=1} END {exit !found}' || found=$?
        case "$found" in
          0) rc=2 ;;
          1) case "$key" in remote.*.url) ;; *) rc=2 ;; esac ;;
          *) _repo_state_compare_failed awk; return 3 ;;
        esac ;;
      *) rc=2 ;;
    esac
    printf 'config %s (%s:%s): %s -> %s\n' \
      "$(printf '%s' "$key" | sed -E 's#(//)[^/]*@#\1#g; s#[?].*#?<redacted>#')" "$scope" "$origin" \
      "$(_repo_state_display "$key" "$old")" "$(_repo_state_display "$key" "$new")"
  done; exit "$rc"; }; then
    feed_status=("${PIPESTATUS[@]}")
  else
    feed_status=("${PIPESTATUS[@]}")
  fi
  [ "${feed_status[0]}" = 0 ] || { _repo_state_compare_failed feed; return 3; }
  rc=${feed_status[1]}
  [ "$rc" -le 2 ] || { _repo_state_compare_failed feed; return 3; }
  records=$(_repo_state_pairs records "$before" "$after") || { _repo_state_compare_failed awk; return 3; }
  local kind repo sha cn ce identity_name identity_email count paths
  repo=$( ( printf '%s\n' "$after" || exit 3 ) | awk -F '\t' '$1=="repo" {if(!seen++) print $2}') || { _repo_state_compare_failed awk; return 3; }
  repo=$(_repo_state_decode "$repo")
  identity_name=$( ( printf '%s\n' "$before" || exit 3 ) | awk -F '\t' '$1=="identity" {if(!seen++) print $2}') || { _repo_state_compare_failed awk; return 3; }
  identity_email=$( ( printf '%s\n' "$before" || exit 3 ) | awk -F '\t' '$1=="identity" {if(!seen++) print $3}') || { _repo_state_compare_failed awk; return 3; }
  local unsafe=0
  printf '%s\n' "$after" | while IFS=$'\t' read -r kind key; do
    [ "$kind" = unsafe ] || continue
    printf 'nonregular %s: critical\n' "$(_repo_state_escape_value "$(_repo_state_decode "$key")")"
  done || { _repo_state_compare_failed feed; return 3; }
  found=0
  _repo_state_probe "$after" -F '\t' '$1=="unsafe" {found=1} END {exit !found}' || found=$?
  case "$found" in 0) unsafe=1; rc=2 ;; 1) ;; *) _repo_state_compare_failed awk; return 3 ;; esac
  if printf '%s\n' "$records" | { while IFS=$'\t' read -r kind key old new remote line; do
    [ -n "$kind" ] || continue
    [ "$rc" -ge 1 ] || rc=1
    case "$kind" in
      metadata)
        case "$key" in objects/info/alternates|info/grafts|shallow) rc=2 ;; esac
        printf 'metadata %s: <changed>\n' "$key" ;;
      hooks)
        rc=2
        if [ "$old" = '(absent)' ]; then line=added
        elif [ "$new" = '(absent)' ]; then line=removed
        else line=changed; fi
        printf 'hooks %s: %s\n' "$key" "$line" ;;
      ref)
        printf 'ref %s: %s -> %s\n' "$key" "$old" "$new"
        case "$key" in
          refs/replace/*) rc=2 ;;
          refs/heads/*)
          [ "$unsafe" = 0 ] || continue
          if [ "$exclude_ready" = 0 ]; then
            exclude=$(
              { ( printf '%s\n' "$before" || exit 3 ) | awk -F '\t' '$1=="ref" {print $3}' || exit 1
                ( printf '%s\n' "$after" || exit 3 ) | awk -F '\t' '$1=="ref" && $2 ~ /^refs\/remotes\// {print $3}'; } |
                _repo_state_git -C "$repo" cat-file --batch-check='%(objectname) %(objecttype)' 2>/dev/null |
                awk '($2=="commit" || $2=="tag") {print "^" $1}'
            ) || { _repo_state_compare_failed commit-input; return 3; }
            exclude_ready=1
          fi
          [ "$new" != '(absent)' ] || continue
          if ! commits=$(printf '%s\n' "$exclude" | _repo_state_git --history -C "$repo" rev-list --stdin "$new" 2>/dev/null); then
            printf 'commit-check %s: failed\n' "$key"; rc=2; continue
          fi
          if printf '%s\n' "$commits" | { while IFS= read -r sha; do
            [ -n "$sha" ] || continue
            cn=$(_repo_state_git --history -C "$repo" show -s --format=%cn "$sha") || return 3
            ce=$(_repo_state_git --history -C "$repo" show -s --format=%ce "$sha") || return 3
            if [ "$(_repo_state_encode "$cn")" != "$identity_name" ] || [ "$(_repo_state_encode "$ce")" != "$identity_email" ]; then
              printf 'commit %s: committer <changed>\n' "$sha"; rc=2
            fi
          done; exit "$rc"; }; then
            feed_status=("${PIPESTATUS[@]}")
          else
            feed_status=("${PIPESTATUS[@]}")
          fi
          [ "${feed_status[0]}" = 0 ] || return 3
          rc=${feed_status[1]}
          [ "$rc" -le 2 ] || return 3 ;;
        esac ;;
      worktree)
        [ "$old" = '(absent)' ] || old="HEAD $old"
        [ "$new" = '(absent)' ] || new="HEAD $new"
        printf 'worktree %s: %s -> %s\n' "$key" "$old" "$new" ;;
      tree)
        if [ "$old" = '(absent)' ]; then
          printf 'tree %s: worktree added\n' "$key"
        elif [ "$new" = '(absent)' ]; then
          printf 'tree %s: worktree removed\n' "$key"
        elif [ "$new" = unreadable ]; then
          printf 'tree %s: unreadable\n' "$key"
        else
          dirty=$(_repo_state_tagged "$before" "$after" |
            REPO_STATE_WT="$key" awk -F '\t' '$2=="dirty" && $3==ENVIRON["REPO_STATE_WT"] {if($1=="O") old[$4]=1; else newer[$4]=1} END {for(p in newer) if(!(p in old)) print p}' |
            LC_ALL=C sort) || { _repo_state_compare_failed dirty; return 3; }
          paths=$(printf '%s\n' "$dirty" | awk 'length($0) {n++; if(n<=20) paths=paths (n>1?" ":"") $0} END {print n+0; print paths}') || return 3
          count=${paths%%$'\n'*}; paths=${paths#*$'\n'}
          if [ "$count" = 0 ]; then
            printf 'tree %s: status changed (no new dirty paths)\n' "$key"
          else
            printf 'tree %s: %s new dirty paths: %s\n' "$key" "$count" "$paths"
          fi
        fi ;;
    esac
  done; exit "$rc"; }; then
    feed_status=("${PIPESTATUS[@]}")
  else
    feed_status=("${PIPESTATUS[@]}")
  fi
  [ "${feed_status[0]}" = 0 ] || { _repo_state_compare_failed feed; return 3; }
  rc=${feed_status[1]}
  [ "$rc" -le 2 ] || { _repo_state_compare_failed feed; return 3; }
  found=0
  _repo_state_probe "$before" -F '\t' '$1=="tree" && $3=="unreadable" {found=1} END {exit !found}' || found=$?
  case "$found" in
    0)
      printf 'tree check skipped: baseline unreadable\n'
      [ "$rc" -ge 1 ] || rc=1 ;;
    1) ;;
    *) _repo_state_compare_failed awk; return 3 ;;
  esac
  return "$rc"
)

_repo_state_escape_output() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    _repo_state_escape_value "$line" || return 3
    printf '\n'
  done
}

_repo_state_escape_value() {
  if command -v perl >/dev/null 2>&1; then
    printf '%s' "$1" | LC_ALL=C perl -pe 's/([\x00-\x1f\x7f]|\xc2[\x80-\x9f])/join "", map { sprintf "\\x%02x", ord $_ } split \/\/, $1/ge'
    return
  fi
  local value=$1 char code i
  local LC_ALL=C
  for ((i=0; i<${#value}; i++)); do
    char=${value:i:1}
    printf -v code '%d' "'$char"
    code=$((code & 255))
    if [ "$code" -eq 194 ] && [ "$((i + 1))" -lt "${#value}" ]; then
      printf -v code '%d' "'${value:i+1:1}"
      code=$((code & 255))
      if [ "$code" -ge 128 ] && [ "$code" -le 159 ]; then
        printf '\\xc2\\x%02x' "$code"
        i=$((i + 1)); continue
      fi
      code=194
    fi
    if [ "$code" -lt 32 ] || [ "$code" -eq 127 ]; then
      printf '\\x%02x' "$code"
    else
      printf '%s' "$char"
    fi
  done
}

# Validate before arithmetic: long values must never overflow or disable timeout.
repo_state_snapshot_limit() {
  local caller=$1 default=$2 variable=${3:-DISPATCH_SNAPSHOT_TIMEOUT_SECS} value
  value=${!variable-$default}
  if [[ "$value" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$value))" -ge 1 ] && [ "$((10#$value))" -le 86400 ]; then
    printf '%s\n' "$((10#$value))"
  else
    printf '%s: invalid %s; using %s\n' "$caller" "$variable" "$default" >&2
    printf '%s\n' "$default"
  fi
}

# Cancel only process groups and storage recorded by this invocation.
repo_state_cancel_bound() {
  if [ -n "${REPO_STATE_BOUND_PID:-}" ]; then
    kill -TERM -- "-$REPO_STATE_BOUND_PID" 2>/dev/null || true
  fi
  if [ -n "${REPO_STATE_BOUND_WATCHDOG:-}" ]; then
    kill -TERM -- "-$REPO_STATE_BOUND_WATCHDOG" 2>/dev/null || true
    wait "$REPO_STATE_BOUND_WATCHDOG" 2>/dev/null || true
    kill -KILL -- "-$REPO_STATE_BOUND_WATCHDOG" 2>/dev/null || true
  fi
  _repo_state_close_channel
  [ -z "${REPO_STATE_BOUND_PRIVATE:-}" ] || rm -rf "$REPO_STATE_BOUND_PRIVATE"
}

# Save inherited descriptors to unused high descriptors before opening the channel.
_repo_state_save_channel() {
  local fd candidate saved
  REPO_STATE_BOUND_SAVE7='' REPO_STATE_BOUND_SAVE8=''
  REPO_STATE_BOUND_CHANNEL_ACTIVE=0
  for fd in 7 8; do
    if ( : >&"$fd" ) 2>/dev/null; then
      saved=''
      for ((candidate=10; candidate<60; candidate++)); do
        if ! ( : >&"$candidate" ) 2>/dev/null; then
          if eval "exec $candidate>&$fd"; then saved=$candidate; break; fi
        fi
      done
      if [ -z "$saved" ]; then
        for saved in "$REPO_STATE_BOUND_SAVE7" "$REPO_STATE_BOUND_SAVE8"; do
          [ -z "$saved" ] || eval "exec $saved>&-"
        done
        REPO_STATE_BOUND_SAVE7='' REPO_STATE_BOUND_SAVE8=''
        return 125
      fi
      if [ "$fd" = 7 ]; then REPO_STATE_BOUND_SAVE7=$saved; else REPO_STATE_BOUND_SAVE8=$saved; fi
    fi
  done
  REPO_STATE_BOUND_CHANNEL_ACTIVE=1
}

_repo_state_close_channel() {
  [ "${REPO_STATE_BOUND_CHANNEL_ACTIVE:-0}" = 1 ] || return 0
  exec 7>&- 8>&-
  if [ -n "${REPO_STATE_BOUND_SAVE7:-}" ]; then
    eval "exec 7>&$REPO_STATE_BOUND_SAVE7 $REPO_STATE_BOUND_SAVE7>&-" || echo "repo-state: could not restore caller fd 7" >&2
  fi
  if [ -n "${REPO_STATE_BOUND_SAVE8:-}" ]; then
    eval "exec 8>&$REPO_STATE_BOUND_SAVE8 $REPO_STATE_BOUND_SAVE8>&-" || echo "repo-state: could not restore caller fd 8" >&2
  fi
  REPO_STATE_BOUND_SAVE7='' REPO_STATE_BOUND_SAVE8='' REPO_STATE_BOUND_CHANNEL_ACTIVE=0
}

# macOS can transiently fail stat on shared fd numbers across processes.
_repo_state_channel_verified() {
  local attempt=0
  while [ "$attempt" -lt 20 ]; do
    [ -f /dev/fd/8 ] && [ /dev/fd/7 -ef /dev/fd/8 ] && return 0
    attempt=$((attempt + 1))
    [ "$attempt" -eq 20 ] || { sleep 0.01 2>/dev/null || :; }
  done
  return 1
}

# Pipe the script into bash so private state appears in neither argv nor a script file.
repo_state_run_bounded() {
  local limit=$1 operation=$2 private script_text marker name tcmd='' result=0
  local pid watchdog='' monitor=0 completion='' token_rc='' nbytes='' out='' payload_bytes=0
  local LC_ALL=C noclobber=0
  shift 2
  REPO_STATE_BOUND_OUT=''
  # Read by file-interface callers to preserve setup-error status.
  # shellcheck disable=SC2034
  REPO_STATE_BOUND_STARTED=0
  _repo_state_save_channel || { _repo_state_close_channel; return 125; }
  private=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/repo-state-bound.XXXXXX") || {
    _repo_state_close_channel; return 125;
  }
  REPO_STATE_BOUND_PRIVATE=$private
  if [ -z "$private" ] || ! chmod 700 "$private"; then
    [ -z "$private" ] || rm -rf "$private"
    REPO_STATE_BOUND_PRIVATE=''
    _repo_state_close_channel
    return 125
  fi
  case $- in *C*) noclobber=1 ;; esac
  set -C
  if ! { exec 7>"$private/channel"; }; then result=125; fi
  [ "$noclobber" = 1 ] || set +C
  if [ "$result" = 0 ]; then
    if ! { exec 8<>"$private/channel"; } ||
       ! _repo_state_channel_verified ||
       ! rm -f "$private/channel"; then result=125; fi
  fi
  if [ "$result" != 0 ]; then
    _repo_state_close_channel
    rm -rf "$private"; REPO_STATE_BOUND_PRIVATE=''
    return 125
  fi
  marker="$private/timeout"
  if ! script_text=$(
    umask 077
    : > "$marker" && rm -f "$marker" || exit 1
    printf '{\n'
    # The child must not inherit the parent's saved descriptors either.
    for name in "$REPO_STATE_BOUND_SAVE7" "$REPO_STATE_BOUND_SAVE8"; do
      [ -z "$name" ] || printf 'exec %s>&-\n' "$name"
    done
    for name in ${REPO_STATE_BOUND_VARS:-}; do
      declare -p "$name" 2>/dev/null || true
    done
    if [ "${REPO_STATE_TMP+x}" = x ]; then declare -p REPO_STATE_TMP; fi
    printf '. %q\n' "$_REPO_STATE_LIB"
    declare -f "$operation" || exit 1
    for name in ${REPO_STATE_BOUND_FUNCS:-}; do declare -f "$name" || exit 1; done
    printf 'REPO_STATE_BOUND_OUT=\047\047\n'
    printf '%q "$@" >/dev/null 7>&- 8>&-\nrc=$?\n' "$operation"
    printf 'case "$rc" in 124|137) echo "repo-state: operation returned reserved timeout status $rc" >&2; rc=125 ;; esac\n'
    printf 'LC_ALL=C\n'
    printf 'if [ "${#REPO_STATE_BOUND_OUT}" -gt 67108864 ]; then printf "%%s output exceeded 64 MiB; not evaluated\\n" %q >&2; exit 125; fi\n' "$operation"
    printf 'printf "%%s\\n@@done %%s %%s" "$REPO_STATE_BOUND_OUT" "$rc" "${#REPO_STATE_BOUND_OUT}" >&7 || exit 125\nexit "$rc"\n'
    printf '}\n'
  ); then
    _repo_state_close_channel
    rm -rf "$private"; REPO_STATE_BOUND_PRIVATE=''
    return 125
  fi
  if command -v timeout >/dev/null 2>&1; then tcmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then tcmd=gtimeout; fi
  case $- in *m*) monitor=1 ;; esac
  set -m
  # shellcheck disable=SC2034
  REPO_STATE_BOUND_STARTED=1
  if [ -n "$tcmd" ]; then
    "$tcmd" -k 5s "${limit}s" bash <(printf '%s\n' "$script_text") "$@" &
    REPO_STATE_BOUND_PID=$!
    pid=$REPO_STATE_BOUND_PID
  else
    bash <(printf '%s\n' "$script_text") "$@" &
    REPO_STATE_BOUND_PID=$!
    pid=$REPO_STATE_BOUND_PID
    (
      exec 7>&- 8>&-
      for name in "$REPO_STATE_BOUND_SAVE7" "$REPO_STATE_BOUND_SAVE8"; do
        [ -z "$name" ] || eval "exec $name>&-"
      done
      set +m
      watchdog_self=${BASHPID:-$(exec sh -c 'echo "$PPID"')}
      trap 'trap "" TERM; kill -TERM -- "-$watchdog_self" 2>/dev/null; exit 0' TERM
      sleep "$limit" &
      sleeper=$!
      wait "$sleeper" || exit 0
      kill -0 "$pid" 2>/dev/null || exit 0
      : > "$marker"
      kill -TERM -- "-$pid" 2>/dev/null || true
      sleep 5 &
      sleeper=$!
      wait "$sleeper" || exit 0
      kill -KILL -- "-$pid" 2>/dev/null || true
    ) </dev/null >/dev/null 2>&1 &
    REPO_STATE_BOUND_WATCHDOG=$!
    watchdog=$REPO_STATE_BOUND_WATCHDOG
  fi
  exec 7>&-
  [ "$monitor" = 1 ] || set +m
  while :; do
    result=0
    wait "$pid" || result=$?
    [ "$result" != 127 ] || break
    kill -0 "$pid" 2>/dev/null || break
  done
  # Cleanup is independent of the verdict: zombies and leaked children cannot vote.
  kill -KILL -- "-$pid" 2>/dev/null || true
  if [ -z "$tcmd" ] && [ -e "$marker" ]; then result=124; fi
  if [ -n "$watchdog" ]; then
    kill -TERM -- "-$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    kill -KILL -- "-$watchdog" 2>/dev/null || true
  fi
  # Keep the sentinel until validation; removing it with a wildcard expansion
  # scans the entire payload very slowly on Bash 3.2. Feed tail fresh bytes:
  # GNU tail treats an already-consumed descriptor as an empty stream.
  if ! out=$(cat <&8 || exit 1; printf x); then result=125; fi
  completion=$(set -o pipefail; printf '%s' "$out" | tail -c 65) || result=125
  completion=${completion%x}
  completion=${completion##*$'\n'}
  payload_bytes=$((${#out} - ${#completion} - 2))
  _repo_state_close_channel
  case "$result" in
    124|137)
      if [ -n "$tcmd" ] || [ -e "$marker" ]; then result=124
      else result=125; fi ;;
    *)
      IFS=' ' read -r name token_rc nbytes <<< "$completion"
      if [ "$payload_bytes" -ge 0 ] && [ "$result" -lt 128 ] &&
         [[ "$token_rc" =~ ^[0-9]{1,3}$ ]] && [[ "$nbytes" =~ ^[0-9]{1,8}$ ]] &&
         [ "$completion" = "@@done $token_rc $nbytes" ] &&
         [ "$((10#$token_rc))" -eq "$result" ] && [ "$nbytes" = "$payload_bytes" ] &&
         [ "${out:payload_bytes:1}" = $'\n' ]; then
        REPO_STATE_BOUND_OUT=${out:0:payload_bytes}
      else result=125; fi ;;
  esac
  rm -rf "$private"
  REPO_STATE_BOUND_PRIVATE='' REPO_STATE_BOUND_PID='' REPO_STATE_BOUND_WATCHDOG=''
  return "$result"
}
