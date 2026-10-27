#!/bin/zsh
emulate -L zsh

project_root=${0:A:h:h:h}
workspace="$project_root/artifacts/macos27-vm"
image="$workspace/UniversalMac_27.0.1_26A434_Restore.ipsw"
probe="$project_root/bin/shoji-vm-preflight"
if [[ ! -x "$probe" ]]; then
    print -u2 -r -- "Build the probe first: task build:vm-preflight"
    exit 66
fi
mkdir -p "$workspace"
url='https://updates.cdn-apple.com/2026FallFCS/59241290-5d51-4ca8-9df4-31624b9a4eac/UniversalMac_27.0.1_26A434_Restore.ipsw'

trap 'exit 130' INT
trap 'exit 143' TERM
for attempt in {1..10}; do
    print -r -- "Download attempt $attempt/10 (resuming the existing file)"
    /usr/bin/curl --fail --location --continue-at - --progress-bar \
        --connect-timeout 30 --speed-limit 1024 --speed-time 120 \
        --output "$image" "$url"
    result=$?
    if (( result == 0 )); then
        exec "$probe" "$image"
    fi
    if (( result == 130 )); then
        exit 130
    fi
    if (( attempt < 10 )); then
        print -u2 -r -- "Transfer stopped (curl $result). Resuming in 5 seconds..."
        sleep 5
    fi
done
print -u2 -r -- "Download incomplete. Partial file retained; rerun this script to resume."
exit 1
