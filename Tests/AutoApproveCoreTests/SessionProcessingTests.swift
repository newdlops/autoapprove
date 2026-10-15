import Foundation
import Combine
import AutoApproveCore

extension ApprovalTests {
    func testProcessClassificationPreservesPathAndExecutableIdentity() throws {
        func legacy(_ path: String) -> AgentKind? {
            let name = URL(fileURLWithPath: path).lastPathComponent
            if path.contains("/Applications/ChatGPT.app/") { return nil }
            if name == "codex" { return .codex }
            if name == "claude" || (path.contains("/claude/versions/") && name.first?.isNumber == true) { return .claude }
            return nil
        }
        let prefixes = ["", "/", "./", "../", "//", "/tmp/한글 경로/", "~/", "/tmp/../",
            "/Applications/ChatGPT.app/Contents/MacOS/", "/Applications/ChatGPT.app/../",
            "/Users/test/.local/share/claude/versions/", "/tmp/claude/versions/../"]
        let names = ["", ".", "..", "codex", "claude", "codex-code-mode-host", "claude bg-pty-host",
            "Codex", "worker", "2.1.0", "２.１", "½", "codex%2Fworker", "co\u{301}dex", "\u{301}codex"]
        let endings = ["", "/", "//", "/.", "/..", "/../codex", "/../claude", "/\u{301}"]
        var record = ProcessDiscovery.parse("910000 1 ttys500 910000 910000 Mon Sep 21 09:00:00 2026 /fixture/codex")[0]
        let identity = record.key
        for prefix in prefixes {
            for name in names {
                for ending in endings {
                    let path = prefix + name + ending
                    record.executable = path
                    try expectEqual(record.agent, legacy(path), "Classification changed for \(path.debugDescription)")
                    try expectEqual(record.key, identity, "Classification must not change process identity")
                }
            }
        }
        for (path, expected) in [("/fixture/codex", AgentKind.codex), ("claude", .claude), ("/fixture/claude/versions/2.1.0", .claude)] {
            record.executable = path; try expectEqual(record.agent, expected)
            record.executable = "/fixture/worker"; try expectNil(record.agent)
            record.executable = "/Applications/ChatGPT.app/Contents/MacOS/codex"; try expectNil(record.agent)
        }
    }

    func testSessionProjectionKeepsNestedOrphanCyclicAndEndedPolicies() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-projection-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(directory: directory); try paths.prepare()
        var sessions = (0..<8).map { index -> AgentSession in
            var session = AgentSession(id: "process:\(910000 + index):projection", agent: .claude,
                pid: Int32(910000 + index), started: "projection", tty: "/dev/fixture-projection-\(index)",
                cwd: "/fixture/Project \(8 - index)", terminal: .claudeBackground)
            session.channel = .hook
            session.setPhase(index == 2 ? .input : index == 1 ? .approval : .working, detail: "Synthetic projection")
            return session
        }
        let ids = sessions.map(\.id)
        let parents = [ids[1]: ids[0], ids[2]: ids[1], ids[3]: "process:missing:projection", ids[4]: ids[5], ids[5]: ids[4]]
        let store = try AuditStore(path: paths.database)
        try store.set("claudeParents", String(decoding: try JSONEncoder().encode(parents), as: UTF8.self))
        for id in ids { try store.set("automatic:" + id, "true") }
        let engine = try ApprovalEngine(paths: paths, claudeRegistryReader: { _ in [] })
        defer { engine.stop() }
        engine.updateDiscovery(sessions, records: [], claudeRegistrations: [])
        let main = engine.snapshot.sessions.first { $0.id == ids[0] }!
        try expectEqual(main.ownPhase, .working)
        try expectEqual(main.phase, .input)
        try expectEqual(main.backgroundChildren.map(\.id), [ids[2], ids[1]], "Grandchildren stay with the live root, in attention order")
        try expect(main.automatic && main.backgroundChildren.allSatisfy(\.automatic))
        for id in [ids[3], ids[4], ids[5]] {
            let orphan = engine.snapshot.sessions.first { $0.id == id }!
            try expect(!orphan.automatic && orphan.backgroundChildren.isEmpty)
            try expect(orphan.detail.contains("메인 세션이 종료"))
        }
        try expectEqual(engine.snapshot.sessions.map(\.id), [ids[7], ids[6], ids[5], ids[4], ids[3], ids[0]])
        engine.updateDiscovery(sessions, records: [], directories: [ids[0]: "/fixture/Project 0"], claudeRegistrations: [])
        try expectEqual(engine.snapshot.sessions.first?.id, ids[0], "Current cwd must immediately replace a previous sort key")
        try expectEqual(engine.snapshot.sessions.first?.project, "Project 0")
        var publications = 0
        let subscription = engine.$snapshot.dropFirst().sink { _ in publications += 1 }
        for _ in 0..<20 { engine.refreshNotices() }
        try expectEqual(publications, 0)
        subscription.cancel()
        sessions.removeFirst()
        engine.updateDiscovery(sessions, records: [], claudeRegistrations: [])
        let ended = engine.snapshot.sessions.first { $0.id == ids[0] }!
        try expectEqual(ended.phase, .ended)
        try expectEqual(engine.snapshot.sessions.last?.id, ids[0], "Ended rows follow live rows regardless of project name")
        try expect(ended.backgroundChildren.isEmpty && !ended.automatic)
        for id in [ids[1], ids[2]] {
            let orphan = engine.snapshot.sessions.first { $0.id == id }!
            try expect(!orphan.automatic && orphan.backgroundChildren.isEmpty, "Ended ancestry must immediately stop inheritance")
        }
        try expect(engine.snapshot.events.isEmpty)
    }
}
