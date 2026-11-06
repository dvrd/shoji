#!/usr/bin/env swift
// B3 sentinel toggle for the disposable guest. usage: sentinel.swift on|off
// Run with sudo on the guest: the sentinel must be root-owned.
import Foundation

let sentinel = "/Library/GPUBundles/ShojiWindowServerProbe/DISABLED"

func die(_ msg: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(code)
}

guard CommandLine.arguments.count >= 2 else { die("usage: sentinel.swift on|off", 2) }

switch CommandLine.arguments[1] {
case "on":
    let stamp = ISO8601DateFormatter().string(from: Date())
    do { try "disabled \(stamp)\n".write(toFile: sentinel, atomically: true, encoding: .utf8) }
    catch { die("cannot write \(sentinel): \(error)", 1) }
    chown(sentinel, 0, 0)   // root:wheel
    chmod(sentinel, 0o644)
    print("sentinel on")
case "off":
    try? FileManager.default.removeItem(atPath: sentinel)
    print("sentinel off")
default:
    die("usage: sentinel.swift on|off", 2)
}
