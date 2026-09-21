import AppKit
import AutoApproveCore

@MainActor enum TerminalNavigator {
    static func open(_ session: AgentSession, engine: ApprovalEngine) async throws {
        TerminalHighlighter.shared.dismiss()
        if let bounds = try await engine.reveal(session) {
            guard let height = NSScreen.screens.first?.frame.height,
                  let frame = bounds.appKitFrame(primaryScreenHeight: height) else {
                throw AppError.message("터미널은 열었지만 창 위치를 확인하지 못했습니다. 다시 열기를 눌러주세요.")
            }
            TerminalHighlighter.shared.show(frame: frame, project: session.project,
                detail: "\(session.agent.title) · \(session.tty)", ownerBundleID: "com.apple.Terminal")
        }
    }
}
