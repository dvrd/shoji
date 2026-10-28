#!/bin/zsh
set -eu
stage_dir=/tmp/shoji-dock-move-vm
log_path=/tmp/shoji-dock-move-diagnostic_501.txt
fixture_pid=''
cleanup() {
  if [ -n "$fixture_pid" ]; then kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM
if [ -e "$log_path" ]; then printf 'Diagnostic log already exists; refusing to overwrite %s\n' "$log_path" >&2; exit 1; fi
"$stage_dir/shoji" --check-sa
"$stage_dir/fixture" fixture > "$stage_dir/fixture-test.out" 2> "$stage_dir/fixture-test.err" &
fixture_pid=$!
for n in {1..50}; do [ -s "$stage_dir/fixture-test.out" ] && break; kill -0 "$fixture_pid" 2>/dev/null || break; sleep 0.1; done
if [ ! -s "$stage_dir/fixture-test.out" ]; then cat "$stage_dir/fixture-test.err" >&2; exit 1; fi
read actual_pid first_id second_id < "$stage_dir/fixture-test.out"
if [ "$actual_pid" != "$fixture_pid" ]; then printf 'Fixture PID mismatch\n' >&2; exit 1; fi
"$stage_dir/move-client" "$fixture_pid" "$first_id"
if [ ! -s "$log_path" ]; then printf 'Dock did not write diagnostic stage results\n' >&2; exit 1; fi
cat "$log_path"
