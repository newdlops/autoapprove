import AppKit
import Combine
import SwiftUI
import UserNotifications
import AutoApproveCore

@MainActor final class QuestionNotifications: ObservableObject {
    @Published var authorization: UNAuthorizationStatus = .authorized
    @Published var busy = false
    @Published var error: String?
    var status: String { "합성 화면 검증 · 실제 알림은 보내지 않습니다" }
    func requestAuthorization() async {}
    func openSettings() {}
    func retryDelivery() async {}
}
@MainActor final class SafetyPreview: ObservableObject {
    let engine: ApprovalEngine
    let notifications = QuestionNotifications()
    init() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-safety-preview-" + UUID().uuidString)
        engine = try! ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] }, processReader: { [] })
        let request = "UI 합성 시험 · 실제 실행하지 않습니다.\ncp artifacts/" + String(repeating: "긴 경로/", count: 15) + "report.plist ~/Library/LaunchAgents/com.fixture.plist"
        let risk = SystemCommandRisk.detect(request)!
        let sessions = (0..<3).map { index -> AgentSession in
            var session = AgentSession(id: "preview:safety:\(index)", agent: .codex, pid: Int32(1200 + index), started: "synthetic", tty: "/dev/ttys-test-\(index)", cwd: "/fixture/" + ["합성 대안 안내 완료", "합성 시스템 변경 감지", "합성 전송 확인 필요"][index], terminal: .terminal)
            session.channel = .terminalScreen
            var notice = SystemSafetyNotice(id: "fixture-\(index)", risk: risk, request: request)
            notice.phase = [.guided, .detected, .uncertain][index]
            notice.message = ["시스템 변경을 거절하고 같은 대화에 안전한 대안을 전달했습니다.", "시스템 변경을 승인하지 않고 안전한 대안을 안내합니다.", "안내문의 전달 결과를 확인하지 못해 입력을 반복하지 않습니다."][index]
            session.systemSafety = notice
            session.phase = index == 0 ? .working : .approval
            if index > 0 { session.pendingSummary = request; session.systemCommandRisk = risk; session.pendingInTerminal = true }
            return session
        }
        engine.updateDiscovery(sessions, records: [])
    }
}
@main struct SystemSafetyPreviewApp: App {
    @StateObject private var model = SafetyPreview()
    var body: some Scene {
        Window("시스템 변경 보호 · 합성 시험", id: "main") {
            SessionWindow(engine: model.engine, notifications: model.notifications, openTerminal: { _,_ in })
        }.defaultSize(width: 1060, height: 760)
        Window("도움말 · 합성 시험", id: "help") {
            HelpWindow(connectionsAvailable: false)
        }.defaultSize(width: 540, height: 660)
    }
}
