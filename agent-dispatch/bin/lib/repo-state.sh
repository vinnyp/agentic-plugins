#!/usr/bin/env bash
# Sourceable repository config snapshots. No caller shell options are changed.
_REPO_STATE_LOCAL_ENV_VARS=$(git rev-parse --local-env-vars 2>/dev/null)

_repo_state_git() (
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_PREFIX
  # Git supplies the whitespace-separated names of its repository-local variables.
  # shellcheck disable=SC2086
  unset $_REPO_STATE_LOCAL_ENV_VARS
  export GIT_OPTIONAL_LOCKS=0
  git "$@"
)

_repo_state_sha256() (
  local digest input
  umask 077
  input=$(mktemp "${TMPDIR:-/tmp}/repo-state-hash.XXXXXX") || return 1
  trap 'rm -f "$input"' EXIT
  cat > "$input" || return 1
  if ! command -v shasum >/dev/null 2>&1 || ! digest=$(shasum -a 256 < "$input"); then
    digest=$(sha256sum < "$input") || return 1
  fi
  digest=${digest%% *}
  [ -n "$digest" ] || return 1
  printf '%s\n' "$digest"
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
    case "$lower" in credential.*) lower=extraheader ;; *) lower=${lower##*.} ;; esac
    case "$lower" in
      *extraheader*|*token*|*pass*|*secret*|*proxy*)
        value="sha256:$(printf '%s' "$value" | _repo_state_sha256)" ;;
      *)
        if [[ "$value" =~ ://[^/]*@ ]]; then
          value="sha256:$(printf '%s' "$value" | _repo_state_sha256)"
        fi ;;
    esac
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
      target=$(readlink "$file"; printf '.')
      target=${target%.}
      target=${target%$'\n'}
      content=dangling
      if [ -f "$file" ]; then
        content=$(_repo_state_sha256 < "$file")
      fi
      if [ -x "$file" ]; then mode=link-exec; else mode=link-noexec; fi
      digest=$(printf '%s\0%s\0%s' "$target" "$content" "$mode" | _repo_state_sha256)
    else
      [ -f "$file" ] || continue
      mode=$(stat -f '%Lp' "$file" 2>/dev/null) || mode=$(stat -c '%a' "$file")
      digest=$(_repo_state_sha256 < "$file")
    fi
    printf 'hooks\t%s\t%s\t%s\n' "$(_repo_state_encode "$prefix${file##*/}")" "$mode" "$digest"
  done
}

_repo_state_tree() {
  local wt=$1 status=$2 record path skip
  if [ ! -d "$wt" ] || ! _repo_state_git -C "$wt" -c core.fsmonitor=false status --porcelain=v2 -z --untracked-files=all > "$status" 2>/dev/null; then
    printf 'tree\t%s\tunreadable\n' "$(_repo_state_encode "$wt")"
    return
  fi
  printf 'tree\t%s\t%s\n' "$(_repo_state_encode "$wt")" "$(_repo_state_sha256 < "$status")"
  while IFS= read -r -d '' record; do
    case "$record" in
      '1 '*) skip=8 ;; '2 '*) skip=9 ;; 'u '*) skip=10 ;;
      '? '*) skip=1 ;; *) continue ;;
    esac
    path=$record
    while [ "$skip" -gt 0 ]; do path=${path#* }; skip=$((skip - 1)); done
    printf 'dirty\t%s\t%s\n' "$(_repo_state_encode "$wt")" "$(_repo_state_encode "$path")"
    case "$record" in '2 '*) IFS= read -r -d '' path || true ;; esac
  done < "$status"
}

repo_state_snapshot() (
  umask 077
  local repo=${1:-} out=${2:-} top ident name email config wt hooks custom head branch record temp
  _repo_state_sha256 </dev/null >/dev/null || return 3
  case "$repo" in /*) ;; *) return 3 ;; esac
  top=$(_repo_state_git -C "$repo" rev-parse --path-format=absolute --show-toplevel 2>/dev/null) || return 3
  temp=$(mktemp -d "$(dirname "$out")/.repo-state.XXXXXX") || return 3
  trap 'rm -rf "$temp"' EXIT
  config="$temp/config"
  if ! _repo_state_git -C "$repo" config --list --show-scope --show-origin -z > "$config"; then
    return 3
  fi
  if ! _repo_state_git -C "$repo" for-each-ref --format='ref%09%(refname)%09%(objectname)' > "$config.refs"; then
    return 3
  fi
  : > "$out" || return 3
  chmod 600 "$out" || return 3
  {
    printf 'repo\t%s\n' "$(_repo_state_encode "$top")"
    ident=$(_repo_state_git -C "$repo" var GIT_COMMITTER_IDENT 2>/dev/null) || ident=''
    ident=${ident% *}; ident=${ident% *}
    name=${ident% <*}; email=${ident##*<}; email=${email%>}
    printf 'identity\t%s\t%s\n' "$(_repo_state_encode "$name")" "$(_repo_state_encode "$email")"
    cat "$config.refs"
    hooks="$(_repo_state_git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/hooks"
    _repo_state_hooks "$hooks" ''
    custom=$(_repo_state_git -C "$repo" rev-parse --path-format=absolute --git-path hooks)
    [ "$custom" = "$hooks" ] || _repo_state_hooks "$custom" 'core.hooksPath/'
    wt='' head='' branch=''
    while IFS= read -r record || [ -n "$record" ]; do
      case "$record" in
        'worktree '*) wt=${record#worktree } ;;
        'HEAD '*) head=${record#HEAD } ;;
        'branch '*) branch=${record#branch } ;;
        '')
          [ -n "$wt" ] || continue
          printf 'worktree\t%s\t%s\t%s\n' "$(_repo_state_encode "$wt")" "$head" "$branch"
          _repo_state_tree "$wt" "$config.status"
          wt='' head='' branch='' ;;
      esac
    done < <(_repo_state_git -C "$repo" -c core.quotePath=false worktree list --porcelain 2>/dev/null)
    _repo_state_configs < "$config"
    while IFS= read -r wt; do
      case "$wt" in 'worktree '*) wt=${wt#worktree } ;; *) continue ;; esac
      [ "$wt" != "$top" ] && [ -d "$wt" ] || continue
      if _repo_state_git -C "$wt" config --list --show-scope --show-origin -z --worktree > "$config" 2>/dev/null; then
        _repo_state_configs < "$config"
      fi
    done < <(_repo_state_git -C "$repo" worktree list --porcelain 2>/dev/null)
  } > "$out"
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
  local before=$1 after=$2 changes=$3 first='' temp scope origin key old new rc=0 remote line
  : > "$changes" || return 2
  if [ ! -f "$before" ] || [ ! -r "$before" ]; then
    printf 'state: <unreadable before snapshot>\n' > "$changes"
    return 3
  fi
  IFS= read -r first < "$before" || true
  if [ "$first" = unreadable ]; then
    printf 'state: <unreadable before snapshot>\n' > "$changes"
    return 3
  fi
  if [ ! -f "$after" ] || [ ! -r "$after" ]; then
    printf 'config: <unreadable after review>\n' > "$changes"
    return 2
  fi
  IFS= read -r first < "$after" || true
  if [ "$first" = unreadable ]; then
    printf 'config: <unreadable after review>\n' > "$changes"
    return 2
  fi
  temp=$(mktemp -d "$(dirname "$changes")/.repo-state-compare.XXXXXX") || return 3
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
      branch.*.pushremote) rc=2 ;;
      branch.*.remote)
        remote=$(_repo_state_decode "$new")
        # Only pre-existing remote names are benign.
        if [ "$new" != '(absent)' ] &&
           ! awk -F '\t' -v prefix="remote.$remote." '$1=="config" && index($4,prefix)==1 { found=1 } END {exit !found}' "$before"; then rc=2; fi ;;
      branch.*.*|remote.*.fetch|remote.*.gh-resolved|gc.*|maintenance.*|extensions.worktreeconfig|core.sparsecheckout|core.sparsecheckoutcone) ;;
      remote.*.*)
        remote=${key#remote.}; remote=${remote%.*}
        if awk -F '\t' -v prefix="remote.$remote." '$1=="config" && index($4,prefix)==1 { found=1 } END {exit !found}' "$before"; then
          rc=2
        else
          case "$key" in remote.*.url) ;; *) rc=2 ;; esac
        fi ;;
      *) rc=2 ;;
    esac
    printf 'config %s (%s:%s): %s -> %s\n' \
      "$(printf '%s' "$key" | sed -E 's#(://)[^/]*@#\1#g')" "$scope" "$origin" \
      "$(_repo_state_display "$key" "$old")" "$(_repo_state_display "$key" "$new")" >> "$changes"
  done < "$temp/diff"
  # Pair records by kind and name; compare complete payloads (including modes/branches).
  awk -F '\t' '
    $1!="hooks" && $1!="ref" && $1!="worktree" && $1!="tree" {next}
    {k=$1 FS $2; v=$3; for(i=4;i<=NF;i++) v=v FS $i; keys[k]=1}
    FILENAME==ARGV[1] {old[k]=v; next} {new[k]=v}
    END {for(k in keys) {hasold=(k in old); hasnew=(k in new); if(old[k]!=new[k]) {gsub(FS," ",old[k]); gsub(FS," ",new[k]); print k FS (hasold?old[k]:"(absent)") FS (hasnew?new[k]:"(absent)")}}}
  ' "$before" "$after" > "$temp/records"
  local kind repo sha cn ce identity_name identity_email count paths
  repo=$(awk -F '\t' '$1=="repo" {print $2;exit}' "$after")
  repo=$(_repo_state_decode "$repo")
  identity_name=$(awk -F '\t' '$1=="identity" {print $2;exit}' "$before")
  identity_email=$(awk -F '\t' '$1=="identity" {print $3;exit}' "$before")
  while IFS=$'\t' read -r kind key old new remote line; do
    [ "$rc" -ge 1 ] || rc=1
    case "$kind" in
      hooks)
        rc=2
        if [ "$old" = '(absent)' ]; then line=added
        elif [ "$new" = '(absent)' ]; then line=removed
        else line=changed; fi
        printf 'hooks %s: %s\n' "$key" "$line" >> "$changes" ;;
      ref)
        printf 'ref %s: %s -> %s\n' "$key" "$old" "$new" >> "$changes"
        case "$key" in refs/heads/*)
          if [ ! -f "$temp/exclude" ]; then
            awk -F '\t' '$1=="ref" {print $3}' "$before" |
              _repo_state_git -C "$repo" cat-file --batch-check='%(objectname) %(objecttype)' 2>/dev/null |
              awk '($2=="commit" || $2=="tag") {print "^" $1}' > "$temp/exclude"
          fi
          [ "$new" != '(absent)' ] || continue
          if ! _repo_state_git -C "$repo" rev-list --stdin "$new" --not --remotes < "$temp/exclude" > "$temp/commits" 2>/dev/null; then
            printf 'commit-check %s: failed\n' "$key" >> "$changes"; rc=2; continue
          fi
          while IFS= read -r sha; do
            cn=$(_repo_state_git -C "$repo" show -s --format=%cn "$sha")
            ce=$(_repo_state_git -C "$repo" show -s --format=%ce "$sha")
            if [ "$(_repo_state_encode "$cn")" != "$identity_name" ] || [ "$(_repo_state_encode "$ce")" != "$identity_email" ]; then
              printf 'commit %s: committer <changed>\n' "$sha" >> "$changes"; rc=2
            fi
          done < "$temp/commits" ;;
        esac ;;
      worktree)
        [ "$old" = '(absent)' ] || old="HEAD $old"
        [ "$new" = '(absent)' ] || new="HEAD $new"
        printf 'worktree %s: %s -> %s\n' "$key" "$old" "$new" >> "$changes" ;;
      tree)
        if [ "$old" = '(absent)' ]; then
          printf 'tree %s: worktree added\n' "$key" >> "$changes"
        elif [ "$new" = '(absent)' ]; then
          printf 'tree %s: worktree removed\n' "$key" >> "$changes"
        elif [ "$new" = unreadable ]; then
          printf 'tree %s: unreadable\n' "$key" >> "$changes"
        else
          awk -F '\t' -v wt="$key" '$1=="dirty" && $2==wt {print $3}' "$before" | LC_ALL=C sort -u > "$temp/dirty-old"
          awk -F '\t' -v wt="$key" '$1=="dirty" && $2==wt {print $3}' "$after" | LC_ALL=C sort -u > "$temp/dirty-new"
          LC_ALL=C comm -13 "$temp/dirty-old" "$temp/dirty-new" > "$temp/dirty"
          count=$(wc -l < "$temp/dirty" | tr -d ' ')
          paths=$(head -n 20 "$temp/dirty" | paste -sd ' ' -)
          if [ "$count" = 0 ]; then
            printf 'tree %s: status changed (no new dirty paths)\n' "$key" >> "$changes"
          else
            printf 'tree %s: %s new dirty paths: %s\n' "$key" "$count" "$paths" >> "$changes"
          fi
        fi ;;
    esac
  done < "$temp/records"
  return "$rc"
)
