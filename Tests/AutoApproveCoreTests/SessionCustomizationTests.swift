import Foundation
import AutoApproveCore

@MainActor private final class CustomizationFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-customization-" + UUID().uuidString)
    let engine: ApprovalEngine
    let sessions: [AgentSession]
    var paths: AppPaths { AppPaths(directory: root) }

    init() throws {
        engine = try ApprovalEngine(paths: AppPaths(directory: root), terminalReader: { ttys in
            TerminalSnapshot(screens: ttys.map { TerminalScreen(tty: $0, contents: "Working", title: "도구가 갱신한 제목") })
        })
        sessions = (0..<2).map { index in
            var session = AgentSession(id: "process:\(1400 + index):customization", agent: .claude,
                pid: Int32(1400 + index), started: "customization", tty: "/dev/customization-\(index)", cwd: "/tmp/shared-project", terminal: .terminal)
            session.channel = .hook; session.terminalTitle = "원래 제목 \(index)"
            return session
        }
        engine.updateDiscovery(sessions, records: [])
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

extension ApprovalTests {
    func testCustomizationPersistsAndStaysInItsSession() async throws {
        let fixture = try CustomizationFixture(), engine = fixture.engine, first = fixture.sessions[0], second = fixture.sessions[1]
        try engine.setAutomatic(first.id, enabled: true)
        let label = SessionCustomization(title: "결제 API", note: "내일 확인\n중복 결제 회귀 검사", color: .blue)
        try engine.setCustomization(first.id, value: label)
        try expectEqual(engine.snapshot.sessions.first { $0.id == first.id }?.customization, label)
        try expect(engine.snapshot.sessions.first { $0.id == second.id }?.customization == nil, "The same project cannot share labels")
        engine.updateDiscovery(fixture.sessions.reversed(), records: [], directories: [first.id: "/tmp/moved-project"])
        await engine.connectTerminal()
        let changed = engine.snapshot.sessions.first { $0.id == first.id }!
        try expectEqual(changed.displayedTerminalTitle, "결제 API")
        try expectEqual(changed.terminalTitle, "도구가 갱신한 제목")
        try expectEqual(changed.customization, label)
        try expect(changed.automatic, "Editing labels must not change automation")
        try expectEqual(changed.pid, first.pid); try expectEqual(changed.tty, first.tty)
        let restored = try ApprovalEngine(paths: fixture.paths)
        restored.updateDiscovery([second], records: [])
        restored.updateDiscovery(fixture.sessions, records: [])
        try expectEqual(restored.snapshot.sessions.first { $0.id == first.id }?.customization, label)
        var reused = first; reused.id = "process:\(first.pid):new-start"; reused.started = "new-start"
        restored.updateDiscovery([reused, second], records: [])
        try expect(restored.snapshot.sessions.first { $0.id == reused.id }?.customization == nil, "PID or TTY reuse cannot inherit another execution's notes")
    }

    func testCustomizationResetAndSearch() throws {
        let fixture = try CustomizationFixture(), id = fixture.sessions[0].id
        try fixture.engine.setCustomization(id, value: SessionCustomization(title: "  Payment API  ", note: "\n메모로 찾기\n줄바꿈 유지\n", color: .green))
        let edited = fixture.engine.snapshot.sessions.first { $0.id == id }!
        try expectEqual(edited.customization?.title, "Payment API")
        try expectEqual(edited.customization?.note, "메모로 찾기\n줄바꿈 유지")
        for query in ["payment", "메모로 찾기", "원래 제목 0", "shared-project", "/dev/customization-0", "1400", "Claude"] {
            try expect(edited.matchesSearch(query), "Search must retain original fields and include names and notes: \(query)")
        }
        try expect(!edited.matchesSearch("다른 세션만의 메모"))
        try fixture.engine.setCustomization(id, value: SessionCustomization())
        try expect(fixture.engine.snapshot.sessions.first { $0.id == id }?.customization == nil)
        let restored = try ApprovalEngine(paths: fixture.paths)
        restored.updateDiscovery(fixture.sessions, records: [])
        let reset = restored.snapshot.sessions.first { $0.id == id }!
        try expectEqual(reset.displayedTerminalTitle, "원래 제목 0")
        try expect(!reset.matchesSearch("Payment API"))
    }

    func testCustomizationValidationAndCompatibility() throws {
        let valid = SessionCustomization(title: String(repeating: "👩‍💻", count: 80), note: String(repeating: "한", count: 2_000), color: .yellow)
        try expectEqual(try valid.normalized(), valid)
        try expectThrows(try SessionCustomization(title: String(repeating: "가", count: 81)).normalized())
        try expectThrows(try SessionCustomization(title: "첫째\n둘째").normalized())
        try expectThrows(try SessionCustomization(note: String(repeating: "가", count: 2_001)).normalized())
        let unknown = try JSONDecoder().decode(SessionCustomization.self, from: Data(#"{"title":"기록","note":"유지","color":"future-color"}"#.utf8))
        try expectEqual(unknown.title, "기록"); try expectEqual(unknown.note, "유지"); try expect(unknown.color == nil)
        let fixture = try CustomizationFixture(), store = try AuditStore(path: fixture.paths.database)
        try store.set("customization:\(fixture.sessions[0].id)", "broken json")
        let restored = try ApprovalEngine(paths: fixture.paths)
        restored.updateDiscovery(fixture.sessions, records: [])
        try expect(restored.snapshot.sessions.allSatisfy { $0.customization == nil })
        let legacy = try JSONEncoder().encode(fixture.sessions[0])
        try expect(!String(decoding: legacy, as: UTF8.self).contains("customization" + "\"" + ":"), "Legacy-compatible snapshots omit nil metadata")
        try expectEqual(try JSONDecoder().decode(AgentSession.self, from: legacy).displayedTerminalTitle, "원래 제목 0")
    }

    func testCustomizationFailureDoesNotPublishOrReviveSessions() throws {
        let fixture = try CustomizationFixture(), id = fixture.sessions[0].id
        try fixture.engine.setCustomization(id, value: SessionCustomization(title: "저장된 이름", color: .purple))
        let before = fixture.engine.snapshot.sessions
        try expectThrows(try fixture.engine.setCustomization("missing", value: SessionCustomization(title: "없음")))
        try expectThrows(try fixture.engine.setCustomization(id, value: SessionCustomization(title: String(repeating: "x", count: 81))))
        try expectEqual(fixture.engine.snapshot.sessions, before)
        let dropped = try CommandRunner.run("/usr/bin/sqlite3", [fixture.paths.database, "DROP TABLE settings;"])
        try expectEqual(dropped.status, 0)
        try expectThrows(try fixture.engine.setCustomization(id, value: SessionCustomization(title: "실패한 이름")))
        try expectEqual(fixture.engine.snapshot.sessions, before, "A failed save cannot look successful")
        fixture.engine.updateDiscovery([], records: [])
        try expectThrows(try fixture.engine.setCustomization(id, value: SessionCustomization(title: "종료됨")))
        try expect(fixture.engine.snapshot.sessions.allSatisfy { $0.phase == .ended })
    }
}
