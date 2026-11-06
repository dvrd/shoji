import AppKit
import Foundation

@_silgen_name("SLSMainConnectionID") func connectionID() -> Int32
@_silgen_name("SLSMoveWindow") func moveWindow(_ connection: Int32, _ window: UInt32, _ point: UnsafePointer<CGPoint>) -> Int32
@_silgen_name("SLSGetWindowBounds") func windowBounds(_ connection: Int32, _ window: UInt32, _ bounds: UnsafeMutablePointer<CGRect>) -> Int32

// Separate executable from the authorized capturer: fixture instrumentation
// can evolve without replacing the capturer's code identity/TCC permission.
final class PulseView: NSView {
    let color: NSColor
    var phase = false
    init(_ color: NSColor) { self.color = color; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill(); bounds.fill()
        (phase ? NSColor.white : NSColor.black).setFill()
        NSRect(x: 8, y: 8, width: 12, height: 12).fill()
    }
}

guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "fixture" else { exit(2) }
let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let cid = connectionID()
guard cid != 0 else { fatalError("missing GUI connection") }

func json(_ value: [String: Any]) -> Data {
    var data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); data.append(10); return data
}
func make(_ title: String, _ color: NSColor, marker: Bool = false) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: marker ? 20 : 160, height: marker ? 20 : 120), styleMask: .borderless, backing: .buffered, defer: false)
    window.title = title; window.isReleasedWhenClosed = false
    window.backgroundColor = color; window.isOpaque = true; window.hasShadow = false
    window.animationBehavior = .none; window.level = .floating
    if !marker { window.contentView = PulseView(color); window.orderFrontRegardless() }
    return window
}
let red = make("Shoji C1 red pulse", .red)
let green = make("Shoji C1 green pulse", .green)
let marker = make("Shoji C1 ordering marker", .blue, marker: true)
func move(_ window: NSWindow, x: CGFloat, y: CGFloat) {
    var point = CGPoint(x: x, y: y)
    guard moveWindow(cid, UInt32(window.windowNumber), &point) == 0 else { fatalError("owned move failed") }
}
FileManager.default.createFile(atPath: directory.appendingPathComponent("fixture-events.jsonl").path, contents: nil)
let eventFile = try FileHandle(forWritingTo: directory.appendingPathComponent("fixture-events.jsonl"))
var last = ""
let heartbeat = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
    for window in [red, green] {
        let view = window.contentView as! PulseView
        view.phase.toggle(); view.needsDisplay = true
    }
}
let requests = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in
    guard let raw = try? String(contentsOf: directory.appendingPathComponent("fixture-request"), encoding: .utf8), raw.hasSuffix("\n"), raw != last else { return }
    last = raw
    let fields = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard fields.count >= 2 else { return }
    let id = fields[0], verb = fields[1], started = mach_absolute_time()
    func reply() {
        var a = CGRect.zero, b = CGRect.zero
        let ca = windowBounds(cid, UInt32(red.windowNumber), &a), cb = windowBounds(cid, UInt32(green.windowNumber), &b)
        let value: [String: Any] = ["id": id, "verb": verb, "started": started, "ended": mach_absolute_time(), "red_status": ca, "green_status": cb, "red_x": a.origin.x, "red_y": a.origin.y, "green_x": b.origin.x, "green_y": b.origin.y]
        let data = json(value); eventFile.write(data)
        try! data.write(to: directory.appendingPathComponent("fixture-response.json"), options: .atomic)
    }
    if verb == "cascade", fields.count == 3, let y = Double(fields[2]) {
        move(red, x: 100, y: y)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { move(green, x: 400, y: y); reply() }
    } else if verb == "trigger" {
        marker.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { marker.orderOut(nil); reply() }
    } else if verb == "status" { reply() }
    else if verb == "shutdown" { reply(); NSApp.terminate(nil) }
}
_ = heartbeat; _ = requests
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    move(red, x: 100, y: 200); move(green, x: 400, y: 200)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        try! json(["pid": getpid(), "red": UInt32(red.windowNumber), "green": UInt32(green.windowNumber), "marker": UInt32(marker.windowNumber), "heartbeat_hz": 60]).write(to: directory.appendingPathComponent("fixture-ready.json"), options: .atomic)
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 90) { NSApp.terminate(nil) }
app.run()
