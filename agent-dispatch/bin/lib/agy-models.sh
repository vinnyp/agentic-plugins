# shellcheck shell=bash
# Single source of truth for agy default models by role. When agy renames a model,
# edit ONLY this file; coding-preflight.sh, dispatch-worker and agent-dispatch-doctor
# fail closed until it matches `agy models`.
# shellcheck disable=SC2034  # consumed by sourcing callers
AGY_MODEL_CODING_DEFAULT="gemini-3.8-flash-medium"
# shellcheck disable=SC2034  # consumed by sourcing callers
AGY_MODEL_REVIEW_DEFAULT="gemini-4-argon-high"

# Match an exact id or display name in tab-separated `agy models` output.
agy_model_present() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v m="$2" '$1==m || $2==m {f=1} END{exit !f}'
}
