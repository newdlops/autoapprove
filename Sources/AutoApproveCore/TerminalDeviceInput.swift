import Foundation
import Darwin
import TerminalInputSupport

public enum TerminalDeviceInput {
    public struct Environment: Sendable {
        public var available: @Sendable () -> Bool
        public var capture: @Sendable (Int32) throws -> TTYInputIdentity
        public var send: @Sendable (TTYInputRequest) throws -> TTYInputReply
        public init(available: @escaping @Sendable () -> Bool, capture: @escaping @Sendable (Int32) throws -> TTYInputIdentity,
                    send: @escaping @Sendable (TTYInputRequest) throws -> TTYInputReply) {
            self.available = available; self.capture = capture; self.send = send
        }
        public static var live: Self {
            Self(available: { TerminalInputClient.shared.isAvailable }, capture: { try TTYInputIdentity.capture(pid: $0) },
                send: { try TerminalInputClient.shared.deliver($0) })
        }
    }
    public static func deliver(target: ScreenTarget, agent: AgentKind, input: RemoteTerminalInput,
                               environment: Environment = .live) throws -> TerminalDelivery {
        try input.validate()
        guard agent != .shell, environment.available() else {
            throw RemoteHTTPError(409, "Mac 연결 설정의 ‘직접 입력 연결’을 확인해주세요. 새 연결은 macOS 로그인 항목 설정에서 허용하며 원래 CLI를 유지합니다.")
        }
        guard let pid = target.sourcePID, let started = target.sourceStarted, target.jobPIDs.contains(pid),
              let original = target.sourceIdentity else { return .agentMissing }
        let identity = try environment.capture(pid)
        guard identity.pid == pid, identity.processStart == started,
              identity.sameProcess(as: original),
              identity.uid == getuid(), identity.effectiveUID == geteuid(),
              identity.processGroup == identity.foregroundGroup else { return .agentMissing }
        let request = TTYInputRequest(identity: identity, tty: target.tty, bytes: Data(input.bytes.utf8),
            deadline: TTYInputConfiguration.uptime + 2)
        let reply = try environment.send(request)
        guard reply.written >= 0, reply.written <= request.bytes.count else {
            throw RemoteHTTPError(409, "입력 전달 결과를 확인하지 못했습니다. 다시 보내지 말고 원본 화면을 확인해주세요.")
        }
        if reply.error == 0, reply.written == request.bytes.count { return .sent }
        if reply.written > 0 {
            throw RemoteHTTPError(409, "원본 터미널에 일부 입력만 전달되었습니다. 다시 보내지 말고 화면을 확인해주세요.")
        }
        if [ESTALE, ESRCH, ENOENT].contains(reply.error) { return .agentMissing }
        if reply.error == EOPNOTSUPP {
            throw RemoteHTTPError(409, "원본 CLI가 직접 입력을 받는 터미널 모드가 아닙니다. Mac에서 CLI 입력 상태를 확인해주세요.")
        }
        throw RemoteHTTPError(409, "원본 터미널에 입력을 전달하지 못했습니다. Mac 연결 설정과 같은 CLI의 상태를 확인해주세요.")
    }
}
