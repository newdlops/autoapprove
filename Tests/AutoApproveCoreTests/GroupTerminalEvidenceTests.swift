import Foundation
import AutoApproveCore

private final class GroupScreenReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [@Sendable () throws -> String] = []
    private var targets: [String] = []

    func prepare(_ steps: [@Sendable () throws -> String]) {
        lock.withLock { self.steps = steps; targets = [] }
    }

    var readTargets: [String] { lock.withLock { targets } }

    func read(_ requested: [ScreenTarget]) throws -> TerminalSnapshot {
        guard requested.count == 1, let tty = requested.first?.tty else { throw AppError.message("Expected one terminal") }
        let step = try lock.withLock {
            targets.append(tty)
            guard !steps.isEmpty else { throw AppError.message("Unexpected read") }
            return steps.removeFirst()
        }
        return TerminalSnapshot(screens: [TerminalScreen(tty: tty, contents: try step())])
    }
}

extension ApprovalTests {
    @MainActor func testGroupTerminalReadRecoversWithoutChangingTarget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("""
        141801 1 fixture801 141801 141801 Wed Oct 28 12:00:00 2026 /fixture/claude
        141802 1 fixture802 141802 141802 Wed Oct 28 12:00:00 2026 /fixture/claude
        """)
        let sessions = records.map { AgentSession(id: $0.key, agent: .claude, pid: $0.pid, started: $0.started,
                                                  tty: "/dev/" + $0.tty, cwd: "/fixture", terminal: .terminal) }
        let ids = Dictionary(uniqueKeysWithValues: records.map { ($0.key, UUID().uuidString) })
        let reader = GroupScreenReadProbe()
        let adapter = ScreenHostAdapter(screens: { targets in
            TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: "old monitoring output") })
        }, approve: { _,_,_ in fatalError("Read sent an approval") }, reveal: { _ in fatalError("Read selected a window") },
           input: { _,_,_,_ in fatalError("Read sent input") }, validationScreens: { try reader.read($0) })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), claudeRegistryReader: { rows in
            rows.map { .init(processID: $0.key, kind: "interactive", sessionID: ids[$0.key], status: "idle") }
        }, processReader: { records }, screenAdapters: [.terminal: adapter], isolateByDefault: true)
        defer { engine.stop() }
        engine.updateDiscovery(sessions, records: records)
        await engine.connectScreenHost(.terminal)
        let live = try await engine.sessionGroupSessions()
        let members = try sessions.map { session in
            guard let row = live.first(where: { $0.id == session.id }) else { throw AppError.message("Missing fixture member") }
            return row.member
        }
        let group = SessionGroup(name: "fixture", members: members, leaderMemberID: members[0].id)
        let store = SessionGroupStore(directory: directory)
        try store.save([group])
        func read() async throws -> JSONObject {
            try await engine.mcpAction(["owner": UUID().uuidString, "tool": "get_group_member_terminal", "sessionID": sessions[0].id,
                                        "groupID": group.id.uuidString, "memberID": members[1].id.uuidString])
        }
        let tty = sessions[1].tty
        reader.prepare([{ throw AutomationIPC.Failure.open }, { "fresh after cooldown" }])
        try expectEqual(try await read()["screen"] as? String, "fresh after cooldown")
        try expectEqual(reader.readTargets, [tty, tty])
        reader.prepare([{ throw AutomationIPC.Failure.busy }, { throw AutomationIPC.Failure.timeout }])
        do { _ = try await read(); throw AppError.message("Timeout returned a screen") }
        catch let error as RemoteHTTPError {
            try expectEqual(error.status, 503)
            try expect(error.localizedDescription.contains("get_group_member_terminal"))
            try expectEqual(error.diagnostics?["retryable"], "true")
        }
        try expectEqual(reader.readTargets, [tty, tty])
        reader.prepare([{ throw AutomationIPC.Failure.invalidated }])
        do { _ = try await read(); throw AppError.message("Invalidated observation succeeded") }
        catch AutomationIPC.Failure.invalidated {}
        try expectEqual(reader.readTargets, [tty])
        reader.prepare([{ throw TerminalAdapterError.permissionDenied }])
        do { _ = try await read(); throw AppError.message("Permission denial returned a screen") }
        catch TerminalAdapterError.permissionDenied {}
        try expectEqual(reader.readTargets, [tty])
        var changed = group
        changed.members[1].conversationID = UUID().uuidString
        let replacement = changed
        reader.prepare([{ try SessionGroupStore(directory: directory).save([replacement]); throw AutomationIPC.Failure.timeout }])
        do { _ = try await read(); throw AppError.message("Read retried into a replacement conversation") }
        catch let error as RemoteHTTPError { try expectEqual(error.status, 409) }
        try expectEqual(reader.readTargets, [tty])
        try store.save([group])
        reader.prepare([{ try SessionGroupStore(directory: directory).save([]); throw AutomationIPC.Failure.timeout }])
        do { _ = try await read(); throw AppError.message("Read retried after membership was revoked") }
        catch let error as RemoteHTTPError { try expectEqual(error.status, 403) }
        try expectEqual(reader.readTargets, [tty])
    }
}
