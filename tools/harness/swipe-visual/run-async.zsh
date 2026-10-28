set -eu
work_dir=$(mktemp -d /tmp/shoji-swipe-async.XXXXXXXX)
fixture_pid=''
rule_name="shoji-async-experiment-$$"
cleanup() {
  if [ -n "$fixture_pid" ]; then kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true; fi
  bin/shoji -m rule --remove "$rule_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
bin/shoji -m rule --add "label=$rule_name" 'title=^Shoji swipe visual fixture (A|B|indicator)$' manage=off
/tmp/shoji-swipe-visual fixture "${1:-slow}" > "$work_dir/fixture.out" 2> "$work_dir/fixture.err" &
fixture_pid=$!
for n in {1..50}; do [ -s "$work_dir/fixture.out" ] && break; kill -0 "$fixture_pid" 2>/dev/null || break; sleep 0.1; done
if [ ! -s "$work_dir/fixture.out" ]; then cat "$work_dir/fixture.err"; printf 'Fixture failed: %s\n' "$work_dir"; exit 1; fi
read actual_pid first_id second_id < "$work_dir/fixture.out"
if [ "$actual_pid" != "$fixture_pid" ]; then printf 'Fixture PID mismatch\n'; exit 1; fi
/tmp/shoji-swipe-visual async "$fixture_pid" "$first_id" "$second_id" "$work_dir/async.json" > "$work_dir/probe.out" 2> "$work_dir/probe.err" || result=$?
cat "$work_dir/probe.out"
cat "$work_dir/probe.err"
if [ "${result:-0}" -eq 0 ]; then
  jq -f tools/harness/swipe-visual/verify-async.jq "$work_dir/async.json" || result=$?
fi
printf 'Probe exit: %s; evidence: %s\n' "${result:-0}" "$work_dir"
exit "${result:-0}"
