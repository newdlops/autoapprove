import Foundation
import Darwin
import TerminalInputSupport

/// Terminal input is delivered by the user app under its Accessibility permission.
public enum TerminalDeviceInput {
    public static let unavailableBeforeInputMessage = "Mac의 손쉬운 사용에서 AutoApprove의 직접 입력 권한을 허용해주세요."
    public static func deliver(target: ScreenTarget, agent: AgentKind, input: RemoteTerminalInput, screen: String = "",
                               environment: TerminalKeyboard.Environment = .live,
                               captureIdentity: @escaping @Sendable (Int32) throws -> TTYInputIdentity = { try TTYInputIdentity.capture(pid:$0) }) throws -> TerminalDelivery {
        try input.validate()
        guard let pid = target.sourcePID, let started = target.sourceStarted, target.jobPIDs.contains(pid),
              let original = target.sourceIdentity, original.pid == pid, original.processStart == started else { return .agentMissing }
        let valid: @Sendable () -> Bool = {
            guard let current = try? captureIdentity(pid) else { return false }
            return current.sameProcess(as:original) && current.uid == getuid() && current.effectiveUID == geteuid()
                && current.processGroup == current.foregroundGroup
        }
        guard valid() else { return .agentMissing }
        var keyboard = environment
        keyboard.postPair = { owner, down, up in
            guard valid() else { throw RemoteHTTPError(409,"원본 CLI의 실행 식별자나 전경 작업이 바뀌어 입력하지 않았습니다.") }
            try environment.postPair(owner,down,up)
        }
        return try TerminalKeyboard.deliver(target:target,expected:screen,agent:agent,input:input,environment:keyboard)
    }
}
