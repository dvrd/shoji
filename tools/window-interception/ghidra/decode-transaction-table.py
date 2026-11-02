#!/usr/bin/env python3
"""Decode the 26A434 SkyLight PKGTransaction dispatch table.

Static evidence only. Reads the carved exact-build SkyLight image and prints
the op-type -> handler map for the table at unslid 0x1e873d430, whose runtime
use was traced in PKGTransactionCommit (see transaction-commit.asm):

    ldrb w28, [cursor]                  ; op type byte from the op stream
    cmp  w8, #0x8b                      ; bounds: types 1..0x8c
    add  x25, x24, x28, lsl #4          ; entry = table + op*16
    ldr  x8,  [x25]                     ; handler (PAC-signed)
    ldr  x20, [x25, #0x8]               ; per-op metadata/diversity
    blraaz x8                           ; authenticated indirect call

Table base is materialized in-code (adrp 0x1e873d000, add #0x430), not passed
by callers. Entry handlers decode as 0x187000000 | (signed & 0xFFFFFF) for
this build. usage: decode-transaction-table.py [SkyLight path]
"""
import struct
import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else 'artifacts/windowserver-26A434/extracted/SkyLight'
TABLE_VA = 0x1E873D430
OP_MAX = 0x8C
TEXT_BASE = 0x187000000

d = open(PATH, 'rb').read()
ncmds, = struct.unpack_from('<I', d, 16)
off, segs, symtab = 32, [], None
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack_from('<II', d, off)
    if cmd == 0x19:
        va, vs, fo, fs = struct.unpack_from('<QQQQ', d, off + 24)
        segs.append((va, vs, fo, fs))
    elif cmd == 0x2:
        symtab = struct.unpack_from('<IIII', d, off + 8)
    off += cmdsize

def va_to_off(va):
    for sva, vs, fo, fs in segs:
        if sva <= va < sva + vs:
            return fo + (va - sva)

names = {}
if symtab:
    symoff, nsyms, stroff, _ = symtab
    for e in range(nsyms):
        strx, ntype, nsect, ndesc, val = struct.unpack_from('<IBBHQ', d, symoff + e * 16)
        names.setdefault(val, d[stroff + strx:d.index(b'\0', stroff + strx)].decode(errors='replace'))

t_off = va_to_off(TABLE_VA)
if t_off is None:
    sys.exit(f'table VA {TABLE_VA:#x} not mapped in {PATH}')

named = 0
for op in range(1, OP_MAX + 1):
    signed, meta = struct.unpack_from('<QQ', d, t_off + op * 16)
    addr = TEXT_BASE | (signed & 0xFFFFFF)
    name = names.get(addr, '').lstrip('_')
    named += bool(name)
    print(f'op {op:#04x}  signed={signed:#018x}  handler={addr:#x}  meta={meta:#018x}  {name}')
print(f'# {named} named of {OP_MAX} ops')
