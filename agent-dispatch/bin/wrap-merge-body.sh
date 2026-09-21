#!/usr/bin/env bash
# wrap-merge-body.sh — wrap and lint a merge body BEFORE it becomes an
# unrewritable squash commit.
#
# A squash merge composes the landing commit from the PR title and body. Branch
# commits were linted; that composed message was not, so a violation surfaced
# only on the push run AFTER it reached main, where it can no longer be
# rewritten (vinnyp/foundry#202). CI now lints the prospective squash message on
# every pull_request event — that is the check that binds. This wrapper is the
# ergonomic path: it folds the body to the limit and lints it locally, so the
# operator sees the problem before opening or editing the PR.
#
# Usage:
#   wrap-merge-body.sh --subject <subject> --body-file <file|-> [--out <file>]
#                      [--config <commitlint.config.cjs>] [--wrap-only]
#
#   --subject      the conventional-commit header (the PR title).
#   --body-file    the body, read from a FILE or from stdin with `-`. The body is
#                  never accepted as a command-line word: `gh` would read a body
#                  whose first line begins with `-` as options, and a body
#                  carrying `-R owner/repo` would retarget the merge. For the
#                  same reason this tool accepts no repository or PR selector at
#                  all — a merge body cannot choose what it merges.
#   --out          write the wrapped message here instead of stdout. Feed it to
#                  `gh pr merge --squash --body-file "$OUT" -- <pr>`; never
#                  `--body "$(...)"`.
#   --config       the commitlint config to lint against. Without it, the
#                  invoking repository's commitlint.config.cjs is used, then the
#                  one shipped at this plugin's repository root. This tool runs
#                  from PATH in any repository, so it never assumes the config
#                  belongs to whatever directory it happens to be called from,
#                  and it never invents rules of its own: the limit it wraps to
#                  and the rules CI enforces have one source.
#   --wrap-only    wrap and exit without linting. It exists so this tool's own
#                  regression can run where commitlint is not installed (CI runs
#                  the suites at step 22 and installs commitlint at step 199).
#                  It never claims a lint it did not perform.
#
# Exit 0 = the message is wrapped and (unless --wrap-only) clean.
# Exit 1 = a commitlint violation, or a token too long to wrap.
# Exit 2 = a usage error, or commitlint/its config is unavailable. An absent
#          linter is a refusal, never a pass: a linter that is not there has not
#          evaluated anything.
set -euo pipefail

# Pathname expansion is never wanted here: the body is data, and a line
# containing `*.md` or `?` must not be rewritten by whatever happens to sit in
# the caller's working directory. `set -e` does not turn globbing off.
set -f

# The body may be unpublished text. Tracing inherited from the caller (SHELLOPTS
# or `bash -x`) would echo every line of it to stderr, so it is turned off here.
set +x

LIMIT=100

usage() {
  cat >&2 <<'USAGE'
usage: wrap-merge-body.sh --subject <subject> --body-file <file|-> [--out <file>]
                          [--config <commitlint.config.cjs>] [--wrap-only]
USAGE
  exit 2
}

die() { printf 'wrap-merge-body: %s\n' "$1" >&2; exit 2; }

SUBJECT=""; BODY_FILE=""; OUT=""; WRAP_ONLY=0; CFG_OVERRIDE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --subject)   [ "$#" -ge 2 ] || usage; SUBJECT="$2"; shift 2 ;;
    --body-file) [ "$#" -ge 2 ] || usage; BODY_FILE="$2"; shift 2 ;;
    --out)       [ "$#" -ge 2 ] || usage; OUT="$2"; shift 2 ;;
    --config)    [ "$#" -ge 2 ] || usage; CFG_OVERRIDE="$2"; shift 2 ;;
    --wrap-only) WRAP_ONLY=1; shift ;;
    -h|--help)   usage ;;
    --)          shift; break ;;
    *)           usage ;;
  esac
done
[ "$#" -eq 0 ] || usage
[ -n "$SUBJECT" ] || usage
[ -n "$BODY_FILE" ] || usage
[ "$BODY_FILE" = "-" ] || [ -r "$BODY_FILE" ] || usage

# Resolve this script through any symlink before looking beside it: the plugin
# installs its bin/ on PATH, so `dirname "$0"` is the symlink's directory and the
# shipped config would never be found from there.
_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  case "$_src" in /*) ;; *) _src="$_dir/$_src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"

CFG=""
if [ "$WRAP_ONLY" -eq 0 ]; then
  command -v commitlint >/dev/null 2>&1 \
    || die "commitlint not found — refusing to pass a message nothing checked"
  CFG="$CFG_OVERRIDE"
  if [ -z "$CFG" ]; then
    TL="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$TL" ] && [ -r "$TL/commitlint.config.cjs" ]; then
      CFG="$TL/commitlint.config.cjs"
    fi
  fi
  if [ -z "$CFG" ] && [ -r "$SCRIPT_DIR/../../commitlint.config.cjs" ]; then
    CFG="$(cd "$SCRIPT_DIR/../.." && pwd)/commitlint.config.cjs"
  fi
  [ -n "$CFG" ] && [ -r "$CFG" ] \
    || die "no commitlint config found (tried --config, the invoking repository, and the one shipped with this plugin) — refusing to lint against unknown rules"
fi

TMP="$(mktemp "${TMPDIR:-/tmp}/merge-body.XXXXXX")" || die "mktemp failed"
chmod 600 "$TMP"
BODY_TMP=""
cleanup() { rm -f "$TMP"; [ -z "$BODY_TMP" ] || rm -f "$BODY_TMP"; }
trap cleanup EXIT

if [ "$BODY_FILE" = "-" ]; then
  BODY_TMP="$(mktemp "${TMPDIR:-/tmp}/merge-body-in.XXXXXX")" || die "mktemp failed"
  chmod 600 "$BODY_TMP"
  cat > "$BODY_TMP"
  BODY_FILE="$BODY_TMP"
fi

# A trailer is machine-read: foundry-reconcile-closures.sh parses
# ^Refs:( <repo>#N)+$, and folding that line would silently break closure
# parsing. Trailers therefore pass through exactly as written, however long.
is_trailer() {
  case "$1" in
    *": "*)
      case "${1%%:*}" in
        Co-Authored-By|Claude-Session|Signed-off-by|Refs|Closes|Fixes|Reviewed-by|Reported-by|Cc|BREAKING\ CHANGE)
          return 0 ;;
      esac ;;
  esac
  return 1
}

wrap_line() {
  local line="$1" w out=""
  if is_trailer "$line"; then
    # A trailer over the limit is still passed through: folding it is the one
    # thing that must not happen. commitlint will then reject the message on
    # footer-max-line-length, which is correct and not something this tool may
    # paper over — so say what the remedy is rather than leaving the operator to
    # infer it from a rule name.
    if [ "${#line}" -gt "$LIMIT" ]; then
      printf 'wrap-merge-body: a trailer line is %s characters, over %s: %s...\n' \
        "${#line}" "$LIMIT" "${line:0:40}" >&2
      printf 'wrap-merge-body: trailers are never folded (it would break `Refs:` parsing) — split it across several trailer lines instead\n' >&2
    fi
    printf '%s\n' "$line"
    return 0
  fi
  if [ "${#line}" -le "$LIMIT" ]; then
    printf '%s\n' "$line"
    return 0
  fi
  for w in $line; do
    if [ "${#w}" -gt "$LIMIT" ]; then
      # Emitting an over-long line would hand commitlint a body it must reject
      # while claiming the wrapper succeeded. Refuse instead.
      printf 'wrap-merge-body: a token of %s characters cannot be wrapped to %s: %s...\n' \
        "${#w}" "$LIMIT" "${w:0:40}" >&2
      exit 1
    fi
    if [ -z "$out" ]; then
      out="$w"
    elif [ "$(( ${#out} + 1 + ${#w} ))" -le "$LIMIT" ]; then
      out="$out $w"
    else
      printf '%s\n' "$out"
      out="$w"
    fi
  done
  # A line of nothing but whitespace leaves $out empty; an empty tail must not
  # return non-zero and kill the script under `set -e`.
  [ -z "$out" ] || printf '%s\n' "$out"
  return 0
}

{
  printf '%s\n\n' "$SUBJECT"
  while IFS= read -r l || [ -n "$l" ]; do
    wrap_line "$l"
  done < "$BODY_FILE"
} > "$TMP"

if [ "$WRAP_ONLY" -eq 0 ]; then
  commitlint --edit "$TMP" --config "$CFG" --verbose || exit 1
fi

if [ -n "$OUT" ]; then
  cp "$TMP" "$OUT"
else
  cat "$TMP"
fi
