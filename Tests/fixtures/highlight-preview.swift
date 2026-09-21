// A standalone UI harness using the production overlay. Never reads or opens user terminals.
import AppKit
import SwiftUI
import AutoApproveCore
import UserNotifications

@MainActor final class AuditPreviewFixture: ObservableObject {
    let engine: ApprovalEngine
    private(set) var notifications: QuestionNotifications!
    @Published var notificationResult = "알림 검증 대기"
    @Published var opened = 0
    private var openedTerminals = 0
    @Published var terminalOpenResult = "세션 관리 · 열기 0회"
    private var questionID = UUID().uuidString
    private var completionTurn = UUID().uuidString
    init() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("autoapprove-ui-preview-" + UUID().uuidString)
        let paths = AppPaths(directory: directory)
        try! paths.prepare()
        let store = try! AuditStore(path: paths.database)
        for index in 0..<125 {
            let session = AgentSession(id: "preview-\(index)", agent: index % 2 == 0 ? .claude : .codex, pid: Int32(1200 + index), started: "preview", tty: "/dev/ttys-test", cwd: index % 2 == 0 ? "/tmp/자동 승인 기록 검증용 긴 프로젝트 이름" : "/tmp/preview-project", terminal: .terminal)
            var event = AuditEvent(sessionID: session.id, summary: "테스트 요청 \(index): npm test -- --project preview", outcome: index % 3 == 0 ? "승인 입력 전달" : (index % 3 == 1 ? "입력 미전달 · 새 화면 확인" : "터미널에서 확인"), source: index % 2 == 0 ? "Claude 훅" : "Terminal 화면", context: AuditContext(session: session), tool: "Bash", request: "# UI 검증용 기록 — 실제 실행한 명령이 아닙니다.\n\n" + String(repeating: "npm test -- --project preview --reporter verbose\n", count: index == 0 ? 40 : 1))
            if index < 4 { event.sessionID = "preview-0" }
            event.date = Date().addingTimeInterval(-Double(index * 60))
            if index == 1 {
                event.summary = "UI 검증용: 여기서 바로 작업을 시작할까요?\n1. 예\n2. 아니오"
                event.outcome = "질문 응답 전달"; event.tool = "AskUserQuestion"; event.answer = "예"
                event.context?.agent = .claude; event.source = "Claude 훅"
                event.request = "UI 검증용 기록 — 실제 질문이나 응답이 아닙니다.\n\n여기서 바로 작업을 시작할까요?\n1. 예 — 현재 작업 위치에서 진행합니다.\n2. 아니오 — 다른 위치를 정합니다."
            }
            try! store.append(event)
        }
        engine = try! ApprovalEngine(paths: paths, questionTransport: CodexReplyTransport(prepare: { _, question in
            CodexReplyTarget(executable: "/unused-preview", home: "/unused-preview", threadID: question.threadID)
        }, send: { _, text in
            try await Task.sleep(nanoseconds: 700_000_000)
            if text.contains("fixture failure") { throw AppError.message("검증용: 접수 결과를 확인하지 못했습니다. 터미널에서 확인해주세요.") }
            return UUID().uuidString
        }))
        var session = AgentSession(id: "preview-0", agent: .codex, pid: 1200, started: "preview", tty: "/dev/ttys-test", cwd: "/tmp/자동 승인 기록 검증용 긴 프로젝트 이름", terminal: .vscode)
        session.phase = .working
        session.bridgeID = "preview"; session.terminalID = "preview-0"; session.channel = .vscodeScreen
        session.terminalTitle = "미커밋 변경 정리 · 여러 워크트리의 상태를 확인하는 아주 긴 터미널 제목"
        var second = AgentSession(id: "preview-1", agent: .claude, pid: 1201, started: "preview", tty: "/dev/ttys-second", cwd: "/tmp/두 번째 터미널", terminal: .terminal)
        second.phase = .idle; second.channel = .terminalScreen; second.terminalTitle = "두 번째 창 · 더블클릭 검증"
        let disconnected = AgentSession(id: "preview-disconnected", agent: .codex, pid: 1202, started: "preview", tty: "/dev/ttys-disconnected", cwd: "/tmp/연결 전 터미널", terminal: .vscode)
        engine.updateDiscovery([session, second, disconnected], records: [])
        queueQuestions()
        notifications = QuestionNotifications(engine: engine, openSession: { [weak self] id in
            guard let self, ["claude:notification-preview", "preview-0"].contains(id),
                  let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "preview" }) else {
                throw AppError.message("검증 창을 찾지 못했습니다.")
            }
            self.opened += 1
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            TerminalHighlighter.shared.show(frame: window.frame, project: "알림 검증 프로젝트",
                detail: "검증용 창 · 실제 터미널 아님", ownerBundleID: Bundle.main.bundleIdentifier!)
        })
    }

    func openTerminal(_ session: AgentSession, engine: ApprovalEngine) async throws {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "queue" }) else {
            throw AppError.message("세션 검증 창을 찾지 못했습니다.")
        }
        openedTerminals += 1
        terminalOpenResult = "세션 관리 · 열기 \(openedTerminals)회 · \(session.id)"
        window.makeKeyAndOrderFront(nil)
        TerminalHighlighter.shared.show(frame: window.frame, project: session.project,
            detail: "\(session.id) · 실제 터미널 아님", ownerBundleID: Bundle.main.bundleIdentifier!)
    }

    func queueQuestions() {
        engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: "preview-0", questions: [
            QueuedQuestion(id: "preview-queue-1", threadID: "preview", title: "검증용: 어느 작업부터 시작할까요?", options: ["미커밋 현황을 모아 정리합니다.", "열린 PR의 CI와 리뷰 상태를 확인합니다.", "지정한 작업부터 시작합니다."]),
            QueuedQuestion(id: "preview-queue-2", threadID: "preview", title: "검증용: 여러 프로젝트에 걸친 변경을 확인할 때 포함할 범위와 제외해야 할 작업을 알려주세요.")
        ])])
    }

    func question(new: Bool) {
        if new { questionID = UUID().uuidString }
        _ = engine.handleHook(["session_id": "notification-preview", "requestID": UUID().uuidString,
            "cwd": "/tmp/알림 검증 프로젝트", "hook_event_name": "PreToolUse", "tool_use_id": questionID,
            "tool_name": "AskUserQuestion", "tool_input": ["questions": [["question": "검증용 질문: 어느 작업부터 할까요?",
                "options": [["label": "미커밋 현황 훑기"], ["label": "PR 상태 점검"], ["label": "지정하는 일"]]]]]])
    }

    func resolve() {
        _ = engine.handleHook(["session_id": "notification-preview", "requestID": UUID().uuidString, "hook_event_name": "PostToolUse"])
    }

    func startWork(codex: Bool = false) {
        if codex {
            completionTurn = UUID().uuidString
            engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: "preview-0",
                questions: engine.snapshot.sessions.first(where: { $0.id == "preview-0" })?.questions ?? [],
                turn: CodexTurnState(threadID: "preview", turnID: completionTurn, status: "inProgress"))])
        } else {
            _ = engine.handleHook(["session_id": "notification-preview", "requestID": UUID().uuidString,
                "cwd": "/tmp/알림 검증 프로젝트", "hook_event_name": "UserPromptSubmit"])
        }
    }

    func finishWork(codex: Bool = false) {
        if codex {
            engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: "preview-0",
                questions: engine.snapshot.sessions.first(where: { $0.id == "preview-0" })?.questions ?? [],
                turn: CodexTurnState(threadID: "preview", turnID: completionTurn, status: "completed", completedAt: Date(),
                    summary: "검증용 Codex 최종 응답: 요청한 작업과 검증을 마쳤습니다."))])
        } else {
            _ = engine.handleHook(["session_id": "notification-preview", "requestID": UUID().uuidString,
                "hook_event_name": "Stop", "background_tasks": [], "session_crons": [],
                "last_assistant_message": "검증용 Claude 최종 응답: 작업과 검증을 마쳤습니다."])
        }
    }

    func brieflyFinishWork() {
        startWork(); finishWork()
        Task { try? await Task.sleep(nanoseconds: 500_000_000); startWork() }
    }

    func inspectNotifications() {
        Task {
            let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
            let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
            let completions = delivered.filter { $0.request.content.categoryIdentifier == "WORK_COMPLETED" }
            notificationResult = "전달 \(delivered.count)개 · 완료 \(completions.count)개 · 예약 \(pending.count)개 · 알림 클릭 \(opened)회"
                + completions.map { "\n\($0.request.content.title) · \($0.request.content.subtitle)" }.joined()
        }
    }
}

@main struct HighlightPreviewApp: App {
    @StateObject private var fixture = AuditPreviewFixture()
    var body: some Scene {
        Window("AutoApprove 강조 미리보기", id: "preview") {
            HighlightPreview(fixture: fixture).frame(minWidth: 520, minHeight: 500)
        }.defaultSize(width: 1040, height: 700)
        Window("승인 내역 · 검증용 데이터", id: "history") {
            AuditHistoryWindow(engine: fixture.engine)
        }.defaultSize(width: 1040, height: 700).windowResizability(.contentMinSize)
        Window("세션 관리 · 검증용 데이터", id: "queue") {
            SessionWindow(engine: fixture.engine, notifications: fixture.notifications, openTerminal: fixture.openTerminal)
                .navigationTitle(fixture.terminalOpenResult)
        }.defaultSize(width: 1040, height: 700).windowResizability(.contentMinSize)
    }
}

private struct HighlightPreview: View {
    @ObservedObject var fixture: AuditPreviewFixture
    @Environment(\.openWindow) private var openWindow
    @State private var text = ""
    @State private var compact = false
    @State private var alternate = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("터미널 위치 강조 미리보기").font(.title2.bold())
            Text("이 창은 실제 터미널이 아닌 검증용 창입니다.").foregroundStyle(.secondary)
            TextField("강조 표시 중 입력 확인", text: $text).textFieldStyle(.roundedBorder)
            HStack {
                Button("창 강조") { highlight(longName: false) }.keyboardShortcut("l")
                Button("긴 이름 강조") { highlight(longName: true) }
                Button("작은 창 / 기본 창") {
                    guard let window = NSApp.keyWindow else { return }
                    compact.toggle()
                    window.setContentSize(compact ? NSSize(width: 520, height: 500) : NSSize(width: 1040, height: 672))
                }
                Button("테마 전환") {
                    alternate.toggle()
                    NSApp.appearance = NSAppearance(named: alternate ? .darkAqua : .aqua)
                }
            }
            Divider()
            Button("승인 내역 미리보기") { openWindow(id: "history") }
            Button("질문 대기열 · 터미널 제목 · 접기 펼치기") { openWindow(id: "queue") }
            HStack {
                Button("삼지선다 알림 보내기") { fixture.question(new: true) }
                Button("같은 질문 다시 관찰") { fixture.question(new: false) }
                Button("질문 해결") { fixture.resolve() }
            }
            HStack {
                Button("Claude 작업 시작") { fixture.startWork() }
                Button("Claude 최종 완료 / 반복") { fixture.finishWork() }
                Button("완료 직후 작업 재개") { fixture.brieflyFinishWork() }
            }
            HStack {
                Button("Codex 작업 시작") { fixture.startWork(codex: true) }
                Button("Codex 최종 완료 / 반복") { fixture.finishWork(codex: true) }
            }
            Button("알림 상태 확인") { fixture.inspectNotifications() }
            Text(fixture.notificationResult).font(.caption)
            Text("알림 클릭 \(fixture.opened)회").font(.caption)
            Button("표시 패널 확인") {
                highlight(longName: true)
                let windows = NSApp.windows.filter { $0.isVisible && !$0.title.hasPrefix("선택한 터미널") }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    windows.forEach { $0.orderOut(nil) }
                    try? await Task.sleep(nanoseconds: 1_800_000_000)
                    windows.forEach { $0.orderFrontRegardless() }
                }
            }
            Text("Claude Code · /dev/ttys-test").font(.system(.body, design: .monospaced))
            Spacer()
        }.padding(24)
    }
    private func highlight(longName: Bool) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.identifier?.rawValue == "preview" }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        TerminalHighlighter.shared.show(frame: window.frame,
            project: longName ? "아주 긴 프로젝트 이름 — 여러 작업을 동시에 수행하는 터미널 위치 확인" : "autoapprove",
            detail: "Claude Code · /dev/ttys-test", ownerBundleID: Bundle.main.bundleIdentifier!)
    }
}
