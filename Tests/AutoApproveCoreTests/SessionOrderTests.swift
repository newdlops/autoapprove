import Foundation
import AutoApproveCore

@MainActor private final class SessionOrderFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-session-order-" + UUID().uuidString)
    let engine: ApprovalEngine
    let sessions: [AgentSession]
    var paths: AppPaths { AppPaths(directory: root) }
    var ids: [String] { sessions.map(\.id) }
    var order: [String] { engine.snapshot.sessions.filter { $0.phase != .ended }.map(\.id) }
    init() throws {
        engine = try ApprovalEngine(paths: AppPaths(directory: root))
        sessions = (0..<5).map { index in
            var session = AgentSession(id: "process:\(index):order-fixture", agent: .claude, pid: Int32(1200 + index), started: "order-fixture", tty: "/dev/order-\(index)", cwd: "/tmp/item-\(index == 1 ? 0 : index)", terminal: .terminal)
            session.channel = .hook
            session.gitBranch = .init(kind: .branch, name: "branch-\(index)")
            return session
        }
        engine.updateDiscovery(sessions, records: [])
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

extension ApprovalTests {
    func testSessionOrderPersistsAcrossDiscoveryAndRestart() throws {
        let fixture = try SessionOrderFixture(), engine = fixture.engine, ids = fixture.ids
        try engine.setAutomatic(ids[0], enabled: true)
        let metadata = Dictionary(uniqueKeysWithValues: engine.snapshot.sessions.map { ($0.id, $0) })
        try engine.moveSessions(fromOffsets: [2], toOffset: 0, visibleIDs: ids)
        try expectEqual(fixture.order, [ids[2], ids[0], ids[1], ids[3], ids[4]])
        try expectEqual(Dictionary(uniqueKeysWithValues: engine.snapshot.sessions.map { ($0.id, $0) }), metadata, "Moving must not change approval, branch or terminal identity")
        engine.updateDiscovery(fixture.sessions.reversed(), records: [])
        try expectEqual(fixture.order.first, ids[2], "Discovery cannot restore alphabetical order")
        try engine.moveSessions(fromOffsets: [0], toOffset: 5, visibleIDs: fixture.order)
        let expected = [ids[0], ids[1], ids[3], ids[4], ids[2]]
        try expectEqual(fixture.order, expected, "Moving downward uses the original destination offset")
        let restored = try ApprovalEngine(paths: fixture.paths)
        // Startup can discover only some of the saved sessions at first.
        restored.updateDiscovery([fixture.sessions[2]], records: [])
        restored.updateDiscovery(fixture.sessions.reversed(), records: [], directories: [ids[0]: "/tmp/zz-renamed"])
        try expectEqual(restored.snapshot.sessions.map(\.id), expected)
        var newcomer = fixture.sessions[0]; newcomer.id = "process:new:order-fixture"; newcomer.cwd = "/tmp/aaa-new"
        restored.updateDiscovery(fixture.sessions + [newcomer], records: [])
        try expectEqual(restored.snapshot.sessions.last?.id, newcomer.id, "New sessions follow the saved order")
        restored.updateDiscovery(fixture.sessions.filter { $0.id != ids[1] } + [newcomer], records: [])
        try expectEqual(restored.snapshot.sessions.filter { $0.phase != .ended }.map(\.id), expected.filter { $0 != ids[1] } + [newcomer.id])
        try expect(restored.snapshot.sessions.first { $0.id == ids[0] }?.automatic == true)
    }

    func testFilteredAndMultipleSessionMoves() throws {
        let fixture = try SessionOrderFixture(), engine = fixture.engine, ids = fixture.ids
        try engine.moveSessions(fromOffsets: [2], toOffset: 0, visibleIDs: [ids[0], ids[2], ids[4]])
        try expectEqual(fixture.order, [ids[4], ids[1], ids[0], ids[3], ids[2]], "Hidden rows keep their exact slots")
        try engine.moveSessions(fromOffsets: [0, 2], toOffset: 5, visibleIDs: fixture.order)
        try expectEqual(fixture.order, [ids[1], ids[3], ids[2], ids[4], ids[0]], "Moving multiple rows keeps their relative order")
        let before = fixture.order
        try engine.moveSessions(fromOffsets: [1], toOffset: 2, visibleIDs: before)
        try engine.moveSessions(fromOffsets: [], toOffset: 0, visibleIDs: before)
        try expectEqual(fixture.order, before, "Dropping at the same position is a no-op")
    }

    func testSessionMoveRejectsStaleAndInvalidRows() throws {
        let fixture = try SessionOrderFixture(), engine = fixture.engine, ids = fixture.ids
        try expectThrows(try engine.moveSessions(fromOffsets: [5], toOffset: 0, visibleIDs: ids))
        try expectThrows(try engine.moveSessions(fromOffsets: [0], toOffset: -1, visibleIDs: ids))
        try expectThrows(try engine.moveSessions(fromOffsets: [0], toOffset: 6, visibleIDs: ids))
        try expectThrows(try engine.moveSessions(fromOffsets: [0], toOffset: 2, visibleIDs: [ids[0], ids[0]]))
        try expectThrows(try engine.moveSessions(fromOffsets: [0], toOffset: 2, visibleIDs: [ids[1], ids[0]]))
        try expectEqual(fixture.order, ids)
        engine.updateDiscovery(Array(fixture.sessions.dropLast()), records: [])
        try expectThrows(try engine.moveSessions(fromOffsets: [4], toOffset: 0, visibleIDs: ids))
        try expectEqual(fixture.order, Array(ids.dropLast()), "A stale drag cannot revive an exited session")
    }

    func testSessionOrderSaveFailureAndDamagedPreference() throws {
        let fixture = try SessionOrderFixture(), ids = fixture.ids
        let store = try AuditStore(path: fixture.paths.database)
        try store.set("sessionOrder", "not-json")
        let defaultEngine = try ApprovalEngine(paths: fixture.paths)
        defaultEngine.updateDiscovery(fixture.sessions, records: [])
        try expectEqual(defaultEngine.snapshot.sessions.map(\.id), ids)
        let saved = [ids[3], ids[3], "old-ended-session", ids[0]]
        try store.set("sessionOrder", String(decoding: try JSONEncoder().encode(saved), as: UTF8.self))
        let restored = try ApprovalEngine(paths: fixture.paths)
        restored.updateDiscovery(fixture.sessions, records: [])
        try expectEqual(restored.snapshot.sessions.map(\.id), [ids[3], ids[0], ids[1], ids[2], ids[4]], "Duplicate and stale saved IDs must not break discovery")
        let result = try CommandRunner.run("/usr/bin/sqlite3", [fixture.paths.database, "DROP TABLE settings;"])
        try expectEqual(result.status, 0)
        try expectThrows(try fixture.engine.moveSessions(fromOffsets: [4], toOffset: 0, visibleIDs: ids))
        try expectEqual(fixture.order, ids, "A failed save must leave the visible order unchanged")
    }
}
