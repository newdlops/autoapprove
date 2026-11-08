import AppKit
import AutoApproveCore

@MainActor enum TerminalNavigator {
    static func open(_ session: AgentSession, engine: ApprovalEngine) async throws {
        // Retain this process across the exact-tab reveal. A replacement host
        // must not inherit a delayed notification's activation request.
        let application=ScreenHost(kind:session.terminal).flatMap {NSRunningApplication.runningApplications(withBundleIdentifier:$0.bundleID).first}
        try await open(session,reveal:{try await engine.reveal(session)},activate:{host in
            guard let application,application.bundleIdentifier==host.bundleID else {throw AppError.message("대상 터미널 앱을 찾지 못했습니다. 목록을 새로고침해주세요.")}
            try await activate(application)
        })
    }

    static func activate(_ application:NSRunningApplication) async throws {
        guard !application.isTerminated else {throw AppError.message("대상 터미널 앱이 종료되었습니다. 목록을 새로고침해주세요.")}
        // macOS 14+ activation is cooperative. A helper's scripted activate is
        // insufficient when AutoApprove owns the notification's foreground.
        NSApp.yieldActivation(to:application)
        guard application.activate(from:.current,options:[]) else {throw AppError.message("macOS가 터미널 앱 전환을 허용하지 않았습니다. 터미널 열기를 다시 눌러주세요.")}
        for _ in 0..<50 {
            try Task.checkCancellation()
            if application.isActive {return}
            guard !application.isTerminated else {throw AppError.message("대상 터미널 앱이 종료되었습니다. 목록을 새로고침해주세요.")}
            try await Task.sleep(for:.milliseconds(20))
        }
        throw AppError.message("터미널 탭은 찾았지만 앱 전환을 확인하지 못했습니다. 터미널 열기를 다시 눌러주세요.")
    }

    static func open(_ session:AgentSession,reveal:() async throws -> TerminalWindowBounds?,activate:(ScreenHost) async throws -> Void) async throws {
        TerminalHighlighter.shared.dismiss()
        let host = ScreenHost(kind: session.terminal)
        let bounds = try await reveal()
        if let host {
            try await activate(host)
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
