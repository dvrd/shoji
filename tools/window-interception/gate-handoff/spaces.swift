import Foundation

// List managed-display spaces for the space-move fixture. Prints one line:
// ACTIVE <id64> then per space "SPACE <id64>" in display order.
@_silgen_name("SLSMainConnectionID") func SLSMainConnectionID() -> Int32
@_silgen_name("SLSCopyManagedDisplaySpaces") func SLSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray?
@_silgen_name("SLSGetActiveSpace") func SLSGetActiveSpace(_ cid: Int32) -> UInt64

let cid = SLSMainConnectionID()
guard cid != 0, let displays = SLSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else {
    FileHandle.standardError.write("no spaces\n".data(using: .utf8)!)
    exit(1)
}
print("ACTIVE \(SLSGetActiveSpace(cid))")
for display in displays {
    guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
    for space in spaces {
        if let id = space["id64"] as? UInt64 {
            print("SPACE \(id)")
        } else if let number = space["id64"] as? NSNumber {
            print("SPACE \(number.uint64Value)")
        }
    }
}
