#!/usr/bin/swift
// Send one command to the persistent gate controller and print its response.
// Single driver at a time (the sequence file is not locked).
// usage: gate-ctl.swift <command> [args...]
import Foundation

let req = "/private/tmp/shoji-gate-controller-request"
let resp = "/private/tmp/shoji-gate-controller-response"
let seqfile = "/private/tmp/shoji-gate-controller-seq"

// The runner preamble may delete the seq file while the controller still
// dedupes on content; seed from the epoch so the content never repeats.
var seq = Int(Date().timeIntervalSince1970)
if let s = try? String(contentsOfFile: seqfile, encoding: .utf8),
   let n = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
    seq = n
}
seq += 1
try? "\(seq)\n".write(toFile: seqfile, atomically: true, encoding: .utf8)

let cmd = CommandLine.arguments.dropFirst().joined(separator: " ")
do { try "\(seq) \(cmd)\n".write(toFile: req, atomically: true, encoding: .utf8) }
catch {
    FileHandle.standardError.write(Data("cannot write \(req): \(error)\n".utf8))
    exit(1)
}

let prefix = "\(seq) "
for _ in 0..<200 {
    if let body = try? String(contentsOfFile: resp, encoding: .utf8),
       let line = body.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) {
        print(line)
        exit(0)
    }
    usleep(50_000) // 0.05s
}
FileHandle.standardError.write(Data("TIMEOUT waiting for response \(seq) (\(cmd))\n".utf8))
exit(1)
