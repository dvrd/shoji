#!/usr/bin/env python3
"""Resolve a bounded set of arm64e stub addresses against an exact local cache."""

import argparse
import json
import pathlib
import re
import subprocess


def resolve(cache, address):
    evidence = []

    def run(arguments):
        command = ["ipsw", "dyld", *arguments]
        result = subprocess.run(command, text=True, capture_output=True, timeout=30)
        evidence.append({"command": command, "exit": result.returncode,
                         "stdout": result.stdout, "stderr": result.stderr})
        if result.returncode:
            raise ValueError(f"command failed with exit {result.returncode}")
        return result.stdout + result.stderr

    record = {"stub": address, "evidence": evidence}
    try:
        assembly = run(["disass", cache, "--vaddr", address, "--count", "4", "--quiet"])
        # Match only the observed four-instruction authenticated stub shape.
        patterns = [r"adrp\s+x17, (0x[0-9a-f]+)",
                    r"add\s+x17, x17, #(0x[0-9a-f]+)",
                    r"ldr\s+x16, \[x17\]", r"braa\s+x16, x17"]
        matches = [re.search(pattern, assembly) for pattern in patterns]
        if not all(matches):
            raise ValueError("unsupported stub instruction shape; not guessed")
        slot = int(matches[0][1], 16) + int(matches[1][1], 16)
        record["pointer_slot"] = hex(slot)
        pointer = run(["dump", cache, hex(slot), "--addr", "--count", "1"]).strip()
        if not re.fullmatch(r"0x[0-9a-fA-F]+", pointer):
            raise ValueError("unexpected decoded pointer output")
        record["destination"] = pointer
        mapping = run(["a2s", cache, pointer, "--mapping"])
        symbol = re.search(r"^" + re.escape(pointer) + r": (.+)$", mapping, re.M)
        image = re.search(r"dylib=(\S+) section=(\S+)", mapping)
        if not image:
            raise ValueError("no containing image/section reported")
        record.update(image=image[1], section=image[2],
                      symbol=symbol[1] if symbol else None, status="resolved")
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        record.update(status="unresolved", error=str(error))
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cache")
    parser.add_argument("warnings", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--limit", type=int, default=8)
    args = parser.parse_args()
    if not 1 <= args.limit <= 256:
        parser.error("limit must be between 1 and 256")
    warnings = json.loads(args.warnings.read_text())["addresses"]
    report = {"scope": "static local-cache stub resolution; unsupported shapes remain unknown",
              "cache": args.cache, "items": []}
    for entry in warnings[:args.limit]:
        record = resolve(args.cache, entry["address"])
        record["warning_count"] = entry["warnings"]
        report["items"].append(record)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({key: record.get(key) for key in
                          ("stub", "status", "symbol", "image", "error")}), flush=True)


if __name__ == "__main__":
    main()
