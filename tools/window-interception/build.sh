#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
compiler=${ODIN:-"$PWD/.toolchain/Odin/odin"}
out="$PWD/bin/window-interception"
mkdir -p "$out"
export ODIN_ROOT="$PWD/.toolchain/Odin"
"$compiler" build tools/window-interception/agent -build-mode:dll -no-entry-point -warnings-as-errors -out:"$out/shoji-window-agent.dylib"
"$compiler" build tools/window-interception/fixture -warnings-as-errors -out:"$out/shoji-window-interception-fixture"
codesign --force --sign - "$out/shoji-window-agent.dylib"
codesign --force --sign - "$out/shoji-window-interception-fixture"
