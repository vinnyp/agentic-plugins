# shellcheck shell=bash
# Shared capacity and limit diagnostic matcher. Sourced, not executed.
AGENT_UNAVAILABLE_RE='at capacity|overloaded|resource.?exhausted|too many requests|(http|status|error)[^a-z0-9]{0,12}429([^0-9]|$)|rate.?limit(ed)?|usage limit|quota (exceeded|reached)'

agent_unavailable_match() {
  local f line
  for f in "$@"; do
    [ -f "$f" ] || continue
    if line="$(grep -ihE "$AGENT_UNAVAILABLE_RE" "$f")"; then
      printf '%s\n' "$line" | sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;}' | cut -c1-200
      return 0
    fi
  done
  return 1
}
