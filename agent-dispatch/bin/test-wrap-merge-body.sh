#!/usr/bin/env bash
# Regression for wrap-merge-body.sh.
#
# The load-bearing case is a PURE LINE-LENGTH assertion over the real body of
# 3957b55 — the commit whose 164/349/184/365/341-character body lines reached
# public main unlintable. It deliberately does NOT shell out to commitlint:
# run-tests.sh runs at CI step 22 and commitlint is not installed until step
# 199, so a regression that called it would find nothing and pass for the wrong
# reason. Where a case genuinely needs a linter present or absent, it builds the
# condition itself (a PATH without commitlint; a stub named exactly `commitlint`)
# rather than asking the environment what it happens to have.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAP="$SCRIPT_DIR/wrap-merge-body.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIMIT=100
OFFENDER=3957b55

pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# A PATH that provably lacks commitlint, for the fail-closed case.
NO_CL_DIR="$TMP_DIR/no-commitlint"
mkdir -p "$NO_CL_DIR"
NO_CL_PATH="$NO_CL_DIR:/usr/bin:/bin:/usr/sbin:/sbin"

# A stub named exactly `commitlint` — the real command name, because a stub named
# anything else is not on the code path under test. It records its argv so a case
# can assert HOW the message and the config reached it.
STUB_DIR="$TMP_DIR/stub"
mkdir -p "$STUB_DIR"
make_stub() {
  local rc="$1"
  cat > "$STUB_DIR/commitlint" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TMP_DIR/commitlint-argv.txt"
exit $rc
STUB
  chmod +x "$STUB_DIR/commitlint"
}
STUB_PATH="$STUB_DIR:/usr/bin:/bin:/usr/sbin:/sbin"

longest_line() {            # prints the longest line length in a file
  awk 'length($0) > m { m = length($0) } END { print m + 0 }' "$1"
}

# --- Case 1: the script carries its exec bit -------------------------------
# run-tests.sh shellchecks only executable entrypoints, so a wrapper that lost
# its exec bit would silently drop out of the lint set.
if [ -x "$WRAP" ]; then ok "wrap-merge-body.sh is executable"
else bad "wrap-merge-body.sh is not executable (run-tests.sh would skip it)"; fi

if [ ! -f "$WRAP" ]; then
  echo "FAIL: $WRAP does not exist"
  echo "pass=$pass fail=$((fail + 1))"
  exit 1
fi

# --- Case 2: the real 3957b55 body, wrapped, every line within the limit ---
BODY="$TMP_DIR/offender-body.txt"
if ! git -C "$REPO_ROOT" cat-file -e "$OFFENDER^{commit}" 2>/dev/null; then
  bad "commit $OFFENDER is not in this checkout — CI checks out with fetch-depth: 0 so it must be"
else
  git -C "$REPO_ROOT" log -1 --format=%b "$OFFENDER" > "$BODY"
  before_max="$(longest_line "$BODY")"
  if [ "$before_max" -le "$LIMIT" ]; then
    bad "fixture is not the real offender: longest body line is $before_max (expected > $LIMIT)"
  else
    ok "fixture is the real offender: longest raw body line is $before_max characters"
  fi
  OUT="$TMP_DIR/offender-wrapped.txt"
  if "$WRAP" --subject "feat(x): a subject" --body-file "$BODY" --wrap-only --out "$OUT" >/dev/null 2>"$TMP_DIR/err2"; then
    after_max="$(longest_line "$OUT")"
    if [ "$after_max" -le "$LIMIT" ]; then
      ok "every wrapped line is within $LIMIT characters (longest: $after_max)"
    else
      bad "a wrapped line is $after_max characters, over the $LIMIT limit"
    fi
    # Wrapping must not lose or reorder text: compare the word streams.
    if [ "$(tr -s '[:space:]' '\n' < "$BODY" | sed '/^$/d' | shasum | cut -d' ' -f1)" \
       = "$(tr -s '[:space:]' '\n' < "$OUT" | sed '/^$/d' | tail -n +4 | shasum | cut -d' ' -f1)" ]; then
      ok "wrapping preserved every word of the body in order"
    else
      bad "wrapping changed the body's word stream"
    fi
  else
    bad "wrapping the real offender exited $? (stderr: $(cat "$TMP_DIR/err2"))"
  fi
fi

# --- Case 3: trailers pass through unwrapped -------------------------------
# foundry-reconcile-closures.sh parses ^Refs:( <repo>#N)+$ — a naive wrapper
# that folded that line would silently break closure parsing. The Refs fixture
# is deliberately OVER the limit: a short trailer survives a wrapper with no
# trailer rule at all, so it could never tell the two apart. Six references on
# one line is what a multi-issue wave actually produces.
LONG_REFS="Refs: vinnyp/foundry#202 vinnyp/foundry#197 vinnyp/foundry#203 vinnyp/foundry#196 vinnyp/foundry#199 vinnyp/foundry#206"
TRAILER_BODY="$TMP_DIR/trailers.txt"
{
  echo "A paragraph long enough that the wrapper has to fold it, which is the whole point of running it over a body that a human assembled by hand at merge time."
  echo
  echo "$LONG_REFS"
  echo "Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
  echo "Claude-Session: https://claude.ai/code/session_01LgQFDgw9nCazGcbfbyqsUR"
} > "$TRAILER_BODY"
if [ "${#LONG_REFS}" -le "$LIMIT" ]; then
  bad "the Refs fixture is only ${#LONG_REFS} characters — under the limit it cannot discriminate"
else
  ok "the Refs fixture is ${#LONG_REFS} characters, over the $LIMIT limit, so only passthrough can preserve it"
fi
TRAILER_OUT="$TMP_DIR/trailers-out.txt"
if "$WRAP" --subject "fix: keep trailers intact" --body-file "$TRAILER_BODY" --wrap-only --out "$TRAILER_OUT" >/dev/null 2>&1; then
  miss=""
  while IFS= read -r want; do
    grep -qxF -- "$want" "$TRAILER_OUT" || miss="$miss [$want]"
  done <<WANT
$LONG_REFS
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LgQFDgw9nCazGcbfbyqsUR
WANT
  if [ -z "$miss" ]; then ok "trailer lines came through verbatim and unwrapped"
  else bad "trailer lines were altered or folded:$miss"; fi
  if grep -qE '^Refs:( [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+)+$' "$TRAILER_OUT"; then
    ok "the Refs trailer still matches the closure parser's pattern"
  else
    bad "the Refs trailer no longer matches ^Refs:( <repo>#N)+\$"
  fi
  # The prose must still be folded; only the trailer block is exempt.
  prose_max="$(grep -vE '^(Refs|Co-Authored-By|Claude-Session):' "$TRAILER_OUT" \
    | awk 'length($0) > m { m = length($0) } END { print m + 0 }')"
  if grep -qE '^A paragraph long enough' "$TRAILER_OUT" && [ "$prose_max" -le "$LIMIT" ]; then
    ok "the prose beside the trailers was still wrapped (longest non-trailer line: $prose_max)"
  else
    bad "the prose paragraph was not wrapped (longest non-trailer line $prose_max)"
  fi
else
  bad "the trailer body exited non-zero"
fi

# --- Case 4: an unwrappable token is refused, not emitted over-long --------
URL_BODY="$TMP_DIR/url.txt"
{
  echo "See the run log:"
  echo "https://example.invalid/a/very/long/path/that/no/amount/of/word/wrapping/can/ever/fold/because/it/carries/no/spaces/at/all/run-12345"
} > "$URL_BODY"
url_stdout="$("$WRAP" --subject "docs: link the run log" --body-file "$URL_BODY" --wrap-only 2>"$TMP_DIR/url-err")"
url_rc=$?
if [ "$url_rc" -eq 1 ]; then ok "an unwrappable token exits 1 (refuse)"
else bad "an unwrappable token exited $url_rc, expected 1"; fi
if grep -q "cannot be wrapped" "$TMP_DIR/url-err"; then
  ok "the refusal names the unwrappable token"
else
  bad "the refusal message is missing (stderr: $(cat "$TMP_DIR/url-err"))"
fi
if [ -z "$(printf '%s\n' "$url_stdout" | awk -v l="$LIMIT" 'length($0) > l')" ]; then
  ok "no over-long line was emitted before the refusal"
else
  bad "an over-long line was emitted despite the refusal"
fi

# --- Case 5: a body whose first line starts with `-` is text --------------
DASH_BODY="$TMP_DIR/dash.txt"
{
  echo "--repo vinnyp/other"
  echo "and a second line."
} > "$DASH_BODY"
if dash_out="$("$WRAP" --subject "fix: a dash-leading body" --body-file "$DASH_BODY" --wrap-only 2>"$TMP_DIR/dash-err")"; then
  if printf '%s\n' "$dash_out" | grep -qxF -- "--repo vinnyp/other"; then
    ok "a body whose first line begins with \`-\` is carried as text"
  else
    bad "the dash-leading first line did not survive as text"
  fi
else
  bad "a dash-leading body exited $? (stderr: $(cat "$TMP_DIR/dash-err"))"
fi

# --- Case 6: no repo/PR selector is accepted on the command line ----------
"$WRAP" --subject "fix: x" --repo vinnyp/other --body-file "$DASH_BODY" --wrap-only >/dev/null 2>"$TMP_DIR/sel-err"
sel_rc=$?
if [ "$sel_rc" -eq 2 ]; then ok "an unknown selector flag is a usage error (rc 2)"
else bad "--repo exited $sel_rc, expected 2"; fi

# --- Case 7: commitlint absent is rc 2, never a pass ----------------------
if PATH="$NO_CL_PATH" command -v commitlint >/dev/null 2>&1; then
  bad "the no-commitlint PATH still resolves commitlint — the case cannot prove anything"
else
  PATH="$NO_CL_PATH" "$WRAP" --subject "fix: x" --body-file "$DASH_BODY" >/dev/null 2>"$TMP_DIR/nocl-err"
  nocl_rc=$?
  if [ "$nocl_rc" -eq 2 ]; then ok "an absent commitlint exits 2"
  else bad "an absent commitlint exited $nocl_rc, expected 2"; fi
  if grep -q "commitlint not found" "$TMP_DIR/nocl-err"; then
    ok "the absent-linter refusal says so specifically"
  else
    bad "the absent-linter refusal message is missing (stderr: $(cat "$TMP_DIR/nocl-err"))"
  fi
fi

# --- Case 8: an absent config is rc 2 as well -----------------------------
make_stub 0
PATH="$STUB_PATH" "$WRAP" --subject "fix: x" --body-file "$DASH_BODY" --config "$TMP_DIR/no-such-config.cjs" >/dev/null 2>"$TMP_DIR/nocfg-err"
nocfg_rc=$?
if [ "$nocfg_rc" -eq 2 ]; then ok "an absent config exits 2"
else bad "an absent config exited $nocfg_rc, expected 2"; fi
if grep -q "no commitlint config" "$TMP_DIR/nocfg-err"; then
  ok "the absent-config refusal says so specifically"
else
  bad "the absent-config refusal message is missing (stderr: $(cat "$TMP_DIR/nocfg-err"))"
fi

# --- Case 9: a lint violation is rc 1 -------------------------------------
make_stub 1
PATH="$STUB_PATH" "$WRAP" --subject "fix: x" --body-file "$DASH_BODY" >/dev/null 2>&1
viol_rc=$?
if [ "$viol_rc" -eq 1 ]; then ok "a commitlint violation exits 1"
else bad "a commitlint violation exited $viol_rc, expected 1"; fi

# --- Case 10: the message reaches commitlint by FILE, against the config --
make_stub 0
rm -f "$TMP_DIR/commitlint-argv.txt"
if PATH="$STUB_PATH" "$WRAP" --subject "fix: x" --body-file "$DASH_BODY" >/dev/null 2>&1; then
  argv="$TMP_DIR/commitlint-argv.txt"
  if [ -f "$argv" ]; then
    edit_arg="$(awk '/^--edit$/ { getline; print; exit }' "$argv")"
    cfg_arg="$(awk '/^--config$/ { getline; print; exit }' "$argv")"
    if [ -n "$edit_arg" ] && [ "$edit_arg" != "$DASH_BODY" ]; then
      ok "the message reached commitlint as --edit <temp file>, not as argv text"
    else
      bad "commitlint was not given a --edit file distinct from the body file (got: $edit_arg)"
    fi
    if [ "$cfg_arg" = "$REPO_ROOT/commitlint.config.cjs" ]; then
      ok "the config resolved to the repository's committed commitlint.config.cjs"
    else
      bad "the config resolved to '$cfg_arg', expected $REPO_ROOT/commitlint.config.cjs"
    fi
  else
    bad "the commitlint stub was never invoked"
  fi
else
  bad "a clean lint exited non-zero"
fi

# --- Case 11: a body containing a glob is not expanded --------------------
GLOB_DIR="$TMP_DIR/globcwd"
mkdir -p "$GLOB_DIR"
: > "$GLOB_DIR/decoy.md"
GLOB_BODY="$TMP_DIR/glob.txt"
echo "This paragraph is deliberately long enough to force the word loop to run, and it mentions *.md and a ? so a wrapper that forgot set -f would expand them against the working directory." > "$GLOB_BODY"
if glob_out="$(cd "$GLOB_DIR" && "$WRAP" --subject "docs: globs" --body-file "$GLOB_BODY" --wrap-only 2>&1)"; then
  if printf '%s\n' "$glob_out" | grep -qF -- '*.md' && ! printf '%s\n' "$glob_out" | grep -qF 'decoy.md'; then
    ok "a glob in the body is carried literally, not expanded against the cwd"
  else
    bad "the body's glob was expanded against the working directory"
  fi
else
  bad "the glob body exited non-zero"
fi

# --- Case 12: usage errors --------------------------------------------------
"$WRAP" --body-file "$DASH_BODY" --wrap-only >/dev/null 2>&1
if [ "$?" -eq 2 ]; then ok "a missing --subject is a usage error"; else bad "a missing --subject did not exit 2"; fi
"$WRAP" --subject "fix: x" --wrap-only >/dev/null 2>&1
if [ "$?" -eq 2 ]; then ok "a missing --body-file is a usage error"; else bad "a missing --body-file did not exit 2"; fi
"$WRAP" --subject "fix: x" --body-file "$TMP_DIR/does-not-exist.txt" --wrap-only >/dev/null 2>&1
if [ "$?" -eq 2 ]; then ok "an unreadable --body-file is a usage error"; else bad "an unreadable --body-file did not exit 2"; fi
"$WRAP" --subject --wrap-only >/dev/null 2>&1
if [ "$?" -eq 2 ]; then ok "a flag consumed as --subject's value still fails on the missing body"; else bad "--subject --wrap-only did not exit 2"; fi

# --- Case 13: --body-file - reads stdin -------------------------------------
if stdin_out="$(printf 'a short body line.\n' | "$WRAP" --subject "fix: stdin" --body-file - --wrap-only 2>&1)"; then
  if printf '%s\n' "$stdin_out" | grep -qxF "a short body line."; then
    ok "--body-file - reads the body from stdin"
  else
    bad "--body-file - did not carry the stdin body through"
  fi
else
  bad "--body-file - exited non-zero: $stdin_out"
fi

echo "pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
