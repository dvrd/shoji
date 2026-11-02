#!/bin/sh
# Transaction-gate experiment on the disposable guest.
# usage: run-tgate.sh TAG [--no-hold | --timeout]
G=/Users/Shared/shoji-ws-observer.Qwiazd
TAG=$1
MODE=$2
OUT=/tmp/shoji-tgate-$TAG
echo "run_tag=$TAG mode=${MODE:-hold}"
echo "guest_start=$(date +%s.%N)"
echo "dump" > /private/tmp/shoji-ws-observer-request
sleep 0.2
case "$MODE" in
  --no-hold) "$G/shoji-ws-ordering-trigger" --txn --no-hold > "$OUT.trigger" 2>&1 & ;;
  *)         "$G/shoji-ws-ordering-trigger" --txn > "$OUT.trigger" 2>&1 & ;;
esac
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
"$G/shoji-ws-visibility-sampler" "$WID" 2000 4000 > "$OUT.vis.csv" 2> "$OUT.vis.err" &
SPID=$!
case "$MODE" in
  --no-hold|--timeout) ;;
  *)
    sleep 1.2
    echo "release_before=$(date +%s.%N)"
    echo "release" > /private/tmp/shoji-ws-observer-request
    echo "release_after=$(date +%s.%N)"
    ;;
esac
wait $TPID
echo "trigger_exit=$?"
wait $SPID
echo "sampler_exit=$?"
echo "release" > /private/tmp/shoji-ws-observer-request
sleep 0.2
echo "dump" > /private/tmp/shoji-ws-observer-request
sleep 0.5
cp /private/tmp/shoji-ws-observer-response-26A434.bin "$OUT.response.bin" 2>/dev/null
cp /private/tmp/shoji-ws-observer-tgate-26A434.bin "$OUT.tgate.bin" 2>/dev/null
echo "guest_end=$(date +%s.%N)"
ls -la "$OUT".*
