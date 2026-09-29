import AppKit
import AutoApproveCore

@MainActor enum TerminalNavigator {
    static func open(_ session: AgentSession, engine: ApprovalEngine) async throws {
        TerminalHighlighter.shared.dismiss()
        let host = ScreenHost(kind: session.terminal)
        let bounds = try await engine.reveal(session)
        // A scripted activate from a helper process does not take focus on current macOS;
        // the foreground app must request it. Terminal already activates from its own script.
        if let host, host != .terminal {
            NSRunningApplication.runningApplications(withBundleIdentifier: host.bundleID).first?.activate()
        }
        if let bounds {
            guard let height = NSScreen.screens.first?.frame.height,
                  let frame = bounds.appKitFrame(primaryScreenHeight: height) else {
                throw AppError.message("터미널은 열었지만 창 위치를 확인하지 못했습니다. 다시 열기를 눌러주세요.")
            }
            TerminalHighlighter.shared.show(frame: frame, project: session.project,
                detail: "\(session.agent.title) · \(session.tty)", ownerBundleID: host?.bundleID ?? "com.apple.Terminal")
        }
    }
}
