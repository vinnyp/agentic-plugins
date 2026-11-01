#!/usr/bin/env bash
set -eu
mkdir -p "$SCN_TMP/bin"
cat > "$SCN_TMP/bin/agy" <<'STUB'
#!/usr/bin/env bash
case "$MODE" in
 healthy) printf 'gemini-3.8-flash-medium\tCoding\ngemini-4-argon-high\tReview\n' ;;
 missing) printf 'custom-id\tCustom\n' ;;
 unparseable) echo 'format drift' ;;
 dead) echo 'Please sign in' >&2; exit 1 ;;
esac
STUB
chmod +x "$SCN_TMP/bin/agy"
export PATH="$SCN_TMP/bin:$PATH"
for MODE in healthy missing unparseable dead; do
  export MODE
  rc=0
  "$IMPL_BIN/agent-dispatch-doctor" > "$SCN_TMP/doctor.out" 2> "$SCN_TMP/doctor.err" || rc=$?
  case "$MODE" in
    healthy) grep -q 'coding default model present' "$SCN_TMP/doctor.out"; grep -q 'review default model present' "$SCN_TMP/doctor.out" ;;
    missing) [ "$rc" -eq 1 ]; grep -q "coding default model .* not offered" "$SCN_TMP/doctor.out"; grep -q "review default model .* not offered" "$SCN_TMP/doctor.out" ;;
    unparseable) grep -q 'skipping coding model check' "$SCN_TMP/doctor.out"; grep -q 'skipping review model check' "$SCN_TMP/doctor.out" ;;
    dead) grep -q "agy models.*failed" "$SCN_TMP/doctor.out" ;;
  esac
  echo "PASS: doctor $MODE"
done
