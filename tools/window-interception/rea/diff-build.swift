#!/usr/bin/env swift
// Diff two per-build port models (A3). Compares
// artifacts/macos_versions/<tag>/model/model.json pairs and prints a porting
// report: identity, hooked function, dispatch table base, and the op map.
// Op-name movement is the porting signal; raw address changes are expected on
// every build. usage: diff-build.swift REF_TAG NEW_TAG
import Foundation

let argv = Array(CommandLine.arguments.dropFirst())
guard argv.count == 2 else { FileHandle.standardError.write(Data("usage: diff-build.swift REF_TAG NEW_TAG\n".utf8)); exit(1) }

func git(_ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git"] + args
    let o = Pipe(); p.standardOutput = o; try? p.run(); p.waitUntilExit()
    return String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}
let root = git(["rev-parse", "--show-toplevel"])
func load(_ tag: String) -> [String: Any] {
    let path = "\(root)/artifacts/macos_versions/\(tag)/model/model.json"
    guard let d = FileManager.default.contents(atPath: path),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
        FileHandle.standardError.write(Data("cannot read \(path)\n".utf8)); exit(1)
    }
    return j
}
let ref = load(argv[0]), new = load(argv[1])
func s(_ v: Any?) -> String { v as? String ?? "null" }

print("=== \(argv[0]) -> \(argv[1])")
let ruuid = s(ref["uuid"]), nuuid = s(new["uuid"])
print("uuid:            \(ruuid) -> \(nuuid)  \(ruuid == nuuid ? "MATCH" : "CHANGED (gates will refuse)")")

let rh = ref["hooked_function"] as? [String: Any] ?? [:], nh = new["hooked_function"] as? [String: Any] ?? [:]
print("hooked function: \(s(rh["address"])) -> \(s(nh["address"]))")
let re = (rh["entry"] as? [[String: Any]]) ?? [], ne = (nh["entry"] as? [[String: Any]]) ?? []
let rb = re.map { s($0["bytes"]) }, nb = ne.map { s($0["bytes"]) }
print("entry bytes:     \(rb == nb ? "MATCH" : "CHANGED — re-verify prologue/trampoline")")
for (a, b) in zip(re, ne) {
    let mark = s(a["bytes"]) == s(b["bytes"]) ? " " : "!"
    print("  \(mark) \(s(a["bytes"]))  \(s(a["insn"]))   |   \(s(b["bytes"]))  \(s(b["insn"]))")
}

let rt = ref["dispatch_table"] as? [String: Any] ?? [:], nt = new["dispatch_table"] as? [String: Any] ?? [:]
print("dispatch table:  \(s(rt["base"])) -> \(s(nt["base"]))")
let rops = rt["ops"] as? [String: [String: Any]] ?? [:], nops = nt["ops"] as? [String: [String: Any]] ?? [:]
let rk = Set(rops.keys), nk = Set(nops.keys)
let missing = rk.subtracting(nk).sorted(), added = nk.subtracting(rk).sorted()
let common = rk.intersection(nk).sorted()
let renamed = common.filter { s(rops[$0]?["name"]) != s(nops[$0]?["name"]) }
let moved = common.filter { s(rops[$0]?["handler"]) != s(nops[$0]?["handler"]) }
func listOrNone(_ a: [String]) -> String { a.isEmpty ? "none" : "[" + a.joined(separator: ", ") + "]" }
print("ops: ref=\(rops.count) new=\(nops.count)")
print("  missing ops:  \(listOrNone(missing))")
print("  added ops:    \(listOrNone(added))")
print("  renamed ops:  \(listOrNone(renamed))")
print("  moved handlers (expected on any build): \(moved.count)")
let gatedOps: Set<Int> = [0x01, 0x03, 0x06, 0x0b, 0x18, 0x19, 0x21, 0x22, 0x2a, 0x33, 0x34, 0x35, 0x36, 0x41]
let gated = moved.filter { gatedOps.contains(Int($0.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? -1) }
print("  gated ops moved: \(listOrNone(gated))")
let verdict = (ruuid == nuuid && rb == nb && missing.isEmpty && renamed.isEmpty) ? "PORT CLEAN" : "PORT NEEDED"
print("verdict: \(verdict)")
