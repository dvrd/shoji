import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

// Disposable guest capture probe. Captures one window (or the main display
// when WINDOW_ID is 0) through ScreenCaptureKit and logs every frame's raw
// SCStreamFrameInfo display time, status and callback Mach tick, so gated
// hold/release runs can be checked for early displayed frames.
//
// usage: shoji-capture-probe WINDOW_ID DURATION_MS

final class Output: NSObject, SCStreamOutput {
    var sequence = 0
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let callback = mach_absolute_time()
        var displayTime: Int64 = -1
        var status = -1
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let info = attachments.first {
            if let value = info[.displayTime] as? Int64 { displayTime = value }
            if let value = info[.status] as? Int { status = value }
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        print("\(sequence),\(displayTime),\(status),\(callback),\(pts.seconds)")
        sequence += 1
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 3,
      let windowID = UInt32(arguments[1]),
      let durationMS = UInt32(arguments[2])
else {
    FileHandle.standardError.write(Data("usage: shoji-capture-probe WINDOW_ID DURATION_MS\n".utf8))
    exit(2)
}

var timebase = mach_timebase_info_data_t()
mach_absolute_time()
mach_timebase_info(&timebase)

// Establish the CoreGraphics application connection before any ScreenCaptureKit
// call; otherwise scripted runs abort with CGS_REQUIRE_INIT.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let content: SCShareableContent
do {
    content = try await SCShareableContent.current
} catch {
    FileHandle.standardError.write(Data("FAIL: shareable content: \(error.localizedDescription)\n".utf8))
    exit(1)
}

var filter: SCContentFilter?
if windowID == 0 {
    if let display = content.displays.first {
        filter = SCContentFilter(display: display, excludingWindows: [])
    }
} else if let window = content.windows.first(where: { $0.windowID == windowID }) {
    filter = SCContentFilter(desktopIndependentWindow: window)
}
guard let filter else {
    FileHandle.standardError.write(Data("FAIL: no capture target for window \(windowID) (windows=\(content.windows.count) displays=\(content.displays.count))\n".utf8))
    exit(1)
}

let config = SCStreamConfiguration()
config.minimumFrameInterval = CMTime(value: 1, timescale: 240)
config.queueDepth = 8
config.showsCursor = false
if #available(macOS 14.0, *) {
    config.captureResolution = .nominal
}
let output = Output()
let stream = SCStream(filter: filter, configuration: config, delegate: nil)
do {
    try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "probe"))
    try await stream.startCapture()
} catch {
    FileHandle.standardError.write(Data("FAIL: start capture: \(error.localizedDescription)\n".utf8))
    exit(1)
}

print("# window=\(windowID) duration_ms=\(durationMS) timebase_numer=\(timebase.numer) timebase_denom=\(timebase.denom)")
print("seq,display_time,status,callback_tick,pts_seconds")
try await Task.sleep(for: .milliseconds(durationMS))
try? await stream.stopCapture()
exit(0)
