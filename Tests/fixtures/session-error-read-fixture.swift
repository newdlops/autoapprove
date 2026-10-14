import Foundation
import AutoApproveCore

private final class FixtureFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "합성 원본 터미널\n› Ask Codex to do anything\n\n? for shortcuts"
    func read() -> String { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ text: String) { lock.lock(); defer { lock.unlock() }; value = text }
}

@main struct SessionErrorReadFixture {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let paths = AppPaths(directory: root.appendingPathComponent("profile"))
        try paths.prepare()
        let store = try AuditStore(path: paths.database)
        if store.value("fixture-seeded") == nil {
            var ended = [AgentSession]()
            for index in 0..<3 {
                var session = AgentSession(id: "process:\(41 + index):fixture", agent: .codex, pid: Int32(41 + index), started: "fixture", tty: "/dev/fixture\(index)", cwd: "/fixture/error-check", terminal: .terminal)
                session.phase = .ended; session.terminalTitle = "합성 종료 오류 \(index + 1)"
                session.interruption = SessionInterruption(id: "fixture-error-\(index)", kind: .transport,
                    detail: "stream disconnected before completion: network error · " + String(repeating: "긴 오류 설명/재연결 경로/", count: 40))
                var inbox = SessionInbox()
                let candidate = SessionInbox.Candidate(key: SessionNotice.key(.question, "interruption:fixture-error-\(index)"), kind: .question, summary: "합성 오류", isInterruption: true)
                inbox.update([candidate], at: Date().addingTimeInterval(-2)); inbox.update([candidate])
                // A receipt from an older release must also clean up on upgrade.
                if index == 2 { inbox.markRead() }
                session.notices = inbox.entries
                try store.set("inbox:\(session.id)", String(decoding: JSONEncoder().encode(inbox), as: UTF8.self))
                ended.append(session)
            }
            try store.set("interruptedSessionNotices", String(decoding: JSONEncoder().encode(ended), as: UTF8.self))
            try store.set("fixture-seeded", "true")
            try store.append(AuditEvent(sessionID: ended[0].id, summary: "보존할 합성 승인 내역", outcome: "전달 완료", source: "격리 검사"))
        }
        let records = ProcessDiscovery.parse("45 1 ttys999 45 45 Wed Oct 14 09:00:00 2026 /fixture/codex")
        let record = records[0]
        let frame = FixtureFrame()
        let adapter = ScreenHostAdapter(screens: { targets in
            TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: frame.read()) })
        }, approve: { _, _, _ in .missingTarget }, reveal: { _ in nil })
        let engine = try ApprovalEngine(paths: paths, claudeRegistryReader: { _ in [] }, processReader: { records }, screenAdapters: [.terminal: adapter])
        var live = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/ttys999", cwd: "/fixture/live-work", terminal: .terminal)
        live.phase = .idle; live.terminalTitle = "합성 실행 중 세션"
        engine.updateDiscovery([live], records: records)
        await engine.connectScreenHost(.terminal)
        try engine.start(poll: false)
        try engine.setWebEnabled(true, port: 0, bonjourEnabled: false, discoveryAddresses: { [] })
        while !engine.webStatus.ready { try await Task.sleep(for: .milliseconds(20)) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(["port": String(engine.webStatus.port!), "live": live.id]).write(to: root.appendingPathComponent("ready.json"))
        while !Task.isCancelled {
            let next = root.appendingPathComponent("next-error")
            if FileManager.default.fileExists(atPath: next.path) {
                let label = try String(contentsOf: next, encoding: .utf8)
                try FileManager.default.removeItem(at: next)
                // A genuine new episode follows observed work, rather than a
                // redraw of the same failed turn with different whitespace.
                let busy = "• Working (1s • esc to interrupt)"
                frame.set(busy)
                engine.receiveScreen(sessionID: live.id, raw: busy, generation: "fixture:work:" + label)
                let raw = "■ stream disconnected before completion: network error " + label + "\n\n› Ask Codex to do anything\n\n? for shortcuts"
                frame.set(raw)
                engine.receiveScreen(sessionID: live.id, raw: raw, generation: "fixture:" + label)
            }
            engine.refreshNotices()
            try await Task.sleep(for: .milliseconds(100))
        }
        engine.stop()
    }
}
