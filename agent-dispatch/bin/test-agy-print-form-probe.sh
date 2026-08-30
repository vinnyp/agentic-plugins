#!/usr/bin/env bash
# Test agy-print-form-probe.sh: agy 1.1.22 accepts the
# bare-stdin form (`agy < prompt`) and rejects the legacy `agy exec -` /
# `agy - < prompt` forms. We stub `agy` (never call the real binary) and assert
# the probe gates on the actual form dispatch-worker uses.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PROBE="$SELF_DIR/agy-print-form-probe.sh"
PREFLIGHT="$SELF_DIR/coding-preflight.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

mkdir -p "$TMP/bin" "$TMP/home"
export HOME="$TMP/home"
PATH_ORIG="$PATH"
export PATH="$TMP/bin:$PATH"
export AGY_FORM_PROBE_TIMEOUT="2s"

# shellcheck disable=SC1090
. "$PROBE"

write_stub() {
  # $1 = bare-stdin mode (echo|hang|silent|garbage|slow11|slow2)
  # $2 = legacy mode for `agy exec -` / `agy -` / `agy -p` (same set)
  cat > "$TMP/bin/agy" <<STUB
#!/usr/bin/env bash
emit_mode() {
  prompt="\$1"
  mode="\$2"
  case "\$mode" in
    echo)    printf '%s\n' "\$prompt" | grep -oE 'AGY_FORM_PROBE_[A-Za-z0-9_]+' | head -1 ;;
    hang)    sleep 30 ;;
    silent)  exit 1 ;;
    garbage) printf '%s\n' "OK, sure, here is a totally unrelated reply." ;;
    slow11)  sleep 11; printf '%s\n' "\$prompt" | grep -oE 'AGY_FORM_PROBE_[A-Za-z0-9_]+' | head -1 ;;
    slow2)   sleep 2; printf '%s\n' "\$prompt" | grep -oE 'AGY_FORM_PROBE_[A-Za-z0-9_]+' | head -1 ;;
  esac
}

case "\${1:-}" in
  models)
    case "\${AGY_STUB_MODE:-healthy}" in
      healthy) printf '%s\n' 'Gemini 3.1 Pro (High)'; exit 0 ;;
      dead)    printf '%s\n' 'Error: Please sign in to view available models. Launch the CLI without arguments to sign in.' >&2; exit 1 ;;
    esac
    ;;
  exec)
    emit_mode "\$(cat)" "$2"
    ;;
  -)
    emit_mode "\$(cat)" "$2"
    ;;
  -p)
    emit_mode "\${2:-}" "$2"
    ;;
  *)
    emit_mode "\$(cat)" "$1"
    ;;
esac
STUB
  chmod +x "$TMP/bin/agy"
}

# 1. bare stdin works — probe returns 0.
write_stub echo hang
agy_print_form_probe >"$TMP/t1.out" 2>"$TMP/t1.err"
rc=$?
[ "$rc" -eq 0 ] || fail "bare-stdin works case should return rc 0, got $rc (err: $(cat "$TMP/t1.err"))"
grep -q "bare-stdin form round-trips the sentinel" "$TMP/t1.err" || fail "bare-stdin works case did not confirm the bare-stdin form"
echo "test 1 (bare stdin works -> rc 0) PASS"

# 2. rc=0 with wrong content is still a hard failure.
write_stub garbage garbage
agy_print_form_probe >"$TMP/t2.out" 2>"$TMP/t2.err"
rc=$?
[ "$rc" -eq 1 ] || fail "garbage-output case should fail closed rc 1, got $rc (err: $(cat "$TMP/t2.err"))"
grep -q "bare-stdin form did NOT round-trip the sentinel" "$TMP/t2.err" || fail "garbage-output case did not report bare stdin as non-round-tripping"
grep -qi "FAIL CLOSED" "$TMP/t2.err" || fail "garbage-output case did not fail closed"
echo "test 2 (rc=0 with wrong content is NOT reported healthy) PASS"

# 3. bare stdin broken + legacy form working still fails closed. This is the
# important 1.1.22 contract: preflight must not proceed just because an obsolete
# invocation shape happens to answer in a stub or future wrapper.
write_stub silent echo
agy_print_form_probe >"$TMP/t3.out" 2>"$TMP/t3.err"
rc=$?
[ "$rc" -eq 1 ] || fail "bare-stdin-broken + legacy-working should fail closed rc 1, got $rc (err: $(cat "$TMP/t3.err"))"
grep -qi "FAIL CLOSED" "$TMP/t3.err" || fail "bare-stdin-broken case did not fail closed"
echo "test 3 (bare stdin broken + legacy works -> rc 1 fail closed) PASS"

# 4. bare stdin hang is bounded.
write_stub hang echo
start_ts=$(date +%s)
agy_print_form_probe >"$TMP/t4.out" 2>"$TMP/t4.err"
rc=$?
end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))
[ "$rc" -eq 1 ] || fail "bare-stdin hang should fail closed rc 1, got $rc"
[ "$elapsed" -lt 15 ] || fail "bare-stdin hang took ${elapsed}s — the probe did not bound the call"
echo "test 4 (bare stdin hangs -> probe still returns promptly, rc 1) PASS"

# 5. missing agy binary -> rc 2 (cannot probe), distinct from fail-closed rc 1.
rm -f "$TMP/bin/agy"
AGY_BIN="agy-does-not-exist" agy_print_form_probe >"$TMP/t5.out" 2>"$TMP/t5.err"
rc=$?
[ "$rc" -eq 2 ] || fail "missing binary should return rc 2, got $rc"
write_stub echo hang
echo "test 5 (missing agy binary -> rc 2) PASS"

# 6. missing timeout/gtimeout -> rc 2 advisory.
old_path="$PATH"
PATH="$TMP/bin" AGY_BIN="$TMP/bin/agy" agy_print_form_probe >"$TMP/t6.out" 2>"$TMP/t6.err"
rc=$?
PATH="$old_path"
[ "$rc" -eq 2 ] || fail "missing timeout/gtimeout should return rc 2, got $rc"
echo "test 6 (missing timeout/gtimeout -> rc 2) PASS"

# 7. coding-preflight.sh agy wires the form probe and proceeds when bare stdin works.
write_stub echo hang
AGY_STUB_MODE=healthy "$PREFLIGHT" agy >"$TMP/t7.out" 2>"$TMP/t7.err"
rc=$?
[ "$rc" -eq 0 ] || fail "preflight with a healthy bare-stdin probe should exit 0, got $rc (err: $(cat "$TMP/t7.err"))"
grep -q '^PREFLIGHT=ok$' "$TMP/t7.out" || fail "preflight with a healthy bare-stdin probe missing PREFLIGHT=ok"
echo "test 7 (coding-preflight agy: healthy bare stdin proceeds) PASS"

# 8. coding-preflight.sh agy: bare stdin broken + legacy working -> FAILS closed.
write_stub silent echo
AGY_STUB_MODE=healthy "$PREFLIGHT" agy >"$TMP/t8.out" 2>"$TMP/t8.err"
rc=$?
[ "$rc" -ne 0 ] || fail "preflight with broken bare stdin should NOT exit 0"
grep -q '^PREFLIGHT=ok$' "$TMP/t8.out" && fail "preflight with broken bare stdin must not emit PREFLIGHT=ok"
grep -qi "bare stdin" "$TMP/t8.out" || grep -qi "bare stdin" "$TMP/t8.err" || fail "preflight failure should name bare stdin"
echo "test 8 (coding-preflight agy: broken bare stdin fails closed even if legacy works) PASS"

# 9. default timeout remains calibrated at 30s.
grep -q 'AGY_FORM_PROBE_TIMEOUT:-30s' "$PROBE" || fail "default AGY_FORM_PROBE_TIMEOUT is not 30s in $PROBE"
echo "test 9 (default probe timeout is 30s) PASS"

# 10. Behavioral proof of the 30s default: an 11s answer passes.
write_stub slow11 hang
start_ts=$(date +%s)
( unset AGY_FORM_PROBE_TIMEOUT; agy_print_form_probe >"$TMP/t10.out" 2>"$TMP/t10.err" )
rc=$?
end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))
[ "$rc" -eq 0 ] || fail "11s-equivalent response under the real 30s default should PASS (rc 0), got $rc (err: $(cat "$TMP/t10.err"))"
grep -q "bare-stdin form round-trips the sentinel" "$TMP/t10.err" || fail "11s-equivalent response did not round-trip under the real default"
[ "$elapsed" -ge 10 ] || fail "11s-equivalent case finished in ${elapsed}s — suspiciously fast, the stub's sleep may not have run"
[ "$elapsed" -lt 30 ] || fail "11s-equivalent case took ${elapsed}s — did not finish comfortably under the 30s cap"
echo "test 10 (real 30s default: an 11s-equivalent round trip passes) PASS"

# 11. Short cap + slower bare-stdin response fails closed quickly.
write_stub slow2 silent
start_ts=$(date +%s)
AGY_FORM_PROBE_TIMEOUT="1s" agy_print_form_probe >"$TMP/t11.out" 2>"$TMP/t11.err"
rc=$?
end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))
[ "$rc" -eq 1 ] || fail "response slower than a short cap should fail closed (rc 1), got $rc (err: $(cat "$TMP/t11.err"))"
grep -qi "FAIL CLOSED" "$TMP/t11.err" || fail "response slower than a short cap did not fail closed with a clear message"
[ "$elapsed" -lt 3 ] || fail "capped-timeout case took ${elapsed}s — the short cap did not bound the slow stub"
echo "test 11 (short cap + slower bare-stdin response fails closed) PASS"

export PATH="$TMP/bin:$PATH_ORIG"
echo "ALL PASS"
