import Foundation
import Darwin
private import CTTYInput

public struct TTYInputIdentity: Codable, Equatable, Sendable {
    private static let processStartFormatterLock = NSLock()
    private static let processStartFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()
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
        Self.processStartFormatterLock.lock()
        defer { Self.processStartFormatterLock.unlock() }
        // Keep an already-running app correct if the user changes time zone.
        if Self.processStartFormatter.timeZone.identifier != TimeZone.current.identifier {
            Self.processStartFormatter.timeZone = .current
        }
        return Self.processStartFormatter.string(from: Date(timeIntervalSince1970: Double(startSeconds)))
    }
    /// Foreground jobs can change while the original CLI still exists. Bind
    /// its precise lifetime/device, then check foreground ownership at delivery.
    public func sameProcess(as other: Self) -> Bool {
        pid == other.pid && processGroup == other.processGroup && uid == other.uid && effectiveUID == other.effectiveUID
            && device == other.device && startSeconds == other.startSeconds && startMicroseconds == other.startMicroseconds
    }
}
