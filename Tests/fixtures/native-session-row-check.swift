import Foundation
import SwiftUI
import AutoApproveCore

@main struct NativeSessionRowCheck {
    @MainActor static func main() throws {
        var original = AgentSession(id: "fixture", agent: .codex, pid: 900_000, started: "synthetic", tty: "/dev/ttys099",
            cwd: "/private/tmp/first/project", terminal: .terminal)
        original.phase = .idle; original.channel = .terminalScreen; original.automatic = true
        original.terminalTitle = "합성 원본"; original.lastActivity = Date(timeIntervalSince1970: 1_000)
        original.codexQuestionsObservedAt = Date(timeIntervalSince1970: 2_000)
        original.queuedQuestions = [.init(id: "question", threadID: "fixture", title: "합성 질문", options: ["개발", "시험"])]
        original.notices = [try JSONDecoder().decode(SessionNotice.self, from: Data(#"{"id":"notice","sourceKey":"fixture","kind":"question","summary":"합성 알림","date":0,"isRead":false}"#.utf8))]
        let saved = original, actions = SessionRowActions()
        func display(_ session: AgentSession, paused: Bool = false, selected: Bool = false, owner: SessionRowActions? = nil) -> SessionRowDisplay {
            SessionRowDisplay(session: session, paused: paused, selected: selected, actions: owner ?? actions)
        }
        let before = display(original)
        var timestamps = original
        timestamps.lastActivity = Date(timeIntervalSince1970: 5_000)
        timestamps.codexQuestionsObservedAt = Date(timeIntervalSince1970: 6_000)
        precondition(before == display(timestamps), "Unrendered timestamps must not rebuild a row")
        precondition(original == saved, "Preparing a display must not change the original model")
        precondition(before != display(original, paused: true))
        precondition(before != display(original, selected: true))
        precondition(before != display(original, owner: SessionRowActions()), "A replacement action owner must bind again")

        let mutations: [(String, (inout AgentSession) -> Void)] = [
            ("session identity", { $0.id = "replacement" }),
            ("process identity", { $0.pid += 1 }),
            ("process lifetime", { $0.started = "replacement start" }),
            ("TTY", { $0.tty = "/dev/ttys098" }),
            ("same project name, changed full path/help", { $0.cwd = "/private/tmp/second/project" }),
            ("source kind", { $0.agent = .claude }),
            ("terminal kind", { $0.terminal = .vscode }),
            ("host", { $0.hostName = "합성 편집기" }),
            ("terminal title", { $0.terminalTitle = "변경된 합성 원본" }),
            ("custom title, note and color", { $0.customization = .init(title: "표시 이름", note: "메모", color: .orange) }),
            ("branch", { $0.gitBranch = .init(kind: .branch, name: "fixture") }),
            ("phase", { $0.phase = .working }),
            ("ended/disabled", { $0.phase = .ended }),
            ("automatic", { $0.automatic = false }),
            ("capability/disconnection", { $0.channel = .none }),
            ("background monitoring", { $0.backgroundMonitoring = true }),
            ("background sessions", { value in var child = saved; child.id = "child"; value.backgroundSessions = [child] }),
            ("question", { $0.queuedQuestions?[0].title = "다른 합성 질문" }),
            ("sending answer", { $0.queuedQuestions?[0].reply = .init(phase: .sending, answer: "개발", message: "합성 전송") }),
            ("unread badge", { $0.notices?[0].isRead = true })
        ]
        for (name, mutate) in mutations {
            var changed = original; mutate(&changed)
            precondition(before != display(changed), "Display equality lost \(name)")
        }
        var delivered: [String] = []
        actions.update(automatic: { _ in delivered.append("obsolete") }, reveal: { delivered.append("obsolete") })
        let retainedDisplay = display(original)
        actions.update(automatic: { delivered.append("current-\($0)") }, reveal: { delivered.append("current-reveal") })
        precondition(retainedDisplay == display(timestamps), "The test must keep the old display")
        retainedDisplay.actions.setAutomatic(true); retainedDisplay.actions.setAutomatic(false); retainedDisplay.actions.reveal()
        precondition(delivered == ["current-true", "current-false", "current-reveal"], "A reused display invoked obsolete callbacks")
        let report: [String: Any] = ["passed": mutations.count + 6, "mutations": mutations.map(\.0),
            "timestampsIgnoredOnlyInDisplay": true, "originalUnchanged": true, "pausedSelectionOwnerChecked": true,
            "retainedDisplayInvokedLatestHandlers": true, "inputPosts": 0,
            "scope": "Actual production display and action types, synthetic identities only; no engine, original input or GUI interaction."]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
}
