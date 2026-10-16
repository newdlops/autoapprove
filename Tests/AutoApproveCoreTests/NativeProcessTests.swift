import Foundation
import Darwin
import CSQLite
import AutoApproveCore

private func nativeValue<T>(_ value: T?) throws -> T {
    guard let value else { throw AppError.message("Missing native fixture value") }
    return value
}

extension ApprovalTests {
    func testNativeProcessMetadataAndOriginalHostParity() throws {
        func reference() throws -> [ProcessRecord] {
            let result = try CommandRunner.run("/bin/ps", ["-axo", "pid=,ppid=,tty=,pgid=,tpgid=,lstart=,comm="], environment: ["LC_ALL":"C","LANG":"C"])
            try expectEqual(result.status, 0)
            return ProcessDiscovery.parse(result.output)
        }
        let before = try reference(), current = try ProcessDiscovery.read(), after = try reference()
        let old = Dictionary(before.map { ($0.pid,$0) }, uniquingKeysWith: { a,_ in a })
        let new = Dictionary(current.map { ($0.pid,$0) }, uniquingKeysWith: { a,_ in a })
        let final = Dictionary(after.map { ($0.pid,$0) }, uniquingKeysWith: { a,_ in a })
        try expectNotNil(new[getpid()]); try expectEqual(new[getpid()],old[getpid()])
        for row in before where row == final[row.pid] && row.executable != "<defunct>" {
            guard let actual = new[row.pid] else { throw AppError.message("A stable reference process was omitted") }
            try expectEqual(actual.key,row.key); try expectEqual(actual.parent,row.parent)
            try expectEqual(actual.tty,row.tty); try expectEqual(actual.processGroup,row.processGroup)
            try expectEqual(actual.foregroundGroup,row.foregroundGroup)
            // Restricted system paths may resolve to a canonical alias. Original
            // CLI launch names, identity and terminal ownership must agree.
            if row.agent != nil { try expectEqual(actual.executable,row.executable); try expectEqual(actual.agent,row.agent) }
        }
        let expectedSessions = ProcessDiscovery.sessions(before), actualSessions = ProcessDiscovery.sessions(current)
        for expected in expectedSessions where old[expected.pid] == final[expected.pid] {
            let actual = try nativeValue(actualSessions.first { $0.id == expected.id })
            try expectEqual(actual.pid,expected.pid); try expectEqual(actual.tty,expected.tty)
            try expectEqual(actual.started,expected.started); try expectEqual(actual.agent,expected.agent)
            try expectEqual(actual.terminal,expected.terminal); try expectEqual(actual.hostBundleID,expected.hostBundleID)
            try expectEqual(actual.tmuxHandle,expected.tmuxHandle); try expectEqual(actual.orcaHandle,expected.orcaHandle)
        }
    }

    func testNativeQuestionPreparationUsesCurrentProcessAndOpenFiles() async throws {
        let root = URL(fileURLWithPath:"/private/tmp/aa-question-native-"+UUID().uuidString).appendingPathComponent("한글 e\u{301} with spaces")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root.deletingLastPathComponent()) }
        let thread = UUID().uuidString.lowercased(), next = UUID().uuidString.lowercased()
        let database = root.appendingPathComponent("thread_history_1.sqlite"), day = root.appendingPathComponent("sessions/2026/10/16")
        try FileManager.default.createDirectory(at:day,withIntermediateDirectories:true)
        let rollout = day.appendingPathComponent("rollout-fixture.jsonl")
        func select(_ id: String) throws {
            var value = try JSONSerialization.data(withJSONObject:["type":"session_meta","payload":["source":"cli","id":id]])
            value.append(10);try value.write(to:rollout)
        }
        try select(thread)
        var db: OpaquePointer?
        try expectEqual(sqlite3_open(database.path,&db),SQLITE_OK)
        defer { sqlite3_close(db) }
        let question: JSONObject = ["type":"agentMessage","delivery":"async","id":"fixture-q","questions":[["title":"Pick a fixture option","options":["A","B"]]]]
        let json = String(decoding:try JSONSerialization.data(withJSONObject:question),as:UTF8.self).replacingOccurrences(of:"'",with:"''")
        try expectEqual(sqlite3_exec(db,"CREATE TABLE thread_history_projection_state(thread_id TEXT PRIMARY KEY,next_rollout_ordinal INTEGER); CREATE TABLE thread_items(thread_id TEXT,item_id TEXT,rollout_ordinal INTEGER,item_type TEXT,updated_at_ordinal INTEGER,item_json TEXT); INSERT INTO thread_history_projection_state VALUES('\(thread)',2),('\(next)',2); INSERT INTO thread_items VALUES('\(thread)','fixture-q',1,'agentMessage',1,'\(json)');",nil,nil,nil),SQLITE_OK)
        let originalDatabase = try Data(contentsOf:database)
        let child = Process();child.executableURL = URL(fileURLWithPath:"/bin/zsh")
        child.arguments = ["-c","exec -a codex /bin/sleep 20 3< \"$1\" 4< \"$2\"","fixture",database.path,rollout.path]
        child.standardInput = FileHandle.nullDevice;child.standardOutput = FileHandle.nullDevice;child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        var record: ProcessRecord?
        let deadline = ProcessInfo.processInfo.systemUptime+3
        while ProcessInfo.processInfo.systemUptime < deadline {
            record = try ProcessDiscovery.read(pid:child.processIdentifier).first
            if record?.agent == .codex { break }
            try await Task.sleep(nanoseconds:10_000_000)
        }
        let live = try nativeValue(record);try expectEqual(live.agent,.codex)
        let session = AgentSession(id:live.key,agent:.codex,pid:live.pid,started:live.started,tty:"/dev/"+live.tty,cwd:root.path,terminal:.terminal)
        func expectHome(_ path: String) throws {
            var actual = stat(), expected = stat()
            try expectEqual(path.withCString { Darwin.lstat($0,&actual) },0)
            try expectEqual(root.path.withCString { Darwin.lstat($0,&expected) },0)
            try expectEqual(actual.st_dev,expected.st_dev);try expectEqual(actual.st_ino,expected.st_ino)
        }
        let message = try await CodexReplyTransport.messageTarget(session)
        // Foundation may shorten /private/tmp while libproc preserves it.
        // Compare the directory identity rather than the symlink's spelling.
        try expectHome(message.home)
        try expectEqual(message.threadID,thread)
        let queue = try await CodexReplyTransport.selectedQueueTarget(session,threadID:thread)
        try expectHome(queue.home)
        try expectEqual(queue.threadID,thread)
        let pending = try nativeValue(CodexHistoryReader().read(CodexThreadLocation.locate(paths:[rollout.path])).first)
        let target = try await CodexReplyTransport.live.prepare(session,pending)
        try expectEqual(target.threadID,thread);try expectNil(target.automaticReplyUnavailableReason)
        var stale = session;stale.started = "wrong process lifetime"
        do { _ = try await CodexReplyTransport.messageTarget(stale);throw AppError.message("Stale lifetime accepted") }
        catch { try expect(!error.localizedDescription.contains("Stale lifetime accepted")) }
        try select(next)
        try expectEqual(try await CodexReplyTransport.messageTarget(session).threadID,next,"The open rollout must be read afresh before preparing a message")
        do { _ = try await CodexReplyTransport.live.prepare(session,pending);throw AppError.message("Old conversation accepted") }
        catch { try expect(!error.localizedDescription.contains("Old conversation accepted")) }
        try expectEqual(try Data(contentsOf:database),originalDatabase,"Preparation is read-only and never queues or sends input")
        child.terminate();child.waitUntilExit()
        do { _ = try await CodexReplyTransport.messageTarget(session);throw AppError.message("Exited process accepted") }
        catch { try expect(!error.localizedDescription.contains("Exited process accepted")) }
    }

    func testNativeProcessCancellationAndMissingIdentity() async throws {
        try expect(try ProcessDiscovery.read(pid:Int32.max).isEmpty)
        try expectThrows(ProcessDiscovery.read(pid:-1))
        let task = Task { try ProcessDiscovery.read() }
        task.cancel()
        do { _ = try await task.value;throw AppError.message("Cancelled discovery returned a list") }
        catch is CancellationError {}
    }
}
