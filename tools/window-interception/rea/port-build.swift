#!/usr/bin/env swift
// Per-build port pipeline (A3). Produces a compact model.json for one macOS
// build from its dyld shared cache, without Ghidra:
//   carve SkyLight -> UUID/hash -> hooked-function address + entry bytes ->
//   dispatch table base -> op map decode -> model.json
// Heavy analysis (Ghidra) stays on demand for when the diff shows changes.
// usage: port-build.swift BUILD_TAG DYLD_CACHE_PATH
import Foundation

let fm = FileManager.default
let argv = Array(CommandLine.arguments.dropFirst())
guard argv.count == 2 else { FileHandle.standardError.write(Data("usage: port-build.swift BUILD_TAG DYLD_CACHE_PATH\n".utf8)); exit(1) }
let tag = argv[0], cache = argv[1]

func die(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }
@discardableResult
func sh(_ launch: String, _ args: [String], capture: Bool = true) -> (code: Int32, out: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = [launch] + args
    var pipe: Pipe?
    if capture { pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe }
    do { try p.run() } catch { return (127, "\(error)") }
    var out = ""
    if let pipe = pipe { out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "" }
    p.waitUntilExit(); return (p.terminationStatus, out)
}
func rx(_ s: String, _ pat: String, _ group: Int = 1, options: NSRegularExpression.Options = [.anchorsMatchLines]) -> String? {
    guard let re = try? NSRegularExpression(pattern: pat, options: options),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
          let r = Range(m.range(at: group), in: s) else { return nil }
    return String(s[r])
}

let root = sh("git", ["rev-parse", "--show-toplevel"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
let out = "\(root)/artifacts/macos_versions/\(tag)"
let scriptDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
try? fm.createDirectory(atPath: out + "/extracted", withIntermediateDirectories: true)
try? fm.createDirectory(atPath: out + "/model", withIntermediateDirectories: true)

func writeModel(_ model: [String: Any], to file: String) {
    let d = try! JSONSerialization.data(withJSONObject: model, options: [.prettyPrinted, .sortedKeys])
    try? d.write(to: URL(fileURLWithPath: file))
}
func readModel(_ file: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file)))) as? [String: Any] ?? [:]
}

print("== [1/4] carve SkyLight")
let skyPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
if sh("ipsw", ["dyld", "extract", cache, skyPath, "--output", out + "/extracted"], capture: false).code != 0 {
    die("ipsw dyld extract failed")
}
let sumLine = sh("shasum", ["-a", "256", out + "/extracted/SkyLight"]).out
print(sumLine, terminator: "")
try? sumLine.write(toFile: out + "/model/skylight.sha256", atomically: true, encoding: .utf8)

print("== [2/4] identity + hooked function")
guard let d = fm.contents(atPath: out + "/extracted/SkyLight") else { die("no carved SkyLight") }
func load<T>(_ o: Int, _ t: T.Type) -> T { d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: t) } }
let ncmds = load(16, UInt32.self)
var off = 32
var uuid: String?
for _ in 0..<ncmds {
    let cmd = load(off, UInt32.self), cmdsize = load(off + 4, UInt32.self)
    if cmd == 0x1b {   // LC_UUID
        uuid = (0..<16).map { String(format: "%02x", d[off + 8 + $0]) }.joined()
        break
    }
    off += Int(cmdsize)
}
let nm = sh("nm", [out + "/extracted/SkyLight"]).out
func addrOf(_ pattern: String) -> String? {
    rx(nm, #"^([0-9a-f]+) [tT] "# + pattern + "$").map { "0x" + $0 }
}
var model: [String: Any] = [
    "uuid": uuid as Any,
    "hooked_function": ["name": "_CGXOrderWindowListSpaceSwitchOptions",
                        "address": addrOf(#"__ZL\d+CGXOrderWindowListSpaceSwitchOptions\w*"#) as Any],
    "commit_function": ["name": "PKGTransactionCommit",
                        "address": addrOf(#"__ZL\d+PKGTransactionCommit\w*"#) as Any],
]
writeModel(model, to: out + "/model/identity.json")
print(String(data: try! JSONSerialization.data(withJSONObject: model, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)

print("== [3/4] entry bytes + dispatch table")
model = readModel(out + "/model/identity.json")
var hooked = model["hooked_function"] as! [String: Any]
let hook = hooked["address"] as? String ?? ""
let entryAsm = sh("ipsw", ["dyld", "disass", cache, "--vaddr", hook, "--count", "4", "--quiet"]).out
var entry: [[String: String]] = []
for line in entryAsm.split(separator: "\n") {
    if let m = rx(String(line), #"(0x[0-9a-f]+):\s+((?:[0-9a-f]{2} )+)\s+(\S.*)"#, 2),
       let insn = rx(String(line), #"(0x[0-9a-f]+):\s+((?:[0-9a-f]{2} )+)\s+(\S.*)"#, 3) {
        entry.append(["bytes": m.trimmingCharacters(in: .whitespaces), "insn": insn])
    }
}
hooked["entry"] = entry
model["hooked_function"] = hooked
let commit = (model["commit_function"] as? [String: Any])?["address"] as? String ?? ""
let commitAsm = sh("ipsw", ["dyld", "disass", cache, "--vaddr", commit, "--count", "400", "--quiet"]).out
try? commitAsm.write(toFile: out + "/model/transaction-commit.asm", atomically: true, encoding: .utf8)
var table: String?
if let adrp = rx(commitAsm, #"adrp\s+x24, (0x[0-9a-f]+)\s*\n\s*(0x[0-9a-f]+):\s+[0-9a-f ]+\s+add\s+x24, x24, #(0x[0-9a-f]+)"#, 1, options: [.dotMatchesLineSeparators]),
   let addc = rx(commitAsm, #"adrp\s+x24, (0x[0-9a-f]+)\s*\n\s*(0x[0-9a-f]+):\s+[0-9a-f ]+\s+add\s+x24, x24, #(0x[0-9a-f]+)"#, 3, options: [.dotMatchesLineSeparators]),
   let a = Int(adrp.replacingOccurrences(of: "0x", with: ""), radix: 16),
   let b = Int(addc.replacingOccurrences(of: "0x", with: ""), radix: 16) {
    table = String(format: "0x%x", a + b)
}
model["dispatch_table"] = ["base": table as Any]
writeModel(model, to: out + "/model/identity.json")
print("table base: \(table ?? "nil")")

print("== [4/4] decode op map")
let tableVA = ((readModel(out + "/model/identity.json")["dispatch_table"] as? [String: Any])?["base"] as? String) ?? ""
let decoded = sh("swift", [scriptDir + "/ghidra/decode-transaction-table.swift", out + "/extracted/SkyLight", tableVA]).out
try? decoded.write(toFile: out + "/model/transaction-dispatch-table.txt", atomically: true, encoding: .utf8)
if let last = decoded.split(separator: "\n").last { print(last) }
var ops: [String: [String: String]] = [:]
for line in decoded.split(separator: "\n") {
    // op 0x01  signed=..  handler=0x..  meta=..  name
    if let op = rx(String(line), #"op (0x[0-9a-f]+)\s+signed=\S+\s+handler=(0x[0-9a-f]+)\s+meta=\S+\s*(.*)"#, 1),
       let handler = rx(String(line), #"op (0x[0-9a-f]+)\s+signed=\S+\s+handler=(0x[0-9a-f]+)\s+meta=\S+\s*(.*)"#, 2) {
        let name = rx(String(line), #"op (0x[0-9a-f]+)\s+signed=\S+\s+handler=(0x[0-9a-f]+)\s+meta=\S+\s*(.*)"#, 3) ?? ""
        ops[op] = ["handler": handler, "name": name]
    }
}
model = readModel(out + "/model/identity.json")
var dt = model["dispatch_table"] as! [String: Any]
dt["ops"] = ops
model["dispatch_table"] = dt
writeModel(model, to: out + "/model/model.json")
print("model.json: \(ops.count) ops")
print("model written to \(out)/model/model.json")
