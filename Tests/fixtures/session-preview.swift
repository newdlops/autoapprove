// Native production views with synthetic sessions, local persistence and no live transports.
import AppKit
import Combine
import SwiftUI
import UserNotifications
import AutoApproveCore

private let previewStarted = "Tue Sep 22 09:00:00 2026"
private let previewProcesses = ProcessDiscovery.parse("""
1 0 ?? 1 0 Tue Sep 22 09:00:00 2026 /sbin/launchd
10 1 ?? 10 0 Tue Sep 22 09:00:00 2026 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
1100 10 ttys037 1100 2200 Tue Sep 22 09:00:00 2026 /bin/zsh
1101 10 ttys038 1101 2201 Tue Sep 22 09:00:00 2026 /bin/zsh
2200 1100 ttys037 2200 2200 Tue Sep 22 09:00:00 2026 claude
2201 1101 ttys038 2201 2201 Tue Sep 22 09:00:00 2026 claude
999 2200 ?? 999 0 Tue Sep 22 09:00:00 2026 claude bg-pty-host
2202 999 ttys039 2202 2202 Tue Sep 22 09:00:00 2026 claude
2203 999 ttys040 2203 2203 Tue Sep 22 09:00:00 2026 claude
""")

@MainActor final class QuestionNotifications: ObservableObject {
    @Published var authorization: UNAuthorizationStatus = .authorized
    @Published var busy = false
    @Published var error: String?
    var status: String { "검증용 알림 대역" }
    func requestAuthorization() async {}
    func openSettings() {}
    func retryDelivery() async {}
}

@MainActor final class SessionPreview: ObservableObject {
    let engine: ApprovalEngine
    let notifications = QuestionNotifications()
    let sessions: [AgentSession]
    private var subscription: AnyCancellable?
    private var timer: Timer?
    private var hookPayloads: [JSONObject] = []
    private var hookPaused = false
    private let root = Bundle.main.bundleURL.deletingLastPathComponent()

    init() {
        engine = try! ApprovalEngine(paths: AppPaths(directory: root.appendingPathComponent("parent-preview-data")), terminalReader: { _ in TerminalSnapshot() }, claudeRegistryReader: { _ in [] }, processReader: { previewProcesses })
        sessions = (0..<4).map { index in
            var session = AgentSession(id: "process:\(2200 + index):\(previewStarted)", agent: .claude,
                pid: Int32(2200 + index), started: previewStarted, tty: "/dev/ttys0\(37 + index)", cwd: "/tmp/결제 서비스", terminal: index >= 2 ? .claudeBackground : .terminal)
            session.phase = .idle; session.channel = .hook
            session.terminalTitle = ["결제 API · 구현", "주문 이력 · 회귀 검증", "백그라운드 작업", "백그라운드 검토"][index]
            session.activityDetail = "다음 작업을 기다리고 있습니다."
            session.gitBranch = .init(kind: .branch, name: "feature/session-identification")
            return session
        }
        engine.updateDiscovery(sessions, records: previewProcesses)
        let statePath = root.appendingPathComponent("session-preview-state.json")
        subscription = engine.$snapshot.sink { snapshot in
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: statePath, options: .atomic) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.engine.refreshNotices()
                if !self.hookPaused {
                    self.hookPayloads = self.hookPayloads.filter { payload in
                        guard let result = try? self.engine.handleClaudeHook(payload),
                              let bridge = result["autoapproveBridge"] as? JSONObject else { return true }
                        if bridge["response"] != nil { try? self.engine.acknowledgeClaudeHook(payload); return false }
                        return true
                    }
                }
            }
        }
    }

    func notify(_ index: Int, completion: Bool, manual: Bool = false) {
        let session = sessions[index]
        var payload: JSONObject = ["session_id": "preview-\(index)", "agentPID": session.pid,
            "agentStarted": session.started, "requestID": UUID().uuidString, "tty": session.tty, "cwd": session.cwd]
        if completion {
            payload["hook_event_name"] = "UserPromptSubmit"; _ = engine.handleHook(payload)
            payload["hook_event_name"] = "Stop"; payload["last_assistant_message"] = "검증용: 중복 결제와 환불 흐름의 확인을 마쳤습니다. 변경 내역을 검토해주세요."
        } else {
            payload["hook_event_name"] = "PreToolUse"; payload["tool_name"] = "AskUserQuestion"
            payload["tool_use_id"] = UUID().uuidString
            payload["tool_input"] = ["questions": [["question": "검증용: 다음 작업으로 계속 진행할까요?", "header": "확인", "multiSelect": false,
                "options": [["label": "허용", "description": "이번 작업을 진행합니다."], ["label": "항상 허용", "description": "다음부터 묻지 않습니다."], ["label": "거부", "description": "다음 질문으로 넘어갑니다."]]]]]
            if manual {
                payload["tool_input"] = ["questions": [["question": "검증용: \(index == 2 ? "중복 결제와 환불" : "주문 이력") 검토에서 어떤 환경을 먼저 확인할까요? " + String(repeating: "기존 사용자 데이터와 처리 중인 주문에 미치는 영향을 확인한 뒤 진행 방향을 선택해주세요. ", count: 2),
                    "options": [["label": "개발 환경", "description": "검증용 데이터로 확인합니다."], ["label": "운영 환경", "description": "실제 처리 내역을 검토합니다."]]]]]
            }
        }
        _ = engine.handleHook(payload)
    }

    func longMetadata() {
        try! engine.setCustomization(sessions[0].id, value: SessionCustomization(
            title: String(repeating: "긴 이름·결제 확인 ", count: 6),
            note: String(repeating: "결제 완료 이후 환불 상태가 갱신되는지 확인하고 예외 기록을 남깁니다.\n", count: 25), color: .yellow))
    }
    func appApproval(long: Bool = false) {
        let child = sessions[2]
        let payload: JSONObject = ["autoapproveProtocol": 1, "autoapproveExpiresAt": Date().addingTimeInterval(600).timeIntervalSince1970,
            "session_id": "preview-2", "agentPID": child.pid, "agentStarted": child.started, "requestID": UUID().uuidString,
            "tty": child.tty, "cwd": child.cwd, "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_use_id": UUID().uuidString,
            "tool_input": ["questions": [["question": "이 작업을 허용할까요?" + (long ? String(repeating: " 기존 사용자 데이터와 주문 내역에 미치는 영향을 확인한 뒤 진행합니다.", count: 3) : ""),
                "options": [["label": "허용", "description": "이번 요청만 허용합니다."], ["label": "항상 허용", "description": "앞으로 묻지 않습니다."], ["label": "거부", "description": "진행하지 않습니다."]]]]]]
        hookPayloads.append(payload); _ = try! engine.handleClaudeHook(payload)
    }
    func holdDelivery() { hookPaused.toggle() }
    func failHookSaving() { _ = try! CommandRunner.run("/usr/bin/sqlite3", [engine.paths.database, "CREATE TRIGGER fail_hook BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT, 'fixture'); END;"]) }
    func restoreHookSaving() { _ = try! CommandRunner.run("/usr/bin/sqlite3", [engine.paths.database, "DROP TRIGGER IF EXISTS fail_hook"]) }
    func recoverWaiting(resolved: Bool = false) {
        let input: JSONObject = ["questions": [["question": "이 작업을 허용할까요?", "options": [
            ["label": "허용", "description": "이번만 허용합니다."],
            ["label": "항상 허용", "description": "앞으로 묻지 않고 항상 허용합니다."],
            ["label": "거부", "description": "허용하지 않습니다."]]]]]
        let activity = ClaudeSessionActivity(providerID: "preview-2", status: resolved ? "busy" : "waiting",
            waitingFor: resolved ? nil : "input needed", changedAt: Date(),
            questionSummary: resolved ? nil : QuestionDetector.hookSummary(tool: "AskUserQuestion", input: input))
        engine.updateDiscovery(sessions, records: previewProcesses,
            claudeRegistrations: [.init(processID: sessions[2].id, kind: "bg", jobID: "preview-job", activity: activity)])
    }
    func failSaving() { _ = try! CommandRunner.run("/usr/bin/sqlite3", [engine.paths.database, "DROP TABLE settings"]) }
    func restoreSaving() { _ = try! AuditStore(path: engine.paths.database) }
    func endFirst() { engine.updateDiscovery(Array(sessions.dropFirst()), records: previewProcesses.filter { $0.pid != 2200 }) }
    func resize(compact: Bool) {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) else { return }
        window.setFrame(NSRect(origin: window.frame.origin, size: compact ? NSSize(width: 784, height: 612) : NSSize(width: 1040, height: 700)), display: true)
    }
}

@main struct SessionPreviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var fixture = SessionPreview()
    var body: some Scene {
        Window("세션 표시 · 검증용 데이터", id: "main") {
            SessionWindow(engine: fixture.engine, notifications: fixture.notifications, openTerminal: { _, _ in })
        }.defaultSize(width: 1040, height: 648).windowResizability(.contentMinSize)
        .commands {
            AppCommands(connectionsAvailable: true)
            CommandMenu("검증") {
                Button("첫 번째 새 질문") { fixture.notify(0, completion: false) }.keyboardShortcut("q", modifiers: [.command, .shift])
                Button("두 번째 새 질문") { fixture.notify(1, completion: false) }.keyboardShortcut("n")
                Button("세 번째 작업 완료") { fixture.notify(2, completion: true) }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button("백그라운드 허용 질문") { fixture.notify(2, completion: false) }.keyboardShortcut("b", modifiers: [.command, .shift])
                Button("백그라운드 동시 긴 질문") { fixture.notify(2, completion: false, manual: true); fixture.notify(3, completion: false, manual: true) }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("기존 백그라운드 질문 복원") { fixture.recoverWaiting() }.keyboardShortcut("u", modifiers: [.command, .shift])
                Button("앱에서 허용 질문") { fixture.appApproval() }.keyboardShortcut("a", modifiers: [.command, .shift])
                Button("앱에서 긴 허용 질문") { fixture.appApproval(long: true) }.keyboardShortcut("g", modifiers: [.command, .shift])
                Button("응답 수신 대역 일시정지") { fixture.holdDelivery() }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button("응답 저장 실패") { fixture.failHookSaving() }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("응답 저장 복구") { fixture.restoreHookSaving() }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("복원 질문 해결") { fixture.recoverWaiting(resolved: true) }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button("긴 이름과 메모") { fixture.longMetadata() }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("저장 실패") { fixture.failSaving() }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("저장 복구") { fixture.restoreSaving() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("첫 번째 세션 종료") { fixture.endFirst() }.keyboardShortcut("x", modifiers: [.command, .shift])
                Divider()
                Button("기본 창 1040×700") { fixture.resize(compact: false) }.keyboardShortcut("1")
                Button("최소 창 784×612") { fixture.resize(compact: true) }.keyboardShortcut("2")
            }
        }
        Window("승인 내역", id: "history") { AuditHistoryWindow(engine: fixture.engine) }.defaultSize(width: 1040, height: 700).commandsRemoved()
        Window("연결 설정", id: "settings") { ConnectionSettings(engine: fixture.engine, notifications: fixture.notifications) }.windowResizability(.contentSize).commandsRemoved()
        Window("AutoApprove 도움말", id: "help") { HelpWindow() }.defaultSize(width: 620, height: 660).commandsRemoved()
    }
}
