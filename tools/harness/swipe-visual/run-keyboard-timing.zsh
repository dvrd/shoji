set -eu
work=$(mktemp -d /tmp/shoji-keyboard-fixture.XXXXXXXX)
rule="shoji-keyboard-test-$$"
fixture=''
controller=''
original=$(bin/shoji -m query --windows | jq -r '.[] | select(."has-focus") | .id' | head -1)
cleanup() {
  [ -z "$controller" ] || kill "$controller" 2>/dev/null || true
  [ -z "$fixture" ] || kill "$fixture" 2>/dev/null || true
  [ -z "$fixture" ] || wait "$fixture" 2>/dev/null || true
  bin/shoji -m rule --remove "$rule" >/dev/null 2>&1 || true
  [ -z "$original" ] || bin/shoji -m window "$original" --focus >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
bin/shoji -m rule --add "label=$rule" 'title=^Shoji swipe visual fixture (A|B)$' manage=off >/dev/null
/tmp/shoji-swipe-visual fixture slow > "$work/fixture.out" 2> "$work/fixture.err" &
fixture=$!
for n in {1..50}; do [ -s "$work/fixture.out" ] && break; kill -0 "$fixture" 2>/dev/null || break; sleep 0.1; done
[ -s "$work/fixture.out" ] || { cat "$work/fixture.err"; exit 1; }
read actual a b < "$work/fixture.out"
[ "$actual" = "$fixture" ] || exit 1
/tmp/shoji-swipe-controller "$fixture" "$work/ready.json" "$work/start" observed "${1:-keyboard}" 4 batch > "$work/controller.out" 2> "$work/controller.err" &
controller=$!
for n in {1..100}; do [ -s "$work/ready.json" ] && break; kill -0 "$controller" 2>/dev/null || break; sleep 0.1; done
[ -s "$work/ready.json" ] || { cat "$work/controller.err"; exit 1; }
touch "$work/start"
if [ "${SHOJI_SAMPLE_CONTROLLER:-0}" = 1 ]; then sample "$controller" 3 1 -file "$work/sample.txt" > "$work/sample.log" 2>&1 & sampler=$!; fi
if [ "${SHOJI_KILL_FIXTURE:-0}" = 1 ]; then (sleep 0.5; kill "$fixture" 2>/dev/null || true) & killer=$!; fi
result=0
wait "$controller" || result=$?
controller=''
if [ "${SHOJI_SAMPLE_CONTROLLER:-0}" = 1 ]; then wait "$sampler" || true; fi
if [ "${SHOJI_KILL_FIXTURE:-0}" = 1 ]; then wait "$killer" || true; fi
cat "$work/controller.err"
awk '/^TRACE: / {sub(/^TRACE: /, ""); print}' "$work/controller.out" > "$work/trace.json"
if [ -s "$work/trace.json" ]; then jq '{frames:([.events[]|select(.kind=="native-frame")]|length),max_ms:([.events[]|select(.kind=="native-frame")|.duration_ms]|max)}' "$work/trace.json"; fi
if [ "$result" -eq 0 ]; then
  expected=80
  [ "${1:-keyboard}" != keyboard-stop ] || expected=20
  awk -v expected="$expected" '/^sample / {t=$4; if (count>0 && (t-prev)>0.05) slow++; prev=t; count++} END {printf "samples=%d intervals_over_50ms=%d\n", count, slow; if (count != expected || slow>0) exit 1}' "$work/controller.out" || result=$?
fi
printf 'result=%s evidence=%s\n' "$result" "$work"
exit "$result"
