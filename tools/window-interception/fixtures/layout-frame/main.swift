import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import Foundation

@_silgen_name("SLSMainConnectionID") func connectionID() -> Int32
@_silgen_name("SLSMoveWindow") func moveWindow(_ connection: Int32, _ window: UInt32, _ point: UnsafePointer<CGPoint>) -> Int32
@_silgen_name("SLSGetWindowBounds") func windowBounds(_ connection: Int32, _ window: UInt32, _ bounds: UnsafeMutablePointer<CGRect>) -> Int32

let args = CommandLine.arguments
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func jsonLine(_ value: [String: Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)! + "\n"
}
func writeJSON(_ value: [String: Any], _ url: URL) throws {
    try Data(jsonLine(value).utf8).write(to: url, options: .atomic)
}

func makeWindow(_ title: String, _ color: NSColor, width: CGFloat = 160, height: CGFloat = 120) -> NSWindow {
    let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
    w.title = title; w.isReleasedWhenClosed = false
    w.backgroundColor = color; w.isOpaque = true; w.hasShadow = false
    w.animationBehavior = .none; w.level = .floating
    return w
}

if args.count == 3 && args[1] == "fixture" {
    let directory = URL(fileURLWithPath: args[2], isDirectory: true)
    let cid = connectionID()
    guard cid != 0 else { fatalError("no GUI connection") }
    let red = makeWindow("Shoji C1 red", .red)
    let green = makeWindow("Shoji C1 green", .green)
    let marker = makeWindow("Shoji C1 ordering marker", .blue, width: 20, height: 20)
    red.orderFrontRegardless(); green.orderFrontRegardless()
    func move(_ w: NSWindow, _ x: CGFloat, _ y: CGFloat) {
        var point = CGPoint(x: x, y: y)
        let code = moveWindow(cid, UInt32(w.windowNumber), &point)
        guard code == 0 else { fatalError("owned movement failed \(code)") }
    }
    move(red, 100, 200); move(green, 400, 200)
    let eventFile = directory.appendingPathComponent("fixture-events.jsonl")
    FileManager.default.createFile(atPath: eventFile.path, contents: nil)
    let events = try FileHandle(forWritingTo: eventFile)
    var last = ""
    let timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in
        let request = directory.appendingPathComponent("fixture-request")
        guard let raw = try? String(contentsOf: request, encoding: .utf8), raw.hasSuffix("\n"), raw != last else { return }
        last = raw
        let fields = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count >= 2 else { return }
        let id = fields[0], verb = fields[1]
        let started = mach_absolute_time()
        func reply() {
            var a = CGRect.zero, b = CGRect.zero
            let ca = windowBounds(cid, UInt32(red.windowNumber), &a)
            let cb = windowBounds(cid, UInt32(green.windowNumber), &b)
            let result: [String: Any] = ["id": id, "verb": verb, "started": started, "ended": mach_absolute_time(), "red_status": ca, "green_status": cb, "red_x": a.origin.x, "red_y": a.origin.y, "green_x": b.origin.x, "green_y": b.origin.y]
            events.write(Data(jsonLine(result).utf8))
            try! writeJSON(result, directory.appendingPathComponent("fixture-response.json"))
        }
        if verb == "cascade", fields.count == 3, let y = Double(fields[2]) {
            move(red, 100, y)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { move(green, 400, y); reply() }
        } else if verb == "trigger" {
            marker.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { marker.orderOut(nil); reply() }
        } else if verb == "status" { reply() }
        else if verb == "shutdown" { reply(); NSApp.terminate(nil) }
    }
    _ = timer
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        try! writeJSON(["pid": getpid(), "red": UInt32(red.windowNumber), "green": UInt32(green.windowNumber), "marker": UInt32(marker.windowNumber)], directory.appendingPathComponent("fixture-ready.json"))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 90) { NSApp.terminate(nil) }
    app.run()
    exit(0)
}

struct Frame: Codable {
    let sequence: Int
    let displayTicks: UInt64?
    let callbackTicks: UInt64
    let status: Int
    let redCount: Int
    let greenCount: Int
    let redY: Double?
    let greenY: Double?
    let state: String
}
struct Pixels { let bytes: Data; let width: Int; let height: Int; let stride: Int }
final class Capture: NSObject, SCStreamOutput {
    let lock = NSLock()
    var frames: [Frame] = []
    var snapshots: [String: Pixels] = [:]
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let callback = mach_absolute_time()
        let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
        let status = (info?[.status] as? NSNumber)?.intValue ?? -1
        let ticks = (info?[.displayTime] as? NSNumber)?.uint64Value
        guard status == 0 else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        var redCount = 0, greenCount = 0, redSum = 0, greenSum = 0
        for y in Swift.stride(from: 0, to: height, by: 2) {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in Swift.stride(from: 0, to: width, by: 2) {
                let p = x * 4, b = Int(row[p]), g = Int(row[p+1]), r = Int(row[p+2])
                if r > 180 && g < 70 && b < 70 { redCount += 1; redSum += y }
                if g > 180 && r < 70 && b < 70 { greenCount += 1; greenSum += y }
            }
        }
        let redY = redCount >= 100 ? Double(redSum) / Double(redCount) : nil
        let greenY = greenCount >= 100 ? Double(greenSum) / Double(greenCount) : nil
        func band(_ y: Double?) -> String {
            guard let y else { return "?" }
            if abs(y - 159) < 8 { return "A" }
            if abs(y - 409) < 8 { return "B" }
            return "?"
        }
        let state = band(redY) + band(greenY)
        lock.lock(); defer { lock.unlock() }
        if frames.count >= 5000 { return }
        frames.append(Frame(sequence: frames.count, displayTicks: ticks, callbackTicks: callback, status: status, redCount: redCount, greenCount: greenCount, redY: redY, greenY: greenY, state: state))
        if snapshots[state] == nil && snapshots.count < 6 {
            snapshots[state] = Pixels(bytes: Data(bytes: base, count: stride * height), width: width, height: height, stride: stride)
        }
    }
    func save(_ directory: URL) throws {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for frame in frames { data.append(try encoder.encode(frame)); data.append(10) }
        try data.write(to: directory.appendingPathComponent("frames.jsonl"), options: .atomic)
        for (name, pixels) in snapshots {
            let provider = CGDataProvider(data: pixels.bytes as CFData)!
            let bitmap = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
            let image = CGImage(width: pixels.width, height: pixels.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels.stride, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            try png.write(to: directory.appendingPathComponent("frame-\(name).png"))
        }
    }
}

guard args.count == 4, args[1] == "capture", let duration = UInt64(args[3]), duration <= 30000 else {
    fputs("usage: shoji-layout-frame fixture DIRECTORY | capture DIRECTORY MILLISECONDS\n", stderr); exit(2)
}
let directory = URL(fileURLWithPath: args[2], isDirectory: true)
let ready = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("fixture-ready.json"))) as! [String: NSNumber]
let ids = Set([ready["red"]!.uint32Value, ready["green"]!.uint32Value])
let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { fatalError("missing display") }
let windows = content.windows.filter { ids.contains($0.windowID) && $0.owningApplication?.processID == ready["pid"]!.int32Value }
guard windows.count == 2 else { fatalError("capture must match both fixture windows and owner pid") }
let filter = SCContentFilter(display: display, including: windows)
let config = SCStreamConfiguration()
config.sourceRect = CGRect(x: 0, y: 100, width: 800, height: 600)
config.width = 800; config.height = 600; config.pixelFormat = kCVPixelFormatType_32BGRA
config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
config.queueDepth = 8; config.showsCursor = false
let output = Capture()
let stream = SCStream(filter: filter, configuration: config, delegate: nil)
try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "shoji.c1.capture"))
try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
    stream.startCapture { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}
var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
try writeJSON(["started": mach_absolute_time(), "numer": timebase.numer, "denom": timebase.denom, "display_width": display.width, "display_height": display.height, "duration_ms": duration], directory.appendingPathComponent("capture-ready.json"))
try await Task.sleep(nanoseconds: duration * 1_000_000)
try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
    stream.stopCapture { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}
try output.save(directory)
try writeJSON(["finished": mach_absolute_time()], directory.appendingPathComponent("capture-done.json"))
print("PASS: captured complete-frame pixels and saved representative PNGs")
