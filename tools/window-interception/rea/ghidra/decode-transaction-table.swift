#!/usr/bin/env swift
// Decode the 26A434 SkyLight PKGTransaction dispatch table. Static evidence
// only: reads the carved exact-build SkyLight image and prints the op-type ->
// handler map for the table at unslid 0x1e873d430, whose runtime use was traced
// in PKGTransactionCommit (see transaction-commit.asm):
//     ldrb w28, [cursor]            ; op type byte from the op stream
//     cmp  w8, #0x8b                ; bounds: types 1..0x8c
//     add  x25, x24, x28, lsl #4    ; entry = table + op*16
//     ldr  x8,  [x25]               ; handler (PAC-signed)
//     ldr  x20, [x25, #0x8]         ; per-op metadata/diversity
//     blraaz x8                     ; authenticated indirect call
// Table base is materialized in-code (adrp 0x1e873d000, add #0x430), not passed
// by callers. Entry handlers decode as IMAGE_BASE | (signed & 0xFFFFFF).
// usage: decode-transaction-table.swift [SkyLight path] [TABLE_VA hex]
import Foundation

let argv = Array(CommandLine.arguments.dropFirst())
let path = argv.first ?? "artifacts/macos_versions/26A434/extracted/SkyLight"
let tableVA: UInt64 = argv.count > 1 ? (UInt64(argv[1].replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0) : 0x1E873D430
let opMax: UInt64 = 0x8C

guard let d = FileManager.default.contents(atPath: path) else {
    FileHandle.standardError.write(Data("cannot read \(path)\n".utf8)); exit(1)
}
func load<T>(_ o: Int, _ t: T.Type) -> T { d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: t) } }

let ncmds = load(16, UInt32.self)
var off = 32
var segs: [(va: UInt64, vs: UInt64, fo: UInt64, fs: UInt64)] = []
var symtab: (symoff: UInt32, nsyms: UInt32, stroff: UInt32, strsize: UInt32)?
for _ in 0..<ncmds {
    let cmd = load(off, UInt32.self), cmdsize = load(off + 4, UInt32.self)
    if cmd == 0x19 {
        segs.append((load(off + 24, UInt64.self), load(off + 32, UInt64.self), load(off + 40, UInt64.self), load(off + 48, UInt64.self)))
    } else if cmd == 0x2 {
        symtab = (load(off + 8, UInt32.self), load(off + 12, UInt32.self), load(off + 16, UInt32.self), load(off + 20, UInt32.self))
    }
    off += Int(cmdsize)
}

// Handler pointers decode as IMAGE_BASE | (signed & 0xFFFFFF); derive the base
// from the image itself instead of hardcoding a per-build value.
let textBase = (segs.map(\.va).min() ?? 0) & ~UInt64(0xFFFFFF)

func vaToOff(_ va: UInt64) -> Int? {
    for s in segs where s.va <= va && va < s.va + s.vs { return Int(s.fo + (va - s.va)) }
    return nil
}

var names: [UInt64: String] = [:]
if let st = symtab {
    let base = Int(st.symoff)
    for e in 0..<Int(st.nsyms) {
        let eo = base + e * 16
        let strx = load(eo, UInt32.self)
        let val = load(eo + 8, UInt64.self)
        if names[val] != nil { continue }
        var p = Int(st.stroff) + Int(strx), end = p
        while end < d.count && d[end] != 0 { end += 1 }
        names[val] = String(data: d.subdata(in: p..<end), encoding: .utf8) ?? ""
        _ = p
    }
}

guard let tOff = vaToOff(tableVA) else {
    FileHandle.standardError.write(Data(String(format: "table VA 0x%llx not mapped in \(path)\n", tableVA).utf8)); exit(1)
}

var named = 0
for op in 1...opMax {
    let eo = tOff + Int(op) * 16
    let signed = load(eo, UInt64.self), meta = load(eo + 8, UInt64.self)
    let addr = textBase | (signed & 0xFFFFFF)
    let name = (names[addr] ?? "").drop { $0 == "_" }
    if !name.isEmpty { named += 1 }
    print(String(format: "op %#04llx  signed=%#018llx  handler=%#llx  meta=%#018llx  %@", op, signed, addr, meta, String(name)))
}
print("# \(named) named of \(opMax) ops")
