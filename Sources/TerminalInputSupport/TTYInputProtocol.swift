import Foundation
import Darwin
private import CTTYInput

package enum ProcessStartTime {
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return value
    }()
    private static var zone: TimeZone?
    private static var strings: [Int64: String] = [:]
    private static var dates: [String: Date] = [:]

    private static func updateTimeZone() {
        let current = TimeZone.current
        if current != zone {
            zone = current
            formatter.timeZone = current
            strings.removeAll(keepingCapacity: true)
            dates.removeAll(keepingCapacity: true)
        }
    }

    package static func string(seconds: Int64) -> String {
        lock.lock()
        defer { lock.unlock() }
        updateTimeZone()
        if let value = strings[seconds] { return value }
        let value = formatter.string(from: Date(timeIntervalSince1970: Double(seconds)))
        if strings.count >= 512 { strings.removeAll(keepingCapacity: true) }
        strings[seconds] = value
        return value
    }

    package static func date(_ text: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        updateTimeZone()
        if let value = dates[text] { return value }
        guard let value = formatter.date(from: text) else { return nil }
        if dates.count >= 512 { dates.removeAll(keepingCapacity: true) }
        dates[text] = value
        return value
    }
}

public struct TTYInputIdentity: Codable, Equatable, Sendable {
    public var pid: Int32
    public var processGroup: Int32
    public var foregroundGroup: Int32
    public var uid: UInt32
    public var effectiveUID: UInt32
    public var device: UInt32
    public var startSeconds: UInt64
    public var startMicroseconds: UInt64
    public init(pid: Int32, processGroup: Int32, uid: UInt32, effectiveUID: UInt32, device: UInt32,
                startSeconds: UInt64, startMicroseconds: UInt64, foregroundGroup: Int32? = nil) {
        self.pid = pid; self.processGroup = processGroup; self.foregroundGroup = foregroundGroup ?? processGroup
        self.uid = uid; self.effectiveUID = effectiveUID; self.device = device
        self.startSeconds = startSeconds; self.startMicroseconds = startMicroseconds
    }
    public static func capture(pid: Int32) throws -> Self {
        var value = APTTYIdentity()
        let error = ap_tty_identity(pid, &value)
        guard error == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
        return Self(pid: value.pid, processGroup: value.process_group, uid: value.uid, effectiveUID: value.euid,
            device: value.device, startSeconds: value.start_seconds, startMicroseconds: value.start_microseconds,
            foregroundGroup: value.foreground_group)
    }
    public var processStart: String {
        ProcessStartTime.string(seconds: Int64(clamping: startSeconds))
    }
    /// Foreground jobs can change while the original CLI still exists. Bind
    /// its precise lifetime/device, then check foreground ownership at delivery.
    public func sameProcess(as other: Self) -> Bool {
        pid == other.pid && processGroup == other.processGroup && uid == other.uid && effectiveUID == other.effectiveUID
            && device == other.device && startSeconds == other.startSeconds && startMicroseconds == other.startMicroseconds
    }
}
