#!/usr/bin/env swift
// Resolve a bounded set of arm64e stub addresses against an exact local cache.
// usage: resolve-stubs.swift CACHE WARNINGS.json OUTPUT.json [--limit N]
import Foundation

func rx(_ s: String, _ pat: String, _ group: Int = 1) -> String? {
    guard let re = try? NSRegularExpression(pattern: pat, options: [.anchorsMatchLines]),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
          let r = Range(m.range(at: group), in: s) else { return nil }
    return String(s[r])
}
func hex(_ s: String) -> Int? { Int(s.replacingOccurrences(of: "0x", with: ""), radix: 16) }

var cache = "", warningsPath = "", outputPath = "", limit = 8
var positional: [String] = []
var it = Array(CommandLine.arguments.dropFirst()).makeIterator()
while let a = it.next() {
    if a == "--limit", let v = it.next(), let n = Int(v) { limit = n } else { positional.append(a) }
}
guard positional.count == 3 else { FileHandle.standardError.write(Data("usage: resolve-stubs.swift CACHE WARNINGS OUTPUT [--limit N]\n".utf8)); exit(2) }
cache = positional[0]; warningsPath = positional[1]; outputPath = positional[2]
guard (1...256).contains(limit) else { FileHandle.standardError.write(Data("limit must be between 1 and 256\n".utf8)); exit(2) }

func ipsw(_ args: [String]) throws -> (code: Int32, out: String, cmd: [String]) {
    let cmd = ["ipsw", "dyld"] + args
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = cmd
    let o = Pipe(), e = Pipe(); p.standardOutput = o; p.standardError = e
    try p.run(); p.waitUntilExit()
    let out = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let err = String(data: e.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (p.terminationStatus, out + err, cmd)
}

struct Resolve { var record: [String: Any] }

func resolve(_ address: String) -> [String: Any] {
    var evidence: [[String: Any]] = []
    func run(_ args: [String]) throws -> String {
        let r = try ipsw(args)
        evidence.append(["command": r.cmd, "exit": Int(r.code), "stdout": r.out])
        if r.code != 0 { throw NSError(domain: "", code: 1, userInfo: [NSLocalizedDescriptionKey: "command failed with exit \(r.code)"]) }
        return r.out
    }
    var record: [String: Any] = ["stub": address, "evidence": evidence]
    do {
        let asm = try run(["disass", cache, "--vaddr", address, "--count", "4", "--quiet"])
        // Match only the observed four-instruction authenticated stub shape.
        guard let adrp = rx(asm, #"adrp\s+x17, (0x[0-9a-f]+)"#),
              let add = rx(asm, #"add\s+x17, x17, #(0x[0-9a-f]+)"#),
              rx(asm, #"ldr\s+x16, \[x17\]"#, 0) != nil,
              rx(asm, #"braa\s+x16, x17"#, 0) != nil,
              let a = hex(adrp), let b = hex(add) else {
            throw NSError(domain: "", code: 1, userInfo: [NSLocalizedDescriptionKey: "unsupported stub instruction shape; not guessed"])
        }
        let slot = a + b
        record["pointer_slot"] = String(format: "0x%x", slot)
        let pointer = try run(["dump", cache, String(format: "0x%x", slot), "--addr", "--count", "1"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard pointer.range(of: #"^0x[0-9a-fA-F]+$"#, options: .regularExpression) != nil else {
            throw NSError(domain: "", code: 1, userInfo: [NSLocalizedDescriptionKey: "unexpected decoded pointer output"])
        }
        record["destination"] = pointer
        let mapping = try run(["a2s", cache, pointer, "--mapping"])
        let symbol = rx(mapping, "^" + NSRegularExpression.escapedPattern(for: pointer) + #": (.+)$"#)
        guard let dylib = rx(mapping, #"dylib=(\S+) section=(\S+)"#, 1),
              let section = rx(mapping, #"dylib=(\S+) section=(\S+)"#, 2) else {
            throw NSError(domain: "", code: 1, userInfo: [NSLocalizedDescriptionKey: "no containing image/section reported"])
        }
        record["image"] = dylib; record["section"] = section
        record["symbol"] = symbol as Any; record["status"] = "resolved"
    } catch {
        record["status"] = "unresolved"; record["error"] = error.localizedDescription
    }
    record["evidence"] = evidence
    return record
}

guard let wdata = FileManager.default.contents(atPath: warningsPath),
      let wjson = try? JSONSerialization.jsonObject(with: wdata) as? [String: Any],
      let addresses = wjson["addresses"] as? [[String: Any]] else {
    FileHandle.standardError.write(Data("cannot read warnings \(warningsPath)\n".utf8)); exit(1)
}
var report: [String: Any] = ["scope": "static local-cache stub resolution; unsupported shapes remain unknown",
                             "cache": cache, "items": []]
var items: [[String: Any]] = []
for entry in addresses.prefix(limit) {
    var record = resolve(entry["address"] as? String ?? "")
    record["warning_count"] = entry["warnings"]
    items.append(record); report["items"] = items
    let out = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted])
    try? (String(data: out, encoding: .utf8)! + "\n").write(toFile: outputPath, atomically: true, encoding: .utf8)
    let compact: [String: Any] = ["stub": record["stub"] ?? NSNull(), "status": record["status"] ?? NSNull(),
                                  "symbol": record["symbol"] ?? NSNull(), "image": record["image"] ?? NSNull(),
                                  "error": record["error"] ?? NSNull()]
    if let cd = try? JSONSerialization.data(withJSONObject: compact), let s = String(data: cd, encoding: .utf8) { print(s) }
}
