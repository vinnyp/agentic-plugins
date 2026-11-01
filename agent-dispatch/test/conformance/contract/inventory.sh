#!/usr/bin/env bash
# Probe notes (Task 6): --help runs from a fresh scratch directory with private
# HOME/TMPDIR/XDG_CACHE_HOME. The safe probes below left those directories empty.
# repo-state-check, dispatch-worker, review-clone.sh, agent-dispatch-doctor:
#   help rc 0. wrap-merge-body.sh: help rc 2 (usage), no writes.
# No help contract: coding-dispatch.sh, coding-preflight.sh,
# coding-build-phase.sh, drive-cold-session.sh, drive-cmux-session.sh,
# gate-run.sh, review-pin.sh, review-log-status. Their early argument guards
# reject --help (all eight probes rc 2, no files created); review-log-status treats it as a filename. Use commands.md.
# run-long-gate.sh, mutation-verify.sh, mutation-sweep.sh: not executed under
# this task's prohibition on long gates and mutation tools; use commands.md.
# Help snapshots replace literal probe HOME, scratch and plugin paths only.
# inventory.tsv is stdout: regenerate with inventory.sh > inventory.tsv.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/../../.." && pwd)
docs=$plugin/docs/commands.md
bin=$plugin/bin
while [ "$#" -gt 0 ]; do
  case "$1" in
    --docs) [ "$#" -ge 2 ] || exit 2; docs=$2; shift 2 ;;
    --bin) [ "$#" -ge 2 ] || exit 2; bin=$2; shift 2 ;;
    *) echo 'usage: inventory.sh [--docs <path>] [--bin <dir>]' >&2; exit 2 ;;
  esac
done
bin=$(cd "$bin" && pwd)
[ -f "$docs" ] || exit 2
tmp=$(mktemp -d "${TMPDIR:-/tmp}/conformance-inventory.XXXXXX")
[ -n "$tmp" ] || exit 1
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/home" "$tmp/work" "$tmp/cache" "$tmp/temp"
# Read the public entrypoint list without executing the doctor.
awk '/^ENTRYPOINTS=\(/ {inside=1; next} inside && /^\)/ {exit} inside {print $1}' \
  "$bin/agent-dispatch-doctor" > "$tmp/commands"
[ "$(wc -l < "$tmp/commands" | tr -d ' ')" = 16 ] || exit 1
printf 'command\tkind\tname\tmeaning\tsource\n'
{
while IFS= read -r command; do
  case "$command" in
    repo-state-check|dispatch-worker|review-clone.sh|agent-dispatch-doctor|wrap-merge-body.sh)
      rc=0
      (cd "$tmp/work"; HOME="$tmp/home" TMPDIR="$tmp/temp" XDG_CACHE_HOME="$tmp/cache" \
        bash "$bin/$command" --help) > "$tmp/raw" 2>&1 || rc=$?
      case "$command:$rc" in wrap-merge-body.sh:2|*:0) ;; *) exit 1 ;; esac
      # Literal substitutions, not regexes: a path may contain punctuation.
      awk -v home="$tmp/home" -v scratch="$tmp" -v plugin="$(dirname "$bin")" '
        function replace(s, old, new, n) {
          while ((n=index(s,old))) s=substr(s,1,n-1) new substr(s,n+length(old))
          return s
        }
        {print replace(replace(replace($0,home,"<HOME>"),scratch,"<SCRATCH>"),plugin,"<PLUGIN>")}
      ' "$tmp/raw" > "$tmp/help"
      cmp -s "$tmp/help" "$here/help/$command.txt" || {
        echo "help snapshot differs: $command" >&2; exit 1;
      }
      ;;
    *) : > "$tmp/help" ;;
  esac
  awk -v command="$command" -v help="$tmp/help" '
    function row(kind,name,text,source) {
      gsub(/\t/," ",text); gsub(/\r/,"",text)
      print command "\t" kind "\t" name "\t" text "\t" source
    }
    function scan(text,source, rest,token) {
      if (text ~ /^[[:space:]]*$/) return
      row("line","text",text,source)
      rest=text
      while (match(rest,/--[a-zA-Z][a-zA-Z0-9-]*/)) {
        token=substr(rest,RSTART,RLENGTH); row("flag",token,text,source)
        rest=substr(rest,RSTART+RLENGTH)
      }
      rest=text
      while (source == "docs/commands.md" && match(rest,/`[A-Z][A-Z0-9_]*`/)) {
        token=substr(rest,RSTART+1,RLENGTH-2); if (token !~ /^(AND|JSON|HEAD|XXXXXX)$/) row("env",token,text,source)
        rest=substr(rest,RSTART+RLENGTH)
      }
      if (text ~ /[Ee]xit|^[[:space:]]*[|]?[[:space:]]*`?[0-9]+[[:space:]`|]/) {
        rest=text
        while (match(rest,/[0-9]+/)) {
          token=substr(rest,RSTART,RLENGTH); row("exit",token,text,source)
          rest=substr(rest,RSTART+RLENGTH)
        }
      }
    }
    /^## / {
      title=substr($0,4); gsub(/`/,"",title)
      active=(title==command)
      environment=(title=="Environment variables")
    }
    environment && /^\|/ {
      split($0, columns, "|")
      readers=columns[3]
      # Only commands explicitly named in Read by own these rows.
      matched=0
      while (match(readers, /`[^`]+`/)) {
        reader=substr(readers,RSTART+1,RLENGTH-2)
        split(reader, words, " ")
        if (words[1]==command) matched=1
        readers=substr(readers,RSTART+RLENGTH)
      }
      if (matched) {
        variables=columns[2]
        while (match(variables, /`[A-Z][A-Z0-9_]*`/)) {
          token=substr(variables,RSTART+1,RLENGTH-2)
          row("env",token,$0,"docs/commands.md")
          variables=substr(variables,RSTART+RLENGTH)
        }
      }
      next
    }
    active {scan($0,"docs/commands.md")}
    END {while ((getline text < help)>0) scan(text,"help/" command ".txt")}
  ' "$docs"
  awk -F '\t' -v command="$command" '$1==command {print $1 "\tflag\t" $2 "\t" $3 "\tundocumented.tsv"}' "$here/undocumented.tsv"
done < "$tmp/commands"
cat "$here/exits.tsv"
} | LC_ALL=C sort -u
[ -z "$(find "$tmp/home" "$tmp/work" "$tmp/cache" "$tmp/temp" -mindepth 1 -print)" ] || {
  echo 'inventory: help probe created artifacts' >&2
  exit 1
}
