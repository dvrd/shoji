#!/bin/sh
# Metadata only: no task ports, attachment, injection, restart or security writes.
set -eu
cd "$(dirname "$0")/../../.."
out="$PWD/docs/evidence/windowserver-24G84"
target=/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
sw_vers > "$out/os.txt"
csrutil status > "$out/sip.txt" 2>&1
csrutil authenticated-root status > "$out/authenticated-root.txt" 2>&1 || true
codesign -dvvv --arch arm64e --entitlements - "$target" > "$out/windowserver-signature.txt" 2>&1
codesign -dvv --arch arm64e /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock > "$out/dock-signature.txt" 2>&1
file "$target" > "$out/windowserver-file.txt"
xcrun otool -arch arm64e -L "$target" > "$out/windowserver-dependencies.txt"
xcrun otool -arch arm64e -l "$target" > "$out/windowserver-load-commands.txt"
xcrun otool -arch arm64e -tvV "$target" > "$out/windowserver-disassembly.txt"
xcrun nm -arch arm64e "$target" > "$out/windowserver-symbols.txt"
ps -axo pid,uid,comm | rg 'WindowServer|/Dock.app/' > "$out/processes.txt"
launchctl print system/com.apple.WindowServer > "$out/windowserver-service.txt"
./bin/window-interception/inspect-server > "$out/skylight-symbols.txt"
