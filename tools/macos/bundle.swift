#!/usr/bin/swift
// Package the existing signed runtime as a macOS background application.
// Run: tools/macos/bundle.swift   (task build:app)
import Foundation

let fm = FileManager.default
func fail(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }
func run(_ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    do { try p.run() } catch { fail("cannot run \(args[0]): \(error)") }
    p.waitUntilExit()
    if p.terminationStatus != 0 { fail("command failed (\(p.terminationStatus)): \(args.joined(separator: " "))") }
}

let identifier = "tech.shoji.window-manager"
let env = ProcessInfo.processInfo.environment

// Repo root = two directories above this script (tools/macos/bundle.swift).
let script = URL(fileURLWithPath: CommandLine.arguments[0],
                 relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath)).standardizedFileURL
let root = script.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

let binDir = root.appendingPathComponent("bin")
let binary = binDir.appendingPathComponent("shoji")
let icon = root.appendingPathComponent("assets/macos/Shoji.icns")
guard fm.fileExists(atPath: binary.path), fm.fileExists(atPath: icon.path) else {
    fail("Build bin/shoji and generate assets/macos/Shoji.icns first")
}

// Ad-hoc signing in CI; otherwise the persistent local identity from signing.json.
var signing = ["--sign", "-"]
if env["SHOJI_ADHOC_SIGNING"] != "1" {
    let configHome = env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
        ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".config")
    let cfgURL = configHome.appendingPathComponent("shoji/signing.json")
    guard let data = try? Data(contentsOf: cfgURL),
          let cfg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let identity = cfg["identity"] as? String,
          let keychain = cfg["keychain"] as? String
    else { fail("cannot read signing identity at \(cfgURL.path)") }
    signing = ["--sign", identity, "--keychain", keychain,
               "--requirements",
               "=designated => identifier \"\(identifier)\" and certificate leaf = H\"\(identity)\""]
}

let destination = binDir.appendingPathComponent("Shoji.app")
if let attrs = try? fm.attributesOfItem(atPath: destination.path),
   (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
    fail("Refusing to replace a symlinked app bundle")
}

// Stage the candidate, verify it, then atomically replace the previous bundle.
let stage = binDir.appendingPathComponent("shoji-app-\(ProcessInfo.processInfo.processIdentifier)")
try? fm.removeItem(at: stage)
let app = stage.appendingPathComponent("Shoji.app")
let contents = app.appendingPathComponent("Contents")
let macosDir = contents.appendingPathComponent("MacOS")
let resources = contents.appendingPathComponent("Resources")
do {
    try fm.createDirectory(at: macosDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: resources, withIntermediateDirectories: true)
} catch { fail("cannot stage bundle: \(error)") }

for name in ["shoji", "shoji-loader"] {
    let src = binDir.appendingPathComponent(name)
    if fm.fileExists(atPath: src.path) {
        do { try fm.copyItem(at: src, to: macosDir.appendingPathComponent(name)) }
        catch { fail("cannot copy \(name): \(error)") }
    }
}
// `shoji --load-sa` loads the Dock payload from Resources; the sudoers rule
// pins only the executable, so the payload must travel inside the bundle.
let payload = binDir.appendingPathComponent("shoji-sa.dylib")
guard fm.fileExists(atPath: payload.path) else { fail("missing \(payload.path); run task addition") }
do { try fm.copyItem(at: payload, to: resources.appendingPathComponent("shoji-sa.dylib")) }
catch { fail("cannot copy Dock payload: \(error)") }
do { try fm.copyItem(at: icon, to: resources.appendingPathComponent("Shoji.icns")) }
catch { fail("cannot copy icon: \(error)") }

let info: [String: Any] = [
    "CFBundleIdentifier": identifier, "CFBundleName": "Shoji",
    "CFBundleDisplayName": "Shoji", "CFBundleExecutable": "shoji",
    "CFBundlePackageType": "APPL", "CFBundleIconFile": "Shoji.icns",
    "CFBundleVersion": "1", "CFBundleShortVersionString": "0.1.0",
    "LSMinimumSystemVersion": "15.0", "LSUIElement": true,
    "NSHighResolutionCapable": true,
]
do {
    let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try plist.write(to: contents.appendingPathComponent("Info.plist"))
} catch { fail("cannot write Info.plist: \(error)") }

run(["/usr/bin/codesign", "--force"] + signing + ["--identifier", identifier, "--timestamp=none", app.path])
run(["/usr/bin/codesign", "--verify", "--strict", "--deep", app.path])

if fm.fileExists(atPath: destination.path) {
    do { try fm.removeItem(at: destination) } catch { fail("cannot remove old bundle: \(error)") }
}
do { try fm.moveItem(at: app, to: destination) } catch { fail("cannot install bundle: \(error)") }
try? fm.removeItem(at: stage)

run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
     "-f", destination.path])
print(destination.path)
