import Foundation
import CoreGraphics
import ApplicationServices

public struct MouseActivityPermissions: Codable, Equatable, Sendable {
    public var accessibilityGranted: Bool
    public var eventPostingGranted: Bool
    public var processID: Int32
    public var bundleIdentifier: String?
    public var executable: String
    public init(accessibilityGranted: Bool, eventPostingGranted: Bool, processID: Int32 = ProcessInfo.processInfo.processIdentifier,
                bundleIdentifier: String? = Bundle.main.bundleIdentifier, executable: String = CommandLine.arguments[0]) {
        self.accessibilityGranted = accessibilityGranted; self.eventPostingGranted = eventPostingGranted
        self.processID = processID; self.bundleIdentifier = bundleIdentifier; self.executable = executable
    }
}

public struct MouseActivityStatus: Codable, Equatable {
    public enum Phase: String, Codable { case off, ready, active, locked, permission, unavailable, failed }
    public var enabled: Bool
    public var phase: Phase
    public var detail: String
    public var lastSentAt: Date?
    public var permissions: MouseActivityPermissions?
    public init(enabled: Bool, phase: Phase, detail: String, lastSentAt: Date? = nil, permissions: MouseActivityPermissions? = nil) {
        self.enabled = enabled; self.phase = phase; self.detail = detail; self.lastSentAt = lastSentAt
        self.permissions = permissions
    }
}

public enum MouseActivitySession: Sendable { case active, locked, unavailable }

/// Only permission checks, session state and a mouse-move event. No clicks, keys or unlock actions.
public struct MouseActivityControl: Sendable {
    public var uptime: @Sendable () -> TimeInterval
    public var permission: @Sendable () -> Bool
    public var session: @Sendable () -> MouseActivitySession
    public var pulse: @Sendable () throws -> Void
    public var requestPermission: @MainActor @Sendable () -> Bool
    public var diagnostics: @Sendable () -> MouseActivityPermissions?
    public init(uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                permission: @escaping @Sendable () -> Bool, session: @escaping @Sendable () -> MouseActivitySession,
                pulse: @escaping @Sendable () throws -> Void, requestPermission: @escaping @MainActor @Sendable () -> Bool,
                diagnostics: @escaping @Sendable () -> MouseActivityPermissions? = { nil }) {
        self.uptime = uptime; self.permission = permission; self.session = session
        self.pulse = pulse; self.requestPermission = requestPermission
        self.diagnostics = diagnostics
    }
    public static let live = Self(permission: { CGPreflightPostEventAccess() }, session: { currentSession() }, pulse: {
        // Check again at delivery: a lock or permission change must not race the timer's earlier read.
        switch currentSession() {
        case .locked: throw MouseActivityFailure.locked
        case .unavailable: throw MouseActivityFailure.unavailable
        case .active: break
        }
        guard CGPreflightPostEventAccess() else { throw MouseActivityFailure.permission }
        guard let position = CGEvent(source: nil)?.location, position.x.isFinite, position.y.isFinite,
              let source = CGEventSource(stateID: .privateState),
              let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                  mouseCursorPosition: position, mouseButton: .left) else {
            throw AppError.message("마우스 신호를 준비하지 못했습니다.")
        }
        source.localEventsSuppressionInterval = 0
        // A stationary move signal keeps the pointer where the user put it.
        event.setIntegerValueField(.mouseEventDeltaX, value: 0)
        event.setIntegerValueField(.mouseEventDeltaY, value: 0)
        event.post(tap: .cghidEventTap)
    }, requestPermission: {
        if CGPreflightPostEventAccess() { return true }
        if !AXIsProcessTrusted() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary) }
        return CGRequestPostEventAccess()
    }, diagnostics: { MouseActivityPermissions(accessibilityGranted:AXIsProcessTrusted(),eventPostingGranted:CGPreflightPostEventAccess()) })

    private static func currentSession() -> MouseActivitySession {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return .unavailable }
        // macOS reports this flag while the screen is locked. Never send an event to a locked session.
        if session["CGSSessionScreenIsLocked"] as? Bool == true { return .locked }
        guard session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true else { return .unavailable }
        return .active
    }
}

private enum MouseActivityFailure: Error { case locked, permission, unavailable }

/// An opt-in, independent one-minute schedule. Work, pause, battery and temperature do not gate it.
@MainActor public final class MouseActivity {
    public static let interval: TimeInterval = 60
    public private(set) var status = MouseActivityStatus(enabled: false, phase: .off, detail: "마우스 신호가 꺼져 있습니다.")
    private let control: MouseActivityControl
    private var nextDue: TimeInterval?
    private var stopped = false
    private var activity: NSObjectProtocol?
    public init(control: MouseActivityControl = .live) { self.control = control }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != status.enabled || stopped else { return }
        stopped = false
        status.enabled = enabled
        nextDue = enabled ? control.uptime() + Self.interval : nil
        if enabled {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "사용자가 켠 1분 주기 마우스 신호를 유지합니다.")
            refreshAvailability()
        } else { endActivity(); setPhase(.off, "마우스 신호가 꺼져 있습니다.") }
    }

    public func stop() { stopped = true; nextDue = nil; endActivity() }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }

    @discardableResult public func requestPermission() -> Bool {
        let allowed = control.requestPermission()
        if status.enabled, !stopped { refreshAvailability() }
        return allowed
    }

    public func evaluate() {
        guard status.enabled, !stopped, let due = nextDue else { return }
        let now = control.uptime()
        guard now >= due else { return }
        // Missed minutes after sleep are not replayed in a burst.
        nextDue = now + Self.interval
        guard refreshAvailability() else { return }
        do {
            try control.pulse()
            status.lastSentAt = Date()
            setPhase(.active, "1분마다 마우스 신호를 보내고 있습니다.")
        } catch MouseActivityFailure.locked { setPhase(.locked, "화면이 잠겨 있어 신호를 보내지 않습니다. 직접 잠금을 해제하면 다시 보냅니다.") }
        catch MouseActivityFailure.permission { setPhase(.permission, "마우스 신호를 보내려면 손쉬운 사용 권한을 허용해주세요.") }
        catch MouseActivityFailure.unavailable { setPhase(.unavailable, "로그인한 Mac 화면을 확인할 수 없어 신호를 보내지 않습니다.") }
        catch { setPhase(.failed, "마우스 신호를 보내지 못했습니다. 다음 주기에 다시 확인합니다. \(error.localizedDescription)") }
    }

    @discardableResult private func refreshAvailability() -> Bool {
        status.permissions = control.diagnostics()
        switch control.session() {
        case .locked:
            setPhase(.locked, "화면이 잠겨 있어 신호를 보내지 않습니다. 직접 잠금을 해제하면 다시 보냅니다."); return false
        case .unavailable:
            setPhase(.unavailable, "로그인한 Mac 화면을 확인할 수 없어 신호를 보내지 않습니다."); return false
        case .active: break
        }
        guard control.permission() else {
            let detail = status.permissions?.accessibilityGranted == true
                ? "손쉬운 사용은 허용됐지만 마우스 신호 권한은 아직 확인되지 않습니다. 권한 다시 확인을 눌러 현재 설치본을 확인해주세요."
                : "현재 AutoApprove 설치본의 손쉬운 사용 권한을 확인하지 못했습니다. 시스템 설정에서 이 앱을 허용해주세요."
            setPhase(.permission, detail); return false
        }
        setPhase(.ready, "켜져 있습니다. 1분마다 현재 커서 위치에 마우스 신호를 보냅니다.")
        return true
    }
    private func setPhase(_ phase: MouseActivityStatus.Phase, _ detail: String) {
        status.phase = phase; status.detail = detail
    }
}
