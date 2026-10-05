import Foundation
import Darwin
private import CTTYInput

public enum TTYInputConfiguration {
    public static let service = "local.autoapprove.tty-input"
    public static let appIdentifier = "local.autoapprove.mac"
    public static let cliIdentifier = "local.autoapprove.helper"
    public static let helperIdentifier = "local.autoapprove.tty-input"
    public static let helperName = "AutoApproveTTYService"
    public static let helperPath = "/Library/PrivilegedHelperTools/local.autoapprove.tty-input"
    public static let plistPath = "/Library/LaunchDaemons/local.autoapprove.tty-input.plist"
    public static var uptime: Double { ap_tty_uptime() }
}

@objc public protocol TerminalInputServiceProtocol {
    func status(withReply reply: @escaping (Int32) -> Void)
    func deliver(_ packet: Data, withReply reply: @escaping (Data) -> Void)
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
    fileprivate var raw: APTTYIdentity {
        APTTYIdentity(pid: pid, process_group: processGroup, foreground_group: foregroundGroup, uid: uid, euid: effectiveUID,
            device: device, start_seconds: startSeconds, start_microseconds: startMicroseconds)
    }
    public var processStart: String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current; formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.string(from: Date(timeIntervalSince1970: Double(startSeconds)))
    }
    /// Foreground jobs can change while the original CLI still exists. Bind
    /// its precise lifetime/device, then check foreground ownership at delivery.
    public func sameProcess(as other: Self) -> Bool {
        pid == other.pid && processGroup == other.processGroup && uid == other.uid && effectiveUID == other.effectiveUID
            && device == other.device && startSeconds == other.startSeconds && startMicroseconds == other.startMicroseconds
    }
}

public struct TTYInputRequest: Codable, Equatable, Sendable {
    public var id: UUID
    public var identity: TTYInputIdentity
    public var tty: String
    public var bytes: Data
    public var deadline: Double
    public init(identity: TTYInputIdentity, tty: String, bytes: Data, deadline: Double, id: UUID = UUID()) {
        self.id = id; self.identity = identity; self.tty = tty; self.bytes = bytes; self.deadline = deadline
    }
    public func error(now: Double, caller: UInt32) -> Int32 {
        guard caller != 0, identity.uid == caller, identity.effectiveUID == caller else { return EACCES }
        guard deadline.isFinite, deadline <= now + 2.1, !bytes.isEmpty, bytes.count <= 8000,
              identity.pid > 0, identity.processGroup > 0, identity.foregroundGroup == identity.processGroup,
              identity.startSeconds > 0, identity.startMicroseconds < 1_000_000,
              tty.hasPrefix("/dev/ttys"), (1...5).contains(tty.dropFirst(9).count),
              tty.dropFirst(9).utf8.allSatisfy({ (48...57).contains($0) }) else { return EINVAL }
        return deadline > now ? 0 : ETIMEDOUT
    }
    static func write(_ request: Self, caller: UInt32) -> TTYInputReply {
        var identity = request.identity.raw, result = APTTYWriteResult()
        let error = request.bytes.withUnsafeBytes { bytes in
            request.tty.withCString { tty in
                ap_tty_write(&identity, caller, tty, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count,
                    request.deadline, &result)
            }
        }
        return TTYInputReply(error: error, written: result.written)
    }
}

public struct TTYInputReply: Codable, Equatable, Sendable {
    public var error: Int32
    /// Submitted to the original TTY; application consumption is not acknowledged.
    public var written: Int
    public init(error: Int32, written: Int) { self.error = error; self.written = written }
}
