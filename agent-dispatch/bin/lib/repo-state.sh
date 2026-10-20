#!/usr/bin/env bash
# Sourceable repository config snapshots. No caller shell options are changed.
_repo_state_git() (
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_PREFIX
  export GIT_OPTIONAL_LOCKS=0
  git "$@"
)

_repo_state_encode() {
  local value=$1
  value=${value//%/%25}
  value=${value//$'\t'/%09}
  value=${value//$'\n'/%0A}
  printf '%s' "$value"
}

_repo_state_configs() {
  local scope origin kv key value lower
  while IFS= read -r -d '' scope && IFS= read -r -d '' origin && IFS= read -r -d '' kv; do
    case "$kv" in
      *$'\n'*) key=${kv%%$'\n'*}; value=${kv#*$'\n'} ;;
      *) key=$kv; value='(novalue)' ;;
    esac
    lower=$(printf '%s' "$key" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    case "$lower" in
      credential.*|*extraheader*|*token*|*pass*|*secret*|*proxy*)
        value="sha256:$(printf '%s' "$value" | shasum -a 256 | cut -d ' ' -f 1)" ;;
      *)
        if [[ "$value" =~ ://[^/]*@ ]]; then
          value="sha256:$(printf '%s' "$value" | shasum -a 256 | cut -d ' ' -f 1)"
        fi ;;
    esac
    printf 'config\t%s\t%s\t%s\t%s\n' "$(_repo_state_encode "$scope")" \
      "$(_repo_state_encode "$origin")" "$(_repo_state_encode "$key")" "$(_repo_state_encode "$value")"
  done
}

repo_state_snapshot() (
  umask 077
  local repo=${1:-} out=${2:-} top ident name email config wt
  case "$repo" in /*) ;; *) return 3 ;; esac
  top=$(_repo_state_git -C "$repo" rev-parse --path-format=absolute --show-toplevel 2>/dev/null) || return 3
  config=$(mktemp "${TMPDIR:-/tmp}/repo-state-config.XXXXXX") || return 3
  if ! _repo_state_git -C "$repo" config --list --show-scope --show-origin -z > "$config"; then
    rm -f "$config"
    return 3
  fi
  : > "$out" || { rm -f "$config"; return 3; }
  chmod 600 "$out" || { rm -f "$config"; return 3; }
  {
    printf 'repo\t%s\n' "$(_repo_state_encode "$top")"
    ident=$(_repo_state_git -C "$repo" var GIT_COMMITTER_IDENT 2>/dev/null) || ident=''
    ident=${ident% *}; ident=${ident% *}
    name=${ident% <*}; email=${ident##*<}; email=${email%>}
    printf 'identity\t%s\t%s\n' "$(_repo_state_encode "$name")" "$(_repo_state_encode "$email")"
    _repo_state_configs < "$config"
    while IFS= read -r wt; do
      case "$wt" in 'worktree '*) wt=${wt#worktree } ;; *) continue ;; esac
      [ "$wt" != "$top" ] && [ -d "$wt" ] || continue
      if _repo_state_git -C "$wt" config --list --show-scope --show-origin -z --worktree > "$config" 2>/dev/null; then
        _repo_state_configs < "$config"
      fi
    done < <(_repo_state_git -C "$repo" worktree list --porcelain 2>/dev/null)
  } > "$out"
  rm -f "$config"
  return 0
)

repo_state_mark_unreadable() (
  umask 077
  printf 'unreadable\n' > "$1"
  chmod 600 "$1"
)

_repo_state_display() {
  local key=$1 value=$2
  if [ "$value" = '(absent)' ]; then printf '%s' "$value"; return; fi
  case "$key" in
    core.*) case "$value" in true|false|/*) ;; *) value='<changed>' ;; esac ;;
    commit.gpgsign|tag.gpgsign) ;;
    *) value='<changed>' ;;
  esac
  printf '%s' "$value" | sed -E 's#(://)[^/]*@#\1#g'
}

repo_state_compare() (
  local before=$1 after=$2 changes=$3 first temp scope origin key old new rc=0 remote line
  : > "$changes" || return 2
  IFS= read -r first < "$after" || true
  if [ "$first" = unreadable ]; then
    printf 'config: <unreadable after review>\n' > "$changes"
    return 2
  fi
  temp=$(mktemp -d "${TMPDIR:-/tmp}/repo-state-compare.XXXXXX") || return 2
  trap 'rm -rf "$temp"' EXIT
  LC_ALL=C sort "$before" > "$temp/before"
  LC_ALL=C sort "$after" > "$temp/after"
  LC_ALL=C comm -23 "$temp/before" "$temp/after" > "$temp/old"
  LC_ALL=C comm -13 "$temp/before" "$temp/after" > "$temp/new"
  # Pair removed and added values within a scope/origin/key, retaining duplicates.
  awk -F '\t' '
    $1 != "config" { next }
    { k=$2 FS $3 FS $4; keys[k]=1 }
    FILENAME == ARGV[1] { old[k,++no[k]]=$5; next }
    { new[k,++nn[k]]=$5 }
    END { for (k in keys) {
      n=no[k]>nn[k]?no[k]:nn[k]
      for(i=1;i<=n;i++) print k FS (i<=no[k]?old[k,i]:"(absent)") FS (i<=nn[k]?new[k,i]:"(absent)")
    }}' "$temp/old" "$temp/new" > "$temp/diff"
  while IFS= read -r line; do
    scope=${line%%$'\t'*}; line=${line#*$'\t'}
    origin=${line%%$'\t'*}; line=${line#*$'\t'}
    key=${line%%$'\t'*}; line=${line#*$'\t'}
    old=${line%%$'\t'*}; new=${line#*$'\t'}
    [ -n "$key" ] || continue
    [ "$rc" -ge 1 ] || rc=1
    case "$key" in
      branch.*.*|remote.*.fetch|remote.*.gh-resolved|gc.*|maintenance.*|extensions.worktreeconfig|core.sparsecheckout|core.sparsecheckoutcone|*vscode*) ;;
      remote.*.*)
        remote=${key#remote.}; remote=${remote%.*}
        if awk -F '\t' -v prefix="remote.$remote." '$1=="config" && index($4,prefix)==1 { found=1 } END {exit !found}' "$before"; then rc=2; fi ;;
      *) rc=2 ;;
    esac
    printf 'config %s (%s:%s): %s -> %s\n' \
      "$(printf '%s' "$key" | sed -E 's#(://)[^/]*@#\1#g')" "$scope" "$origin" \
      "$(_repo_state_display "$key" "$old")" "$(_repo_state_display "$key" "$new")" >> "$changes"
  done < "$temp/diff"
  return "$rc"
)
