#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
out="$PWD/bin/window-interception"
DYLD_INSERT_LIBRARIES="$out/shoji-window-agent.dylib" "$out/shoji-window-interception-fixture" passthrough
for mode in front key regardless back; do
    SHOJI_WINDOW_INTERCEPTION_FIXTURE=1 DYLD_INSERT_LIBRARIES="$out/shoji-window-agent.dylib" "$out/shoji-window-interception-fixture" "$mode"
done
