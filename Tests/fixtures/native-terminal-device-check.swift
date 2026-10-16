import Foundation
import Darwin

@main struct NativeTerminalDeviceCheck {
    static func cpu() -> Double {
        var value = rusage(); precondition(getrusage(RUSAGE_SELF, &value) == 0)
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6
    }
    static func legacy(_ device: dev_t) -> String {
        guard device != -1 else { return "??" }
        var value = [CChar](repeating: 0, count: 128)
        return devname_r(device, mode_t(S_IFCHR), &value, Int32(value.count)) != nil ? String(cString: value) : "??"
    }
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp/aa-devices-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let regular = root.appendingPathComponent("regular"), link = root.appendingPathComponent("link")
        try Data().write(to: regular)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/dev/null")
        var null = stat(); precondition(lstat("/dev/null", &null) == 0)
        precondition(NativeTerminalDevice.matches("/dev/null", device: null.st_rdev))
        precondition(!NativeTerminalDevice.matches(regular.path, device: null.st_rdev))
        precondition(!NativeTerminalDevice.matches(link.path, device: null.st_rdev))
        precondition(!NativeTerminalDevice.matches("/dev/null", device: -1))
        precondition(!NativeTerminalDevice.matches(root.appendingPathComponent("missing").path, device: null.st_rdev))
        var devices = Set<dev_t>([-1, null.st_rdev, 0])
        for name in try FileManager.default.contentsOfDirectory(atPath: "/dev") where name.hasPrefix("ttys") {
            var node = stat()
            if lstat("/dev/" + name, &node) == 0, node.st_mode & mode_t(S_IFMT) == mode_t(S_IFCHR) { devices.insert(node.st_rdev) }
        }
        precondition(devices.count > 3)
        for device in devices { precondition(NativeTerminalDevice.name(device) == legacy(device), "Current OS names must match") }
        var trials: [[String: Any]] = []
        for current in [false, true, false, true, false, true] {
            let start = ProcessInfo.processInfo.systemUptime, before = cpu()
            var sum = 0
            for _ in 0..<20 { for device in devices { sum += (current ? NativeTerminalDevice.name(device) : legacy(device)).utf8.count } }
            trials.append(["current": current, "cpuSeconds": cpu() - before, "wallSeconds": ProcessInfo.processInfo.systemUptime - start, "checksum": sum])
        }
        precondition(Set(trials.compactMap { $0["checksum"] as? Int }).count == 1)
        let report: [String: Any] = ["devices": devices.count, "iterations": 20, "trials": trials,
            "verified": ["current OS parity", "fresh character-device identity", "reject regular file", "reject symlink", "reject changed device", "reject missing node"],
            "scope": "Real current /dev read-only names. Same exact production helper; no device opens, input, name logging, cross-read cache or permission changes."]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
}
