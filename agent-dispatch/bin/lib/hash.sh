# shellcheck shell=bash
# hash.sh — shared helper for agent-dispatch. Sourced, not executed directly
# (no shebang / not chmod +x on purpose) — mirrors lib/gate-env.sh's convention.
#
# md5_hex <string-on-stdin> — print a bare 32-character MD5 hex digest.
#
# Why this exists: `md5` is a BSD/macOS binary and does not exist on Linux, where the
# equivalent is `md5sum` (which prints "<digest>  -", not a bare digest). Two callers
# derive the SAME worktree path from this digest (coding-dispatch.sh and
# coding-build-phase.sh), so they must agree byte for byte — a divergent or empty digest
# strands a phase's commits in a path the caller never looks at. One implementation,
# sourced by both, is the only way that stays true.
#
# The digest is a short, stable directory-name discriminator, not a security primitive.

md5_hex() {
  if command -v md5 >/dev/null 2>&1; then
    md5 -q
  elif command -v md5sum >/dev/null 2>&1; then
    md5sum | cut -c1-32
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -md5 | sed -E 's/^.*[[:space:]]//'
  else
    # Last resort: cksum is everywhere and is stable per input, which is all the
    # directory-name discriminator actually needs. Never silently emit nothing.
    cksum | awk '{print $1 $2}'
  fi
}
