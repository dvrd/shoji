import CoreGraphics
import Darwin
import Foundation

// Disposable guest visibility sampler. Polls CGWindowList for one window id at
// a fixed cadence and prints timestamped CSV rows so hold/release experiments
// can align window-list state with observer Mach ticks. Compile once with
// swiftc; never use swift -e at measurement time.
//
// usage: shoji-ws-visibility-sampler WINDOW_ID INTERVAL_US DURATION_MS

let arguments = CommandLine.arguments
guard arguments.count == 4,
      let windowID = UInt32(arguments[1]),
      let intervalUS = UInt32(arguments[2]),
      let durationMS = UInt32(arguments[3])
else {
    FileHandle.standardError.write(Data("usage: shoji-ws-visibility-sampler WINDOW_ID INTERVAL_US DURATION_MS\n".utf8))
    exit(2)
}

var timebase = mach_timebase_info_data_t()
mach_absolute_time()
if mach_timebase_info(&timebase) != KERN_SUCCESS {
    FileHandle.standardError.write(Data("FAIL: mach_timebase_info\n".utf8))
    exit(1)
}

let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
let startTick = mach_absolute_time()
let durationTicks = UInt64(durationMS) * 1_000_000 * UInt64(timebase.denom) / UInt64(timebase.numer)

print("# window=\(windowID) interval_us=\(intervalUS) duration_ms=\(durationMS)")
print("# timebase_numer=\(timebase.numer) timebase_denom=\(timebase.denom) start_tick=\(startTick)")
print("seq,tick_start,tick_end,found,onscreen,layer,alpha,x,y,width,height")

var sequence = 0
while true {
    let tickStart = mach_absolute_time()
    if tickStart - startTick > durationTicks { break }
    var found = 0
    var onscreen = 0
    var layer = -1
    var alpha = -1.0
    var bounds = CGRect.null
    autoreleasepool {
        if let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
            for entry in list {
                guard let number = entry[kCGWindowNumber as String] as? NSNumber,
                      number.uint32Value == windowID
                else { continue }
                found = 1
                if let flag = entry["kCGWindowIsOnscreen" as String] as? NSNumber, flag.boolValue {
                    onscreen = 1
                }
                if let value = entry[kCGWindowLayer as String] as? NSNumber { layer = value.intValue }
                if let value = entry[kCGWindowAlpha as String] as? NSNumber { alpha = value.doubleValue }
                if let value = entry[kCGWindowBounds as String] as? [String: Double] {
                    bounds = CGRect(
                        x: value["X"] ?? 0,
                        y: value["Y"] ?? 0,
                        width: value["Width"] ?? 0,
                        height: value["Height"] ?? 0
                    )
                }
            }
        }
    }
    let tickEnd = mach_absolute_time()
    print("\(sequence),\(tickStart),\(tickEnd),\(found),\(onscreen),\(layer),\(alpha),\(bounds.origin.x),\(bounds.origin.y),\(bounds.size.width),\(bounds.size.height)")
    sequence += 1
    if intervalUS > 0 { usleep(intervalUS) }
}
