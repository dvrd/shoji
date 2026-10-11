#!/usr/bin/env python3
"""Normalize a thin arm64e Mach-O to the legacy ABI required by Dock injection."""

import struct
import sys
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64E_ABI_V1 = 0x81000002
CPU_SUBTYPE_ARM64E_ABI_V0 = 0x80000002


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} MACH_O", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    data = bytearray(path.read_bytes())
    if len(data) < 32:
        print(f"{path}: truncated Mach-O header", file=sys.stderr)
        return 1

    magic, cputype, cpusubtype = struct.unpack_from("<III", data)
    if magic != MH_MAGIC_64 or cputype != CPU_TYPE_ARM64:
        print(f"{path}: expected a thin arm64 Mach-O binary", file=sys.stderr)
        return 1
    if cpusubtype == CPU_SUBTYPE_ARM64E_ABI_V0:
        return 0
    if cpusubtype != CPU_SUBTYPE_ARM64E_ABI_V1:
        print(f"{path}: expected arm64e ABI v1, found subtype 0x{cpusubtype:08x}", file=sys.stderr)
        return 1

    struct.pack_into("<I", data, 8, CPU_SUBTYPE_ARM64E_ABI_V0)
    path.write_bytes(data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
