#!/bin/sh
# Pixel-level hold verification on the disposable guest.
# Captures the trigger window's own SCStream frames across a gated hold and
# checks whether any complete frame's displayTime precedes the release.
# usage: run-pixel.sh TAG [--no-hold]
G=/Users/Shared/shoji-ws-observer.Qwiazd
TAG=$1
MODE=$2
OUT=/tmp/shoji-pixel-$TAG
echo "run_tag=$TAG mode=${MODE:-hold}"
echo "guest_start=$(date +%s.%N)"
echo "dump" > /private/tmp/shoji-ws-observer-request
sleep 0.2
"$G/shoji-ws-ordering-trigger" $MODE > "$OUT.trigger" 2>&1 &
TPID=$!
WID=""
i=0
while [ $i -lt 100 ]; do
  WID=$(sed -n 's/^window=//p' "$OUT.trigger" 2>/dev/null | head -1)
  [ -n "$WID" ] && break
  sleep 0.05
  i=$((i + 1))
done
echo "wid=$WID"
if [ -z "$WID" ]; then
  echo "FAIL: trigger did not report a window id"
  exit 1
fi
"$G/shoji-capture-probe" "$WID" 4000 > "$OUT.frames.csv" 2> "$OUT.frames.err" &
CPID=$!
"$G/shoji-ws-visibility-sampler" "$WID" 2000 4000 > "$OUT.vis.csv" 2> "$OUT.vis.err" &
SPID=$!
if [ "$MODE" != "--no-hold" ]; then
  sleep 1.2
  echo "release_before=$(date +%s.%N)"
  echo "release" > /private/tmp/shoji-ws-observer-request
  echo "release_after=$(date +%s.%N)"
fi
wait $TPID
echo "trigger_exit=$?"
wait $CPID
echo "capture_exit=$?"
wait $SPID
echo "sampler_exit=$?"
# Force a fresh dump: identical consecutive request content is deduplicated by
# the observer, so toggle through a harmless release first.
echo "release" > /private/tmp/shoji-ws-observer-request
sleep 0.2
echo "dump" > /private/tmp/shoji-ws-observer-request
sleep 0.5
cp /private/tmp/shoji-ws-observer-response-26A434.bin "$OUT.response.bin" 2>/dev/null
echo "guest_end=$(date +%s.%N)"
ls -la "$OUT".*
