import Foundation
import Darwin

/// A device number is only a lookup hint. Verify the current character-device
/// node before using the usual macOS PTY name; other devices retain devname_r.
/// Nothing is cached across process snapshots.
enum NativeTerminalDevice {
    static func name(_ device: dev_t) -> String {
        guard device != -1 else { return "??" }
        let number = UInt32(bitPattern: device)
        if number >> 24 == 16 {
            let index = String(number & 0x00ff_ffff)
            let candidate = "ttys" + String(repeating: "0", count: max(0, 3 - index.count)) + index
            if matches("/dev/" + candidate, device: device) { return candidate }
        }
        var value = [CChar](repeating: 0, count: 128)
        return devname_r(device, mode_t(S_IFCHR), &value, Int32(value.count)) != nil ? String(cString: value) : "??"
    }

    static func matches(_ path: String, device: dev_t) -> Bool {
        var value = stat()
        return path.withCString { Darwin.lstat($0, &value) } == 0 &&
            value.st_mode & mode_t(S_IFMT) == mode_t(S_IFCHR) && value.st_rdev == device
    }
}
