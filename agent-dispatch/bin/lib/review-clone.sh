#!/usr/bin/env bash
# Sourceable private review clone builder; preserves caller shell options.
_review_clone_git() (
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_PREFIX
  git "$@"
)

_review_clone_reason() {
  REVIEW_CLONE_REASON=$1
  printf 'review-clone: %s\n' "$1" >&2
  return "${2:-3}"
}

review_clone_guarded_rm() {
  local parent=${1:-} path=${2:-} physical_parent physical_path_parent
  case "$path" in
    ''|*/|[!/]*) _review_clone_reason 'invalid removal path'; return 3 ;;
  esac
  case "$parent" in
    /*) ;;
    *) _review_clone_reason 'invalid removal parent'; return 3 ;;
  esac
  if [ -L "$path" ]; then _review_clone_reason 'symlink removal path'; return 3; fi
  case "${path##*/}" in
    dispatch-review-wt.*) ;;
    *) _review_clone_reason 'invalid removal basename'; return 3 ;;
  esac
  physical_parent=$(cd -P "$parent" 2>/dev/null && pwd -P) || {
    _review_clone_reason 'unreadable removal parent'; return 3;
  }
  physical_path_parent=$(cd -P "$(dirname "$path")" 2>/dev/null && pwd -P) || {
    _review_clone_reason 'unreadable path parent'; return 3;
  }
  if [ "$physical_parent" != "$physical_path_parent" ]; then
    _review_clone_reason 'different removal parent'; return 3
  fi
  rm -rf -- "$path" 2>/dev/null || { _review_clone_reason 'removal failed'; return 3; }
}

_review_clone_refs() {
  local refs
  refs=$(_review_clone_git -C "$1" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags refs/remotes) || return 1
  printf '%s\n' "$refs" | sed '\|^refs/remotes/origin/HEAD |d'
}

# Only called after validating a previously absent destination.
_review_clone_failed() {
  review_clone_guarded_rm "$2" "$3" 2>/dev/null || true
  _review_clone_reason "$1" 4
}

review_clone_build() {
  local src=${1:-} dest=${2:-} sha=${3:-} parent common config key value
  local paths path attributes target source_refs dest_refs status
  REVIEW_CLONE_SHA=''
  # Public output variable for sourced callers.
  # shellcheck disable=SC2034
  REVIEW_CLONE_REASON=''
  case "$dest" in
    ''|*/|[!/]*) _review_clone_reason 'invalid destination path'; return 3 ;;
  esac
  if [ -L "$dest" ] || [ -e "$dest" ]; then
    _review_clone_reason 'destination exists or is a symlink'; return 3
  fi
  case "${dest##*/}" in
    dispatch-review-wt.*) ;;
    *) _review_clone_reason 'invalid destination basename'; return 3 ;;
  esac
  case "$src" in
    /*) ;;
    *) _review_clone_reason 'source is not an absolute work tree'; return 3 ;;
  esac
  if [ "$(_review_clone_git -C "$src" rev-parse --is-inside-work-tree 2>/dev/null)" != true ]; then
    _review_clone_reason 'source is not a work tree'; return 3
  fi
  parent=$(cd -P "$(dirname "$dest")" 2>/dev/null && pwd -P) || {
    _review_clone_reason 'unreadable destination parent'; return 3;
  }
  if [ -z "$sha" ]; then
    sha=$(_review_clone_git -C "$src" rev-parse --verify HEAD 2>/dev/null) || {
      _review_clone_failed 'unborn or unreadable HEAD' "$parent" "$dest"; return 4;
    }
  fi
  # Validate explicit pins as commits as well as implicit HEAD.
  sha=$(_review_clone_git -C "$src" rev-parse --verify "$sha^{commit}" 2>/dev/null) || {
    _review_clone_failed 'unborn or unreadable HEAD' "$parent" "$dest"; return 4;
  }
  config=$(_review_clone_git -C "$src" config --show-scope --get-regexp '^filter\.' 2>/dev/null) || {
    case $? in
      1) ;;
      *) _review_clone_failed 'unreadable filter config' "$parent" "$dest"; return 4 ;;
    esac
  }
  if printf '%s\n' "$config" | grep -Eq '^(local|worktree)[[:space:]]'; then
    _review_clone_failed 'local or worktree filter config' "$parent" "$dest"; return 4
  fi
  if _review_clone_git -C "$src" config --get extensions.partialclone >/dev/null 2>&1; then
    _review_clone_failed 'partial clone' "$parent" "$dest"; return 4
  fi
  config=$(_review_clone_git -C "$src" config --get-regexp '^remote\..*\.promisor$' 2>/dev/null) || {
    case $? in
      1) ;;
      *) _review_clone_failed 'unreadable promisor config' "$parent" "$dest"; return 4 ;;
    esac
  }
  while read -r key value; do
    [ -n "$key" ] || continue
    value=$(_review_clone_git -C "$src" config --bool --get "$key" 2>/dev/null) || {
      _review_clone_failed 'unreadable promisor config' "$parent" "$dest"; return 4;
    }
    if [ "$value" = true ]; then
      _review_clone_failed 'promisor remote' "$parent" "$dest"; return 4
    fi
  done <<< "$config"
  common=$(_review_clone_git -C "$src" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
    _review_clone_failed 'unreadable common directory' "$parent" "$dest"; return 4;
  }
  if [ -e "$common/lfs" ]; then
    _review_clone_failed 'LFS directory' "$parent" "$dest"; return 4
  fi
  if [ -f "$common/info/attributes" ]; then
    attributes=$(cat "$common/info/attributes" 2>/dev/null) || {
      _review_clone_failed 'unreadable info attributes' "$parent" "$dest"; return 4;
    }
    if [[ "$attributes" = *filter=* ]]; then
      _review_clone_failed 'filter in info attributes' "$parent" "$dest"; return 4
    fi
  fi
  paths=$(_review_clone_git -C "$src" -c core.quotePath=false ls-tree -r --name-only "$sha" 2>/dev/null) || {
    _review_clone_failed 'unreadable pinned tree' "$parent" "$dest"; return 4;
  }
  while IFS= read -r path; do
    case "$path" in
      .gitattributes|*/.gitattributes)
        attributes=$(_review_clone_git -C "$src" show "$sha:$path" 2>/dev/null) || {
          _review_clone_failed 'unreadable tree attributes' "$parent" "$dest"; return 4;
        }
        if [[ "$attributes" = *filter=* ]]; then
          _review_clone_failed 'filter in tree attributes' "$parent" "$dest"; return 4
        fi ;;
    esac
  done <<< "$paths"
  if ! _review_clone_git clone --quiet --local --no-checkout "$src" "$dest" 2>/dev/null ||
     ! chmod 700 "$dest" 2>/dev/null; then
    _review_clone_failed 'clone failed' "$parent" "$dest"; return 4
  fi
  _review_clone_git -C "$dest" remote set-head origin -d 2>/dev/null || true
  if ! _review_clone_git -C "$dest" fetch --quiet --no-tags --prune --update-head-ok "$src" \
      '+refs/heads/*:refs/heads/*' '+refs/remotes/*:refs/remotes/*' '+refs/tags/*:refs/tags/*' 2>/dev/null; then
    _review_clone_failed 'ref mirror failed' "$parent" "$dest"; return 4
  fi
  if target=$(_review_clone_git -C "$src" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null); then
    _review_clone_git -C "$dest" symbolic-ref refs/remotes/origin/HEAD "$target" 2>/dev/null || {
      _review_clone_failed 'origin HEAD mirror failed' "$parent" "$dest"; return 4;
    }
  fi
  if ! _review_clone_git -C "$dest" remote set-url origin "$dest/.git/review-clone-disabled-remote" 2>/dev/null ||
     ! _review_clone_git -C "$dest" remote set-url --push origin "$dest/.git/review-clone-disabled-remote" 2>/dev/null ||
     ! _review_clone_git -C "$dest" checkout --quiet --detach "$sha" 2>/dev/null; then
    _review_clone_failed 'remote isolation or checkout failed' "$parent" "$dest"; return 4
  fi
  status=$(_review_clone_git -C "$dest" status --porcelain 2>/dev/null) || {
    _review_clone_failed 'status verification failed' "$parent" "$dest"; return 4;
  }
  if ! source_refs=$(_review_clone_refs "$src" 2>/dev/null) ||
     ! dest_refs=$(_review_clone_refs "$dest" 2>/dev/null); then
      _review_clone_failed 'ref verification failed' "$parent" "$dest"; return 4
  fi
  if [ -n "$status" ] || [ "$source_refs" != "$dest_refs" ]; then
    _review_clone_failed 'dirty checkout or mismatched refs' "$parent" "$dest"; return 4
  fi
  # Public output variable for sourced callers.
  # shellcheck disable=SC2034
  REVIEW_CLONE_SHA=$sha
}
