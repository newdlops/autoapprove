import Foundation
import CSQLite
import AutoApproveCore

private final class GroupClearFixture: @unchecked Sendable {
    private let lock = NSLock()
    var records: [ProcessRecord]
    private var ids: [String]
    private var screens: [String]
    private var clears = [0, 0, 0]
    private var statusReads = [0, 0, 0]
    private var lost = false
    let loseFirstReply: Bool
    init(leader: AgentKind, loseFirstReply: Bool = false) {
        records = ProcessDiscovery.parse("""
        105001 1 fixture501 105001 105001 Wed Oct 28 12:00:00 2026 /fixture/\(leader.rawValue)
        105002 1 fixture502 105002 105002 Wed Oct 28 12:00:00 2026 /fixture/\(leader == .codex ? "claude" : "codex")
        105003 1 fixture503 105003 105003 Wed Oct 28 12:00:00 2026 /fixture/codex
        """)
        ids = records.map { _ in UUID().uuidString.lowercased() }
        screens = records.map { $0.agent == .codex ? ">_ OpenAI Codex (v0.169.0)\n /project\n› \n ? for shortcuts" : "Claude\n❯ \n ? for shortcuts" }
        self.loseFirstReply = loseFirstReply
    }
    func id(_ index: Int) -> String { lock.lock(); defer { lock.unlock() }; return ids[index] }
    func counts() -> [Int] { lock.lock(); defer { lock.unlock() }; return clears }
    func queries() -> Int { lock.lock(); defer { lock.unlock() }; return statusReads.reduce(0,+) }
    func draft(_ index: Int, enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        screens[index] = "fixture\n" + (records[index].agent == .codex ? "›" : "❯") + (enabled ? " unfinished draft" : " ") + "\n ? for shortcuts"
    }
    func resetIdentity(_ index: Int) { lock.lock(); defer { lock.unlock() }; ids[index] = UUID().uuidString.lowercased() }
    func screen(_ tty: String) -> String {
        lock.lock(); defer { lock.unlock() }; return screens[records.firstIndex { "/dev/" + $0.tty == tty }!]
    }
    func send(_ target: ScreenTarget, _ input: RemoteTerminalInput) throws -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }
        let index = records.firstIndex { "/dev/" + $0.tty == target.tty }!
        if input.bytes.contains("/clear") {
            clears[index] += 1; ids[index] = UUID().uuidString.lowercased()
            screens[index] = records[index].agent == .codex ? ">_ OpenAI Codex (v0.169.0)\n /project\n› \n ? for shortcuts" : "Claude\n❯ \n ? for shortcuts"
            if loseFirstReply && !lost { lost = true; throw RemoteHTTPError(409, "Owned lost reply", diagnostics: ["delivery": "unknown"]) }
        } else if input.bytes.contains("/status") {
            statusReads[index] += 1
            screens[index] += "\n>_ OpenAI Codex (v0.169.0)\nModel: fixture (reasoning high)\nDirectory: /project\nPermissions: workspace\nAgents.md: none\nSession: \(ids[index])\nstatus observation \(statusReads[index])\n› \n ? for shortcuts"
        }
        return .sent
    }
}

extension ApprovalTests {
    func testProfileExecutionSettingsRoundTripAndQuotedRestore() throws {
        let id = UUID().uuidString
        for tier in ["default", "priority", "ultrafast", "flex"] {
            let entry = TerminalProfileEntry(title: "owned", agent: "codex", cwd: "/tmp/owned path", conversationID: id,
                executionSettings: .init(model: "gpt-6.1-sol", reasoningEffort: "xhigh", serviceTier: tier))
            let encoded = try TerminalProfileStore.encode(.init(name: "execution", entries: [entry]))
            let restored = try TerminalProfileStore.decode(encoded)
            try expectEqual(restored.schema, 4); try expectEqual(restored.entries[0].executionSettings, entry.executionSettings)
            let command = try restored.entries[0].resumeCommand()
            try expect(command.contains("'--model' 'gpt-6.1-sol'"))
            try expect(command.contains("'model_reasoning_effort=\"xhigh\"'"))
            try expect(command.contains("'service_tier=\"\(tier)\"'"))
        }
        var claude = TerminalProfileEntry(title: "Claude", agent: "claude", cwd: "/tmp", conversationID: id, executionSettings: .init(model: "claude-opus-5-5", reasoningEffort: "max"))
        try expect(try claude.resumeCommand().contains("'--effort' 'max'"))
        claude.executionSettings?.serviceTier = "ultrafast"; try expectThrows(try claude.validated())
        for model in ["--dangerously-skip-permissions", "bad model", "x;touch", "x\nrun"] {
            claude.executionSettings = .init(model: model); try expectThrows(try claude.resumeCommand())
        }
        var legacy = TerminalSessionProfile(name: "legacy", entries: [.init(title: "old", agent: "codex", cwd: "/tmp", conversationID: id)])
        for schema in 1...3 { legacy.schema = schema; try expectNil(try TerminalProfileStore.decode(TerminalProfileStore.encode(legacy)).entries[0].executionSettings) }
    }

    func testProfileSettingsReadOwnedCheckpointWithoutGlobalGuessing() throws {
        let root = URL(fileURLWithPath: "/private/tmp/aa-profile-settings-" + UUID().uuidString)
        let directory = root.appendingPathComponent("sessions/2026/11/18", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased(), foreign = UUID().uuidString.lowercased()
        let log = directory.appendingPathComponent("rollout-owned.jsonl")
        var db: OpaquePointer?; try expectEqual(sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        try expectEqual(sqlite3_exec(db, "CREATE TABLE threads(id TEXT PRIMARY KEY,model TEXT,reasoning_effort TEXT,updated_at INTEGER,rollout_path TEXT); INSERT INTO threads VALUES('\(id)','old-model','low',1794900000,'\(log.path)')", nil, nil, nil), SQLITE_OK)
        let header: JSONObject = ["type": "session_meta", "payload": ["id": id, "source": "cli"]]
        func row(_ owner: String, tier: String?) -> JSONObject {
            var settings: JSONObject = ["model": "gpt-6.1-sol", "reasoning_effort": "xhigh"]
            if let tier { settings["service_tier"] = tier }
            return ["type": "event_msg", "payload": ["type": "thread_settings_applied", "thread_id": owner, "thread_settings": settings]]
        }
        func write(_ rows: [JSONObject]) throws {
            var data = Data(); for row in [header] + rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }; try data.write(to: log)
        }
        let session = AgentSession(id: "fixture", agent: .codex, pid: 1, started: "owned", tty: "/dev/owned", cwd: "/project", terminal: .unknown)
        let live = SessionGroupLiveSession(session: session, conversationID: id, providerHome: root.path)
        try write([row(id, tier: "priority"), row(id, tier: "ultrafast"), row(foreign, tier: "flex")])
        let value = TerminalProfileExecutionSettingsReader.read(live)
        try expectEqual(value?.model, "gpt-6.1-sol"); try expectEqual(value?.reasoningEffort, "xhigh"); try expectEqual(value?.serviceTier, "ultrafast")
        try write([row(id, tier: nil)]); try expectEqual(TerminalProfileExecutionSettingsReader.read(live)?.serviceTier, "default")
        try write([row(foreign, tier: "ultrafast")]); try expectNil(TerminalProfileExecutionSettingsReader.read(live)?.serviceTier)
    }

    @MainActor func testGroupClearMixedAgentsPreservesRolesAndDoesNotRepeat() async throws {
        for (leader, uncertain) in [(AgentKind.codex, false), (.claude, true)] {
            let fixture = GroupClearFixture(leader: leader, loseFirstReply: uncertain)
            let directory = URL(fileURLWithPath: "/private/tmp/aa-group-clear-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let sessions = fixture.records.map { AgentSession(id: $0.key, agent: $0.agent!, pid: $0.pid, started: $0.started, tty: "/dev/" + $0.tty, cwd: "/project", terminal: .iterm) }
            let adapter = ScreenHostAdapter(screens: { targets in .init(screens: targets.map { .init(tty: $0.tty, contents: fixture.screen($0.tty)) }) }, approve: { _,_,_ in .missingTarget }, reveal: { _ in nil }, input: { try fixture.send($0, $3) })
            let engine = try ApprovalEngine(paths: .init(directory: directory), claudeRegistryReader: { records in records.compactMap { record in
                guard record.agent == .claude, let index = fixture.records.firstIndex(where: { $0.key == record.key }) else { return nil }
                return .init(processID: record.key, kind: "interactive", sessionID: fixture.id(index), status: "idle")
            } }, processReader: { fixture.records }, screenAdapters: [.iterm: adapter], codexGroupReader: { record in
                guard record.agent == .codex, let index = fixture.records.firstIndex(where: { $0.key == record.key }) else { return nil }
                return .init(threadID: fixture.id(index), database: "/fixture/home/thread_history_1.sqlite")
            }, isolateByDefault: true, nativeKeyboardActivity: .inactive)
            defer { engine.stop() }; engine.groupClearInterval = 0.05
            engine.updateDiscovery(sessions, records: fixture.records); await engine.connectScreenHost(.iterm)
            let live = try await engine.sessionGroupSessions()
            let members = sessions.map { session in live.first { $0.id == session.id }!.member }
            let group = SessionGroup(name: "clear fixture", members: Array(members.prefix(2)), leaderMemberID: members[0].id)
            let store = SessionGroupStore(directory: directory); try store.save([group])
            let box = try SessionGroupMailbox(directory: directory)
            _ = try box.enqueue(groupID: group.id, senderID: members[1].id, recipientID: members[0].id, kind: .message, text: "retained")
            var request = UUID().uuidString
            func call(_ tool: String, caller: Int = 0, requestID: String? = nil) async throws -> JSONObject {
                try await engine.mcpAction(["owner": UUID().uuidString, "tool": tool, "groupID": group.id.uuidString, "requestID": requestID ?? request, "sessionID": sessions[caller].id])
            }
            do { _ = try await call("clear_session_group", caller: 2); throw AppError.message("Outside caller reset a group") } catch is RemoteHTTPError { }
            do { _ = try await call("clear_session_group", caller: 1); throw AppError.message("Child reset its leader") } catch is RemoteHTTPError { }
            fixture.draft(1, enabled: true)
            let receipt = try await call("clear_session_group")
            try expectEqual(receipt["accepted"] as? Bool, true); try expectEqual(receipt["done"] as? Bool, false)
            try await Task.sleep(for: .milliseconds(350))
            try expectEqual(fixture.counts(), [0,0,0], "Drafts and unfinished members also hold the caller until last")
            _ = try await call("clear_session_group")
            do { _ = try await call("clear_session_group", requestID: UUID().uuidString); throw AppError.message("Overlapping reset accepted") } catch is RemoteHTTPError { }
            var changed = group; changed.leaderMemberID = members[1].id; try store.save([changed])
            for _ in 0..<30 {
                if try await call("get_group_clear_status")["done"] as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try expectEqual(try await call("get_group_clear_status")["status"] as? String,"needs_review")
            try expectEqual(fixture.counts(),[0,0,0],"Revoked authority must stop queued resets")
            try store.save([group]); request = UUID().uuidString
            _ = try await call("clear_session_group")
            fixture.draft(1, enabled: false)
            var result: JSONObject = [:]
            for _ in 0..<180 {
                result = try await call("get_group_clear_status")
                if result["done"] as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try expectEqual(result["status"] as? String, "completed", String(describing: result))
            let latest = try await engine.mcpAction(["owner":UUID().uuidString,"tool":"get_group_clear_status","groupID":group.id.uuidString,"sessionID":sessions[0].id])
            try expectEqual((latest["requestID"] as? String)?.lowercased(),request.lowercased())
            try expectEqual(fixture.counts(), [1,1,0])
            _ = try await call("clear_session_group"); try expectEqual(fixture.counts(), [1,1,0])
            let saved = try store.load()[0]
            try expectEqual(saved.leaderMemberID, group.leaderMemberID); try expectEqual(saved.members.map(\.id), group.members.map(\.id))
            for index in 0..<2 { try expectEqual(saved.members[index].conversationID.lowercased(), fixture.id(index)) }
            try expectEqual(try box.pendingCount, 1); try expectEqual(try box.list(groupID: group.id, memberID: members[0].id)[0].text, "retained")
            try expect(engine.networkIsolated)
        }
    }

    @MainActor func testGroupClearRecoveryQueriesIdentityWithoutReplayingClear() async throws {
        for didClear in [true, false] {
        let fixture = GroupClearFixture(leader: .claude)
        let directory = URL(fileURLWithPath: "/private/tmp/aa-group-clear-recover-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = fixture.records.map { AgentSession(id: $0.key, agent: $0.agent!, pid: $0.pid, started: $0.started, tty: "/dev/" + $0.tty, cwd: "/project", terminal: .iterm) }
        let members = sessions.enumerated().map { SessionGroupLiveSession(session: $0.element, conversationID: fixture.id($0.offset), providerHome: $0.element.agent == .codex ? "/fixture/home" : nil).member }
        let group = SessionGroup(name: "recovery", members: Array(members.prefix(2)), leaderMemberID: members[0].id)
        let paths = AppPaths(directory: directory); try paths.prepare(); try SessionGroupStore(directory: directory).save([group])
        var target = SessionGroupClearTarget(member: members[1], live: .init(session: sessions[1], conversationID: fixture.id(1), providerHome: "/fixture/home"))
        target.phase = "issued"; if didClear { fixture.resetIdentity(1) }
        let job = SessionGroupClearOperation(id: UUID(), groupID: group.id, callerMemberID: members[0].id, targets: [target])
        try AuditStore(path: paths.database).set("sessionGroupClearOperations", String(decoding: JSONEncoder().encode([job]), as: UTF8.self))
        let adapter = ScreenHostAdapter(screens: { targets in .init(screens: targets.map { .init(tty: $0.tty, contents: fixture.screen($0.tty)) }) }, approve: { _,_,_ in .missingTarget }, reveal: { _ in nil }, input: { try fixture.send($0, $3) })
        let engine = try ApprovalEngine(paths: paths, claudeRegistryReader: { records in records.filter { $0.agent == .claude }.map { .init(processID: $0.key, kind: "interactive", sessionID: fixture.id(0), status: "idle") } }, processReader: { fixture.records }, screenAdapters: [.iterm: adapter], codexGroupReader: { _ in .init(threadID: fixture.id(1), database: "/fixture/home/thread_history_1.sqlite") }, isolateByDefault: true, nativeKeyboardActivity: .inactive)
        defer { engine.stop() }; engine.groupClearInterval = 0.05
        engine.updateDiscovery(sessions, records: fixture.records); await engine.connectScreenHost(.iterm); try engine.start(poll: false)
        var result: JSONObject = [:]
        for _ in 0..<100 {
            result = try await engine.mcpAction(["owner": UUID().uuidString, "tool": "get_group_clear_status", "groupID": group.id.uuidString, "requestID": job.id.uuidString, "sessionID": sessions[0].id])
            if result["done"] as? Bool == true { break }; try await Task.sleep(for: .milliseconds(100))
        }
        try expectEqual(result["status"] as? String, didClear ? "completed" : "needs_review")
        try expectEqual(fixture.counts(), [0,0,0], "An uncertain pre-crash write must never be replayed")
        let queries = fixture.queries(); try await Task.sleep(for:.milliseconds(250))
        try expectEqual(fixture.queries(), queries, "A finished or uncertain reset must not accumulate status scripts")
        }
    }
}
