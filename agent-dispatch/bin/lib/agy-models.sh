# shellcheck shell=bash
# Single source of truth for agy default models by role. When agy renames a model,
# edit ONLY this file; coding-preflight.sh, dispatch-worker and agent-dispatch-doctor
# fail closed until it matches `agy models`.
# shellcheck disable=SC2034  # consumed by sourcing callers
AGY_MODEL_CODING_DEFAULT="gemini-3.8-flash-medium"
# shellcheck disable=SC2034  # consumed by sourcing callers
AGY_MODEL_REVIEW_DEFAULT="gemini-4-argon-high"

# Return 0 for present, 1 for absent/invalid, 2 for an unparseable list.
agy_model_present() {
  AGY_MODEL_MATCH="$2" awk -F'\t' '
    BEGIN {
      m=ENVIRON["AGY_MODEL_MATCH"]
      check=m; gsub(/ /, "", check)
      invalid=(m == "" || check ~ /[[:space:][:cntrl:]]/)
      if (invalid) exit 1
      m=tolower(m)
    }
    { gsub(/\r/, ""); if (NF < 2) next; parsed=1
      id=tolower($1)
      if (id == m || tolower($2) == m) found=1
      if (index(id, m "-") == 1) offered=offered (offered ? ", " : "") $1
    }
    END {
      if (invalid) exit 1
      if (!parsed) exit 2
      if (found) exit 0
      if (offered != "") {
        printf "agy model %c%s%c has no tier; agy picks one (offered: %s)\n", 39, ENVIRON["AGY_MODEL_MATCH"], 39, offered > "/dev/stderr"
        exit 0
      }
      exit 1
    }' <<EOF_MODELS
$1
EOF_MODELS
}
