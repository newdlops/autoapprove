// Native UI verification with production views and an isolated engine.
// Notifications, discovery, terminal navigation and message delivery stay local to this fixture.
import AppKit
import Combine
import SwiftUI
import UserNotifications
import AutoApproveCore

@MainActor final class QuestionNotifications: ObservableObject {
    @Published var authorization: UNAuthorizationStatus = .authorized
    @Published var busy = false
    @Published var error: String?
    var status: String { "검증용 알림 대역" }
    func requestAuthorization() async {}
    func openSettings() {}
    func retryDelivery() async {}
}

@MainActor final class AutomaticQuestionPreview: ObservableObject {
    let engine: ApprovalEngine
    let notifications = QuestionNotifications()
    private let sessionID = "automatic-question-preview"
    private var subscription: AnyCancellable?

    init() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("autoapprove-question-ui-" + UUID().uuidString)
        engine = try! ApprovalEngine(paths: AppPaths(directory: directory), questionTransport: CodexReplyTransport(prepare: { _, question in
            if question.title.contains("전송 오류") { throw AppError.message("검증용: 질문을 다시 확인하지 못했습니다. 연결을 확인한 뒤 다시 보내주세요.") }
            return CodexReplyTarget(executable: "/unused-preview", home: "/unused-preview", threadID: question.threadID)
        }, send: { _, _ in
            try await Task.sleep(nanoseconds: 700_000_000)
            return UUID().uuidString
        }))
        var session = AgentSession(id: sessionID, agent: .codex, pid: 1200, started: "preview",
            tty: "/dev/ttys-preview", cwd: "/tmp/응답 자동화 검증", terminal: .vscode)
        session.phase = .working; session.channel = .vscodeScreen
        session.bridgeID = "preview"; session.terminalID = sessionID
        session.terminalTitle = "5초 자동 응답 · 입력과 취소 검증"
        session.gitBranch = .init(kind: .branch, name: "feature/automatic-question-reply")
        engine.updateDiscovery([session], records: [])
        try! engine.setAutomatic(sessionID, enabled: true)
        let statePath = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("automatic-question-state.json")
        subscription = engine.$snapshot.sink { snapshot in
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: statePath, options: .atomic) }
        }
        show("paused")
    }

    func show(_ scenario: String) {
        try! engine.setPaused(true)
        let thread = UUID().uuidString
        let title = "검증용: 변경 사항을 확인한 뒤 다음 작업을 진행할까요?"
        var questions = [QueuedQuestion(id: "\(thread):0", threadID: thread, title: title, options: ["Yes (Recommended)", "No"])]
        if scenario == "long" {
            questions[0].title = "검증용: 여러 프로젝트에 걸친 변경 사항과 아직 완료하지 못한 확인 항목을 함께 검토한 뒤, 현재 선택한 터미널에서 다음 작업을 계속 진행할까요?"
            questions[0].options = ["Yes — 선택한 터미널의 이번 작업을 진행하고, 변경 내용과 확인 결과를 모두 정리해주세요.", "No — 지금은 진행하지 않고 제가 직접 내용을 더 확인하겠습니다."]
        } else if scenario == "history" {
            questions[0].title = "검증용: 이전에 받은 질문을 진행할까요?"
            let duplicate = "검증용: 같은 문구의 질문을 진행할까요?"
            questions.append(QueuedQuestion(id: "\(thread):1", threadID: thread, title: duplicate, options: ["Yes", "No"]))
            questions.append(QueuedQuestion(id: "\(thread):2", threadID: thread, title: duplicate, options: ["Yes", "No"]))
            var later = QueuedQuestion(id: "\(thread):3", threadID: thread, title: "검증용: 이후 메시지가 있는 질문을 진행할까요?", options: ["Yes", "No"])
            later.hasLaterUserMessage = true
            questions.append(later)
        } else if scenario == "allow" {
            questions[0].options = ["Deny", "Always allow", "Allow once (Recommended)"]
        } else if scenario == "failure" {
            questions[0].title = "검증용 전송 오류: 작업을 진행할까요?"
        } else if scenario == "empty" {
            questions = []
        }
        if scenario != "history" {
            engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: sessionID, questions: [], threadID: thread)])
        }
        engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: sessionID, questions: questions, threadID: thread)])
        if scenario == "error" {
            engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: sessionID, error: "검증용: 질문 기록을 읽지 못했습니다. 연결 복구 후 다시 확인합니다.", threadID: thread)])
        }
        if !["paused", "long"].contains(scenario) { try! engine.setPaused(false) }
    }

    func resize(compact: Bool) {
        guard let window = NSApp.keyWindow else { return }
        window.setFrame(NSRect(origin: window.frame.origin, size: compact ? NSSize(width: 784, height: 612) : NSSize(width: 1040, height: 700)), display: true)
    }

    func resizeHelp(compact: Bool) {
        guard let window = NSApp.keyWindow, window.identifier?.rawValue == "help" else { return }
        window.setContentSize(compact ? NSSize(width: 520, height: 540) : NSSize(width: 620, height: 660))
    }
}

@main struct AutomaticQuestionPreviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var fixture = AutomaticQuestionPreview()
    var body: some Scene {
        Window("응답 자동화 · 검증용 데이터", id: "main") {
            SessionWindow(engine: fixture.engine, notifications: fixture.notifications, openTerminal: { _, _ in })
        }
        .defaultSize(width: 1040, height: 648)
        .windowResizability(.contentMinSize)
        .commands {
            AppCommands(connectionsAvailable: true)
            CommandMenu("검증") {
                Button("새 질문 · 5초 후 Yes") { fixture.show("automatic") }.keyboardShortcut("n")
                Button("새 질문 · 5초 후 Allow") { fixture.show("allow") }.keyboardShortcut("a", modifiers: [.command, .shift])
                Button("새 질문 · 일시정지") { fixture.show("paused") }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button("긴 질문과 선택지") { fixture.show("long") }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("과거 · 중복 · 후속 메시지") { fixture.show("history") }.keyboardShortcut("h", modifiers: [.command, .shift])
                Button("연결 오류") { fixture.show("error") }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("전송 오류") { fixture.show("failure") }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("질문 없음") { fixture.show("empty") }.keyboardShortcut("0")
                Divider()
                Button("기본 창 1040×700") { fixture.resize(compact: false) }.keyboardShortcut("1")
                Button("최소 창 784×612") { fixture.resize(compact: true) }.keyboardShortcut("2")
                Button("도움말 기본 620×660") { fixture.resizeHelp(compact: false) }.keyboardShortcut("3")
                Button("도움말 최소 520×540") { fixture.resizeHelp(compact: true) }.keyboardShortcut("4")
            }
        }
        Window("승인 내역", id: "history") {
            AuditHistoryWindow(engine: fixture.engine)
        }.defaultSize(width: 1040, height: 700).windowResizability(.contentMinSize).commandsRemoved()
        Window("연결 설정", id: "settings") {
            ConnectionSettings(engine: fixture.engine, notifications: fixture.notifications)
        }.windowResizability(.contentSize).commandsRemoved()
        Window("AutoApprove 도움말", id: "help") {
            HelpWindow()
        }.defaultSize(width: 620, height: 660).windowResizability(.contentMinSize).commandsRemoved()
    }
}
