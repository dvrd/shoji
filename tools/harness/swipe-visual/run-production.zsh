set -eu
work_dir=$(mktemp -d /tmp/shoji-swipe-production.XXXXXXXX)
fixture_pid=''
controller_pid=''
rule_name="shoji-production-experiment-$$"
cleanup() {
  if [ -n "$controller_pid" ]; then kill "$controller_pid" 2>/dev/null || true; wait "$controller_pid" 2>/dev/null || true; fi
  if [ -n "$fixture_pid" ]; then kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true; fi
  bin/shoji -m rule --remove "$rule_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
bin/shoji -m rule --add "label=$rule_name" 'title=^Shoji swipe visual fixture (A|B)$' manage=off
/tmp/shoji-swipe-visual fixture "${3:-normal}" > "$work_dir/fixture.out" 2> "$work_dir/fixture.err" &
fixture_pid=$!
for n in {1..50}; do [ -s "$work_dir/fixture.out" ] && break; kill -0 "$fixture_pid" 2>/dev/null || break; sleep 0.1; done
if [ ! -s "$work_dir/fixture.out" ]; then cat "$work_dir/fixture.err"; printf 'Fixture failed: %s\n' "$work_dir"; exit 1; fi
read actual_pid first_id second_id < "$work_dir/fixture.out"
if [ "$actual_pid" != "$fixture_pid" ]; then printf 'Fixture PID mismatch\n'; exit 1; fi
/tmp/shoji-swipe-controller "$fixture_pid" "$work_dir/ready.json" "$work_dir/start" "${1:-observed}" "${2:-normal}" "${4:-4}" "${5:-batch}" > "$work_dir/controller.out" 2> "$work_dir/controller.err" &
controller_pid=$!
for n in {1..100}; do [ -s "$work_dir/ready.json" ] && break; kill -0 "$controller_pid" 2>/dev/null || break; sleep 0.1; done
if [ ! -s "$work_dir/ready.json" ]; then cat "$work_dir/controller.err"; printf 'Controller failed: %s\n' "$work_dir"; exit 1; fi
cat "$work_dir/ready.json"
/tmp/shoji-swipe-visual observe "$work_dir/ready.json" "$work_dir/start" "$work_dir/frames.json" > "$work_dir/capture.out" 2> "$work_dir/capture.err" || capture_result=$?
cat "$work_dir/capture.out"
cat "$work_dir/capture.err"
if [ "${capture_result:-0}" -ne 0 ]; then printf 'Capture failed: %s\n' "$work_dir"; exit "$capture_result"; fi
wait "$controller_pid" || controller_result=$?
controller_pid=''
cat "$work_dir/controller.err"
printf 'Controller exit: %s; evidence: %s\n' "${controller_result:-0}" "$work_dir"
exit "${controller_result:-0}"
