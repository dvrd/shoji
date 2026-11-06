import AppKit
import CoreGraphics
import Foundation

struct PSN { var high: UInt32 = 0; var low: UInt32 = 0 }
@_silgen_name("SLSMainConnectionID") func connectionID() -> Int32
@_silgen_name("SLSGetWindowOwner") func windowOwner(_ cid: Int32, _ wid: UInt32, _ owner: UnsafeMutablePointer<Int32>) -> Int32
@_silgen_name("SLSGetConnectionPSN") func connectionPSN(_ cid: Int32, _ psn: UnsafeMutablePointer<PSN>) -> Int32
@_silgen_name("SLPSSetFrontProcessWithOptions") func setFront(_ psn: UnsafePointer<PSN>, _ wid: UInt32, _ options: UInt64) -> Int32
@_silgen_name("proc_pidpath") func pidPath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32

func json(_ value: [String: Any]) -> Data {
    var data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); data.append(10); return data
}
func sessionState() -> [String: Any] {
    let state = (CGSessionCopyCurrentDictionary() as? [String: Any]) ?? [:]
    return ["locked": state["CGSSessionScreenIsLocked"] as? Bool ?? state.isEmpty,
            "on_console": state["kCGSSessionOnConsoleKey"] as? Bool ?? false,
            "login_done": state["kCGSessionLoginDoneKey"] as? Bool ?? false]
}
func sessionReady() -> Bool {
    let state = sessionState()
    return state["locked"] as? Bool == false && state["on_console"] as? Bool == true && state["login_done"] as? Bool == true
}
if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "session" {
    FileHandle.standardOutput.write(json(sessionState())); exit(sessionReady() ? 0 : 3)
}
let app = NSApplication.shared
let arguments = CommandLine.arguments
let executable = URL(fileURLWithPath: arguments[0]).standardized.resolvingSymlinksInPath().path

if arguments.count == 4 && arguments[1] == "activate", let pid = Int32(arguments[2]), let wid = UInt32(arguments[3]) {
    guard sessionReady() else { FileHandle.standardOutput.write(json(["refused": "session_not_ready", "session": sessionState()])); exit(3) }
    app.setActivationPolicy(.accessory)
    var path = [UInt8](repeating: 0, count: 4096)
    guard pidPath(pid, &path, UInt32(path.count)) > 0, String(cString: path) == executable,
          let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
          list.contains(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == wid && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid })
    else { fputs("refused: target must belong to this fixture executable\n", stderr); exit(1) }
    let cid = connectionID()
    var owner: Int32 = 0, psn = PSN()
    let a = windowOwner(cid, wid, &owner)
    let b = a == 0 ? connectionPSN(owner, &psn) : -1
    let c = b == 0 ? setFront(&psn, wid, 0x200) : -1
    FileHandle.standardOutput.write(json(["pid": pid, "target": wid, "owner_status": a, "psn_status": b, "activation_status": c, "tick": mach_absolute_time()]))
    exit(a == 0 && b == 0 && c == 0 ? 0 : 1)
}

guard arguments.count == 3 && arguments[1] == "fixture" else {
    fputs("usage: shoji-focus-fixture fixture DIRECTORY | activate PID WID | session\n", stderr); exit(2)
}
let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
app.setActivationPolicy(.regular)
app.finishLaunching()
let eventURL = directory.appendingPathComponent("events.jsonl")
FileManager.default.createFile(atPath: eventURL.path, contents: nil)
let events = try FileHandle(forWritingTo: eventURL)
func log(_ value: [String: Any]) { events.write(json(value)) }

final class TestWindow: NSWindow {
    var tag = ""
    override var canBecomeKey: Bool { tag != "marker" }
    override var canBecomeMain: Bool { tag != "marker" }
    override func keyDown(with event: NSEvent) {
        log(["event": "key", "tag": tag, "characters": event.characters ?? "", "keycode": event.keyCode,
             "tick": mach_absolute_time(), "pid": getpid(), "is_key": isKeyWindow,
             "active": NSApp.isActive, "front_pid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1])
    }
}
func make(_ tag: String, _ color: NSColor) -> TestWindow {
    let marker = tag == "marker"
    let window = TestWindow(contentRect: NSRect(x: marker ? 1400 : 300, y: marker ? 800 : 500, width: marker ? 20 : 240, height: marker ? 20 : 180), styleMask: .borderless, backing: .buffered, defer: false)
    window.tag = tag; window.title = "Shoji C2 " + tag
    window.backgroundColor = color; window.isOpaque = true; window.hasShadow = false
    window.isReleasedWhenClosed = false; window.animationBehavior = .none
    if !marker { window.orderFrontRegardless() }
    return window
}
let red = make("red", .red), green = make("green", .green), marker = make("marker", .blue)
let ids = [UInt32(red.windowNumber), UInt32(green.windowNumber)]
@MainActor func snapshot(_ id: String, verb: String) {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    let order = list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }.filter { ids.contains($0) }
    let value: [String: Any] = ["id": id, "verb": verb, "tick": mach_absolute_time(), "pid": getpid(),
        "key": app.keyWindow?.windowNumber ?? -1, "main": app.mainWindow?.windowNumber ?? -1,
        "front_pid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
        "active": app.isActive, "red": ids[0], "green": ids[1], "order": order, "session": sessionState()]
    log(value)
    try! json(value).write(to: directory.appendingPathComponent("response.json"), options: .atomic)
}
for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
    NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
        guard let w = note.object as? TestWindow else { return }
        log(["event": name.rawValue, "tag": w.tag, "tick": mach_absolute_time()])
    }
}
var last = ""
let timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in
    MainActor.assumeIsolated {
    guard let raw = try? String(contentsOf: directory.appendingPathComponent("request"), encoding: .utf8), raw.hasSuffix("\n"), raw != last else { return }
    last = raw
    let fields = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard fields.count >= 2 else { return }
    let id = fields[0], verb = fields[1]
    if verb == "trigger" {
        marker.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { marker.orderOut(nil); snapshot(id, verb: verb) }
    } else if verb == "focus", fields.count == 3 {
        guard ["red", "green"].contains(fields[2]), sessionReady() else { snapshot(id, verb: "refused"); return }
        let target = fields[2] == "red" ? red : green
        app.activate(ignoringOtherApps: true); target.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { snapshot(id, verb: verb) }
    } else if verb == "raise", fields.count == 3 {
        guard ["red", "green"].contains(fields[2]), sessionReady() else { snapshot(id, verb: "refused"); return }
        (fields[2] == "red" ? red : green).orderFrontRegardless()
        snapshot(id, verb: verb)
    } else if verb == "snapshot" { snapshot(id, verb: verb) }
    else if verb == "shutdown" { snapshot(id, verb: verb); NSApp.terminate(nil) }
    }
}
_ = timer
DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
    try! json(["pid": getpid(), "red": ids[0], "green": ids[1], "marker": UInt32(marker.windowNumber)]).write(to: directory.appendingPathComponent("ready.json"), options: .atomic)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 180) { NSApp.terminate(nil) }
app.run()
