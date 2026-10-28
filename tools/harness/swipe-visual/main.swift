import AppKit
import ApplicationServices
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import Foundation

@_silgen_name("SLSMainConnectionID") func slsConnection() -> Int32
@_silgen_name("SLSDisableUpdate") func slsDisable(_ cid: Int32) -> Int32
@_silgen_name("SLSReenableUpdate") func slsEnable(_ cid: Int32) -> Int32
@_silgen_name("_AXUIElementGetWindow") func axWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<UInt32>) -> AXError
@_silgen_name("proc_pidpath") func procPIDPath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32
@_silgen_name("shoji_test_transform") func testTransform(_ cid: Int32, _ owned: UInt32, _ fixture: UInt32, _ tx: Double) -> Int32
@_silgen_name("shoji_test_get_transform") func testGetTransform(_ cid: Int32, _ id: UInt32, _ tx: UnsafeMutablePointer<Double>) -> Int32
@_silgen_name("shoji_test_window_x") func testWindowX(_ cid: Int32, _ id: UInt32, _ x: UnsafeMutablePointer<Double>) -> Int32

let fixturePrefix = "Shoji swipe visual fixture "
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func makeWindow(_ title: String, _ rect: NSRect, _ color: NSColor, marker: Bool = false) -> NSWindow {
    let window = NSWindow(contentRect: rect, styleMask: marker ? [.borderless] : [.titled, .resizable, .closable], backing: .buffered, defer: false)
    window.title = title
    window.isReleasedWhenClosed = false
    window.backgroundColor = color
    window.isOpaque = true
    window.hasShadow = false
    window.level = .floating
    window.ignoresMouseEvents = marker
    window.orderFrontRegardless()
    return window
}

if CommandLine.arguments.dropFirst().first == "fixture" {
    let a = makeWindow(fixturePrefix + "A", NSRect(x: 250, y: 300, width: 280, height: 220), .red)
    let b = makeWindow(fixturePrefix + "B", NSRect(x: 550, y: 300, width: 280, height: 220), .green)
    print("\(getpid()) \(a.windowNumber) \(b.windowNumber)")
    fflush(stdout)
    let fixtureMode = CommandLine.arguments.dropFirst(2).first
    if fixtureMode == "slow" || fixtureMode == "slow-exit" {
        _ = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in Thread.sleep(forTimeInterval: 0.08) }
    }
    if fixtureMode == "slow-exit" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) } }
    DispatchQueue.main.asyncAfter(deadline: .now() + 45) { NSApp.terminate(nil) }
    app.run()
    exit(0)
}

struct Measurement: Codable {
    let mode: String
    let time: Double
    let redLeft: Int?
    let redRight: Int?
    let greenLeft: Int?
    let blueLeft: Int?
    let probe: String
    let displayTime: Double?
    let displayTicks: UInt64?
    let machNow: Double
    let timebaseNumer: UInt32
    let timebaseDenom: UInt32
    let frameStatus: Int?
    let status: String
}
struct Timing: Codable {
    let mode: String
    let step: Int
    let offset: Double
    let started: Double
    let firstEnd: Double
    let secondEnd: Double
    let indicatorEnd: Double
    let committed: Double
}
struct WorkerEvent: Codable {
    let requested: Double
    let offset: Double
    let started: Double
    let completed: Double
    let firstStatus: Int32
    let secondStatus: Int32
}
final class CoalescedWorker: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "tech.shoji.swipe-visual.ax-worker")
    private let a: AXUIElement
    private let b: AXUIElement
    private let y: CGFloat
    private var pending: (Double, CGFloat)?
    private var running = false
    private var failed = false
    private var finished: [WorkerEvent] = []
    init(_ a: AXUIElement, _ b: AXUIElement, y: CGFloat) { self.a = a; self.b = b; self.y = y }
    func submit(_ offset: CGFloat) {
        lock.lock()
        if failed { lock.unlock(); return }
        pending = (ProcessInfo.processInfo.systemUptime, offset)
        if running { lock.unlock(); return }
        running = true; lock.unlock()
        queue.async { self.drain() }
    }
    private func write(_ element: AXUIElement, x: CGFloat) -> Int32 {
        var point = CGPoint(x: x, y: y)
        guard let value = AXValueCreate(.cgPoint, &point) else { return -1 }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value).rawValue
    }
    private func drain() {
        while true {
            lock.lock()
            guard let (requested, offset) = pending else { running = false; lock.unlock(); return }
            pending = nil; lock.unlock()
            let start = ProcessInfo.processInfo.systemUptime
            let first = write(a, x: 250 + offset)
            let second = first == 0 ? write(b, x: 550 + offset) : -99999
            let end = ProcessInfo.processInfo.systemUptime
            lock.lock(); finished.append(WorkerEvent(requested: requested, offset: Double(offset), started: start, completed: end, firstStatus: first, secondStatus: second))
            if first != 0 || second != 0 {
                failed = true; pending = nil; running = false; lock.unlock(); return
            }
            lock.unlock()
        }
    }
    func snapshot() -> ([WorkerEvent], Bool) { lock.lock(); defer { lock.unlock() }; return (finished, running) }
}
final class Capture: NSObject, SCStreamOutput {
    let lock = NSLock()
    var mode = "setup"
    var samples: [Measurement] = []
    let row: Int
    init(row: Int) { self.row = row }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixel = sample.imageBuffer else { return }
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
        guard row >= 0 && row < height, let base = CVPixelBufferGetBaseAddress(pixel) else { return }
        let ptr = base.assumingMemoryBound(to: UInt8.self).advanced(by: row * CVPixelBufferGetBytesPerRow(pixel))
        var red: [Int] = [], green: [Int] = [], blue: [Int] = []
        for x in 0..<width {
            let p = ptr.advanced(by: x * 4)
            let b = Int(p[0]), g = Int(p[1]), r = Int(p[2])
            if r > 180 && g < 70 && b < 70 { red.append(x) }
            if g > 180 && r < 145 && b < 125 { green.append(x) }
            if b > 180 && r < 70 && g < 70 { blue.append(x) }
        }
        let probe = ptr.advanced(by: min(700, width - 1) * 4)
        let probeValue = "\(probe[2]),\(probe[1]),\(probe[0]),\(probe[3])"
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let metadata = attachments?.first
        let ticks = (metadata?[.displayTime] as? NSNumber)?.uint64Value
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let displayTime = ticks.map { Double($0) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000 }
        let machNow = Double(mach_absolute_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        let frameStatus = (metadata?[.status] as? NSNumber)?.intValue
        lock.lock(); defer { lock.unlock() }
        if samples.count < 3000 {
            samples.append(Measurement(mode: mode, time: ProcessInfo.processInfo.systemUptime,
                redLeft: red.first, redRight: red.last, greenLeft: green.first, blueLeft: blue.first, probe: probeValue,
                displayTime: displayTime, displayTicks: ticks, machNow: machNow,
                timebaseNumer: timebase.numer, timebaseDenom: timebase.denom, frameStatus: frameStatus,
                status: red.isEmpty || green.isEmpty || blue.isEmpty ? "missing-color" : "complete"))
        }
    }
    func setMode(_ value: String) { lock.lock(); mode = value; lock.unlock() }
    func snapshot() -> [Measurement] { lock.lock(); defer { lock.unlock() }; return samples }
}

func setPosition(_ element: AXUIElement, _ x: CGFloat, _ y: CGFloat) throws {
    var p = CGPoint(x: x, y: y)
    guard let v = AXValueCreate(.cgPoint, &p) else { throw NSError(domain: "AXValue", code: 1) }
    let result = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, v)
    guard result == .success else { throw NSError(domain: "AXPosition", code: Int(result.rawValue)) }
}

struct ProductionReady: Decodable {
    let pid: Int32
    let a: UInt32
    let b: UInt32
    let rings: [UInt32]
}
@MainActor func observeProduction() async throws {
    guard CommandLine.arguments.count == 5 else { throw NSError(domain: "observe arguments", code: 1) }
    guard CGPreflightScreenCaptureAccess(), let screen = NSScreen.main else { throw NSError(domain: "screen permission or screen unavailable", code: 1) }
    let ready = try JSONDecoder().decode(ProductionReady.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { throw NSError(domain: "display", code: 2) }
    let ids = Set([ready.a, ready.b] + ready.rings)
    let selected = content.windows.filter { ids.contains($0.windowID) }
    let selectedIDs = Set(selected.map { $0.windowID })
    guard selectedIDs.contains(ready.a), selectedIDs.contains(ready.b), !selectedIDs.isDisjoint(with: Set(ready.rings)) else {
        throw NSError(domain: "capture missing fixture or production ring surfaces", code: selected.count)
    }
    let scale = CGFloat(display.width) / screen.frame.width
    let config = SCStreamConfiguration()
    config.width = display.width; config.height = display.height
    config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    config.pixelFormat = kCVPixelFormatType_32BGRA; config.showsCursor = false
    let filter = SCContentFilter(display: display, including: selected)
    let output = Capture(row: Int(480 * scale)); output.setMode("production")
    let stream = SCStream(filter: filter, configuration: config, delegate: nil)
    try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "tech.shoji.swipe-visual.production"))
    try await stream.startCapture()
    try await Task.sleep(nanoseconds: 300_000_000)
    try Data("start".utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic)
    try await Task.sleep(nanoseconds: 4_500_000_000)
    try await stream.stopCapture()
    try JSONEncoder().encode(output.snapshot()).write(to: URL(fileURLWithPath: CommandLine.arguments[4]), options: .atomic)
    print("Captured \(output.snapshot().count) frames; selected \(selectedIDs.count)/\(ids.count) fixture and ring surfaces; scale \(scale)")
}
@MainActor func transactionProbe() async throws {
    guard CommandLine.arguments.count == 6,
          let pid = Int32(CommandLine.arguments[2]), let aID = UInt32(CommandLine.arguments[3]),
          let bID = UInt32(CommandLine.arguments[4]), aID != bID else { throw NSError(domain: "transaction arguments", code: 1) }
    var path = [CChar](repeating: 0, count: 4096)
    guard procPIDPath(pid, &path, UInt32(path.count)) > 0,
          URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path == URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path else {
        throw NSError(domain: "fixture executable identity", code: 1)
    }
    guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess(), let screen = NSScreen.main else { throw NSError(domain: "permission or screen unavailable", code: 1) }
    _ = try readWindows(pid, ids: [aID, bID])
    let owned = makeWindow(fixturePrefix + "indicator", NSRect(x: 90, y: 300, width: 80, height: 220), .blue, marker: true)
    defer { owned.close() }
    let ownedID = UInt32(owned.windowNumber)
    let cid = slsConnection()
    guard cid != 0 else { throw NSError(domain: "SkyLight connection", code: 1) }
    try await Task.sleep(nanoseconds: 400_000_000)
    var ownBefore = 0.0, foreignBefore = 0.0
    let ownBeforeStatus = testGetTransform(cid, ownedID, &ownBefore)
    let foreignBeforeStatus = testGetTransform(cid, aID, &foreignBefore)
    guard ownBeforeStatus == 0, foreignBeforeStatus == 0 else { throw NSError(domain: "baseline transform readback", code: 1) }
    defer { _ = testTransform(cid, ownedID, aID, 0) }
    print("Baseline transform: owned=\(ownBefore); foreign=\(foreignBefore)")
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { throw NSError(domain: "display", code: 1) }
    let ids = Set([aID, ownedID])
    let selected = content.windows.filter { ids.contains($0.windowID) }
    guard selected.count == 2 else { throw NSError(domain: "transaction capture selection", code: selected.count) }
    let config = SCStreamConfiguration()
    config.width = display.width; config.height = display.height
    config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    config.pixelFormat = kCVPixelFormatType_32BGRA; config.showsCursor = false
    let scale = CGFloat(display.width) / screen.frame.width
    let output = Capture(row: Int((screen.frame.height - 300 - 110) * scale))
    let stream = SCStream(filter: SCContentFilter(display: display, including: selected), configuration: config, delegate: nil)
    try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "tech.shoji.swipe-visual.transaction"))
    try await stream.startCapture()
    output.setMode("baseline"); try await Task.sleep(nanoseconds: 600_000_000)
    guard testTransform(cid, ownedID, aID, 40) == 0 else { throw NSError(domain: "transaction allocation", code: 1) }
    output.setMode("transformed")
    try await Task.sleep(nanoseconds: 600_000_000)
    var ownTX = 0.0, foreignTX = 0.0
    let ownStatus = testGetTransform(cid, ownedID, &ownTX), foreignStatus = testGetTransform(cid, aID, &foreignTX)
    print("Transform readback: owned status=\(ownStatus) tx=\(ownTX); foreign status=\(foreignStatus) tx=\(foreignTX)")
    guard testTransform(cid, ownedID, aID, 0) == 0 else { throw NSError(domain: "transaction restore allocation", code: 1) }
    output.setMode("restored"); try await Task.sleep(nanoseconds: 600_000_000)
    var ownAfter = 0.0, foreignAfter = 0.0
    let ownAfterStatus = testGetTransform(cid, ownedID, &ownAfter)
    let foreignAfterStatus = testGetTransform(cid, aID, &foreignAfter)
    print("Restored transform: owned status=\(ownAfterStatus) tx=\(ownAfter); foreign status=\(foreignAfterStatus) tx=\(foreignAfter)")
    guard ownAfterStatus == 0, foreignAfterStatus == 0,
          abs(ownAfter - ownBefore) < 0.01, abs(foreignAfter - foreignBefore) < 0.01 else {
        throw NSError(domain: "transaction restore readback mismatch", code: 1)
    }
    try await stream.stopCapture()
    try JSONEncoder().encode(output.snapshot()).write(to: URL(fileURLWithPath: CommandLine.arguments[5]), options: .atomic)
    print("Captured \(output.snapshot().count) transaction probe frames")
}
@MainActor func asynchronousProbe() async throws {
    guard CommandLine.arguments.count == 6,
          let pid = Int32(CommandLine.arguments[2]), let aID = UInt32(CommandLine.arguments[3]),
          let bID = UInt32(CommandLine.arguments[4]), aID != bID else { throw NSError(domain: "async arguments", code: 1) }
    var path = [CChar](repeating: 0, count: 4096)
    guard procPIDPath(pid, &path, UInt32(path.count)) > 0,
          URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path == URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path else { throw NSError(domain: "fixture identity", code: 1) }
    guard AXIsProcessTrusted(), let screen = NSScreen.main else { throw NSError(domain: "permission or screen unavailable", code: 1) }
    let windows = try readWindows(pid, ids: [aID, bID])
    let worker = CoalescedWorker(windows[aID]!, windows[bID]!, y: screen.frame.height - 300 - 220)
    var ticks: [Double] = []
    for step in 0..<80 {
        ticks.append(ProcessInfo.processInfo.systemUptime)
        let offset = CGFloat(step < 25 ? step : step < 50 ? 50-step : 0) * 4
        worker.submit(offset)
        try await Task.sleep(nanoseconds: 16_666_667)
    }
    for _ in 0..<60 {
        if !worker.snapshot().1 { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    let (events, active) = worker.snapshot()
    try await Task.sleep(nanoseconds: 200_000_000)
    var finalA = 0.0, finalB = 0.0
    let cid = slsConnection()
    let codeA = testWindowX(cid, aID, &finalA), codeB = testWindowX(cid, bID, &finalB)
    let result = AsyncResult(ticks: ticks, events: events, workerStillActive: active,
        finalA: codeA == 0 && finalA.isFinite ? finalA : nil,
        finalB: codeB == 0 && finalB.isFinite ? finalB : nil,
        readbackA: codeA, readbackB: codeB)
    try JSONEncoder().encode(result).write(to: URL(fileURLWithPath: CommandLine.arguments[5]), options: .atomic)
    guard !active, events.last?.offset == 0, codeA == 0, codeB == 0,
          abs(finalA-250) <= 2, abs(finalB-550) <= 2,
          events.allSatisfy({ $0.firstStatus == 0 && $0.secondStatus == 0 }) else { throw NSError(domain: "async worker did not settle or AX failed", code: 1) }
    print("Submitted \(ticks.count) samples; applied \(events.count) coalesced frames")
}
struct AsyncResult: Codable { let ticks: [Double]; let events: [WorkerEvent]; let workerStillActive: Bool; let finalA: Double?; let finalB: Double?; let readbackA: Int32; let readbackB: Int32 }
func readWindows(_ pid: pid_t, ids: Set<UInt32>) throws -> [UInt32: AXUIElement] {
    let application = AXUIElementCreateApplication(pid)
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &result) == .success,
          let windows = result as? [AXUIElement], windows.count == 2 else { throw NSError(domain: "fixture windows", code: 1) }
    var found: [UInt32: AXUIElement] = [:]
    for window in windows {
        var id: UInt32 = 0
        guard axWindowID(window, &id) == .success, ids.contains(id) else { throw NSError(domain: "fixture ownership", code: 2) }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
              let text = title as? String,
              text == fixturePrefix + "A" || text == fixturePrefix + "B" else { throw NSError(domain: "fixture title", code: 4) }
        found[id] = window
    }
    guard Set(found.keys) == ids else { throw NSError(domain: "fixture identity", code: 3) }
    return found
}

@MainActor func run() async throws {
    guard CommandLine.arguments.count == 5,
          let pid = Int32(CommandLine.arguments[1]), let aID = UInt32(CommandLine.arguments[2]),
          let bID = UInt32(CommandLine.arguments[3]), aID != bID else { throw NSError(domain: "arguments", code: 1) }
    var path = [CChar](repeating: 0, count: 4096)
    guard procPIDPath(pid, &path, UInt32(path.count)) > 0,
          URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path == URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path else {
        throw NSError(domain: "fixture executable identity", code: 1)
    }
    guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else { throw NSError(domain: "Accessibility or Screen Recording permission unavailable", code: 1) }
    let windows = try readWindows(pid, ids: [aID,bID])
    guard let screen = NSScreen.main else { throw NSError(domain: "screen", code: 1) }
    let indicator = makeWindow(fixturePrefix + "indicator", NSRect(x: 238, y: 300, width: 8, height: 220), .blue, marker: true)
    defer { indicator.close() }
    try await Task.sleep(nanoseconds: 500_000_000)
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { throw NSError(domain: "display", code: 2) }
    let ids = Set([aID,bID,UInt32(indicator.windowNumber)])
    let selected = content.windows.filter { ids.contains($0.windowID) }
    guard selected.count == 3 else { throw NSError(domain: "capture fixture selection", code: selected.count) }
    let scale = CGFloat(display.width) / screen.frame.width
    let config = SCStreamConfiguration()
    config.width = display.width; config.height = display.height
    config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.showsCursor = false
    let filter = SCContentFilter(display: display, including: selected)
    let row = Int((screen.frame.height - 300 - 110) * scale)
    let output = Capture(row: row)
    let stream = SCStream(filter: filter, configuration: config, delegate: nil)
    try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "tech.shoji.swipe-visual.capture"))
    try await stream.startCapture()
    let cid = slsConnection()
    guard cid != 0 else { throw NSError(domain: "SkyLight connection", code: 1) }
    let axY = screen.frame.height - 300 - 220
    var timings: [Timing] = []
    for (trial, batched) in [true, false, false, true].enumerated() {
        output.setMode("reset")
        try setPosition(windows[aID]!, 250, axY); try setPosition(windows[bID]!, 550, axY)
        indicator.setFrameOrigin(NSPoint(x: 238, y: 300))
        try await Task.sleep(nanoseconds: 400_000_000)
        output.setMode("\(batched ? "batch" : "unbatched")-\(trial)")
        for step in 0..<50 {
            let offset = CGFloat(step <= 25 ? step : 50-step) * 4
            let started = ProcessInfo.processInfo.systemUptime
            if batched && slsDisable(cid) != 0 { throw NSError(domain: "disable update", code: 1) }
            var firstEnd = started, secondEnd = started, indicatorEnd = started
            do {
                try setPosition(windows[aID]!, 250 + offset, axY)
                firstEnd = ProcessInfo.processInfo.systemUptime
                try setPosition(windows[bID]!, 550 + offset, axY)
                secondEnd = ProcessInfo.processInfo.systemUptime
                indicator.setFrameOrigin(NSPoint(x: 238 + offset, y: 300))
                indicatorEnd = ProcessInfo.processInfo.systemUptime
            } catch {
                if batched { _ = slsEnable(cid) }
                throw error
            }
            if batched && slsEnable(cid) != 0 { throw NSError(domain: "enable update", code: 1) }
            timings.append(Timing(mode: "\(batched ? "batch" : "unbatched")-\(trial)", step: step,
                offset: Double(offset), started: started, firstEnd: firstEnd, secondEnd: secondEnd,
                indicatorEnd: indicatorEnd, committed: ProcessInfo.processInfo.systemUptime))
            try await Task.sleep(nanoseconds: 16_666_667)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
    }
    output.setMode("done")
    try await stream.stopCapture()
    let data = try JSONEncoder().encode(output.snapshot())
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[4]), options: .atomic)
    try JSONEncoder().encode(timings).write(to: URL(fileURLWithPath: CommandLine.arguments[4] + ".timings"), options: .atomic)
    print("Captured \(output.snapshot().count) fixture-only frames at nominal 60 Hz; scale \(scale)")
}
Task { @MainActor in
    do {
        if CommandLine.arguments.dropFirst().first == "observe" { try await observeProduction() }
        else if CommandLine.arguments.dropFirst().first == "transaction" { try await transactionProbe() }
        else if CommandLine.arguments.dropFirst().first == "async" { try await asynchronousProbe() }
        else { try await run() }
        NSApp.terminate(nil)
    }
    catch { fputs("swipe visual: \(error)\n", stderr); exit(1) }
}
app.run()
