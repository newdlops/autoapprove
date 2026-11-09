import Foundation
import ApplicationServices

public enum TerminalInputStatus: Equatable, Sendable {
    case notInstalled, available, requiresApproval, unavailable(String)
    public var message: String {
        switch self {
        case .available: return "손쉬운 사용으로 직접 입력 연결됨 · 별도 root 입력 서비스를 사용하지 않습니다."
        case .notInstalled, .requiresApproval: return "Mac의 손쉬운 사용에서 AutoApprove를 허용해주세요. 별도 입력 서비스나 관리자 설치는 사용하지 않습니다."
        case .unavailable(let message): return message
        }
    }
    public var available: Bool { self == .available }
}

/// Compatibility facade for existing callers. No Mach service is connected or installed.
public final class TerminalInputClient: @unchecked Sendable {
    public static let shared = TerminalInputClient()
    private init() {}
    public var state: TerminalInputStatus { probe() }
    public var isAvailable: Bool { state.available }
    public func refreshIfNeeded(force: Bool = false) {}
    public func refreshNow() -> TerminalInputStatus { probe() }
    public func resetConnection() {}
    private func probe() -> TerminalInputStatus {
        TerminalKeyboard.isAvailable && CGPreflightPostEventAccess() ? .available : .notInstalled
    }
}
