import Foundation
import Darwin
import CSQLite
import AutoApproveCore

private func nativeValue<T>(_ value: T?) throws -> T {
    guard let value else { throw AppError.message("Missing native fixture value") }
    return value
}

extension ApprovalTests {
    func testProcessAgentNamePrefilterKeepsFoundationClassification() throws {
        // Independent compatibility oracle: the original Foundation path rules,
        // including URL resolution for empty/dot names and Unicode numerals.
        func reference(_ executable: String) -> AgentKind? {
            let component = (executable as NSString).lastPathComponent
            let name = component.isEmpty || component == "." || component == ".."
                ? URL(fileURLWithPath: executable).lastPathComponent : component
            let agent: AgentKind?
            if name == "codex" { agent = .codex }
            else if name == "claude" || (name.first?.isNumber == true && executable.contains("/claude/versions/")) { agent = .claude }
            else { return nil }
            return executable.contains("/Applications/ChatGPT.app/") ? nil : agent
        }
        let leaves = ["codex", "claude", "Codex", "Claude", "codec", "xcode", "node", "worker-12", "service",
                      "2.1.0", "2.1.0-beta", "0", "٤.٢", "Ⅷ", "²", "一", "코덱스", "🙂", "e\u{301}", ".", "..", "", "\0codex"]
        let roots = ["", "/", "//", "/fixture/", "relative/", "~/", "./", "../", "/fixture/한글 e\u{301}/",
                     "/fixture/claude/versions/", "/Applications/ChatGPT.app/Contents/MacOS/",
                     "/Applications/ChatGPT.app/claude/versions/", "C:\\fixture\\"]
        var record = ProcessDiscovery.parse("42 1 ttys042 42 42 Tue Oct 20 02:00:00 2026 codex")[0]
        func check(_ value: String) throws {
            record.executable = value
            try expectEqual(record.agent, reference(value), "Classification changed for " + String(reflecting: value))
            // NSString-origin strings must also keep the same result.
            record.executable = (NSMutableString(string: value) as NSString) as String
            try expectEqual(record.agent, reference(value), "Foreign classification changed for " + String(reflecting: value))
        }
        for root in roots {
            for leaf in leaves {
                for suffix in ["", "/", "///"] { try check(root + leaf + suffix) }
            }
        }
        var seed: UInt64 = 0x5a17c0de
        let alphabet: [Character] = Array("abcdfw0129._-/\\ ~한글é\u{301}🙂٤Ⅷ")
        for _ in 0..<2000 {
            seed = seed &* 6364136223846793005 &+ 1
            let count = Int(seed % 64)
            var value = ""
            for _ in 0..<count {
                seed = seed &* 6364136223846793005 &+ 1
                value.append(alphabet[Int(seed % UInt64(alphabet.count))])
            }
            try check(value)
        }
        record.executable = "/fixture/codex"
        try expectEqual(record.agent, .codex)
        record.executable = "/fixture/worker"
        try expect(record.agent == nil, "No classification result survives an executable change")
        record.executable = "/fixture/claude/versions/2.1.0"
        try expectEqual(record.agent, .claude)
    }

    func testFilteredAgentAncestryRevalidatesTheCompleteParentChain() throws {
        let rows = ProcessDiscovery.parse("""
        10 20 ttys901 10 20 Tue Oct 20 02:00:00 2026 /fixture/helper
        20 30 ttys901 20 20 Tue Oct 20 01:59:00 2026 /fixture/codex
        30 1 ttys901 30 20 Tue Oct 20 01:58:00 2026 /fixture/claude
        """)
        let graph = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) })
        var calls: [Int32] = []
        let enclosing = try ProcessDiscovery.enclosingAgent(of: 10, matching: .claude) { pid in
            calls.append(pid); return graph[pid].map { [$0] } ?? []
        }
        try expectEqual(enclosing, graph[30])
        try expectEqual(calls, [10, 20, 30, 30, 20, 10], "Only the matching ancestor and its complete chain are read and revalidated")
        try expectEqual(try ProcessDiscovery.enclosingAgent(of: 10) { graph[$0].map { [$0] } ?? [] }, graph[20])
        try expectEqual(try ProcessDiscovery.enclosingAgent(of: 10, matching: .codex) { graph[$0].map { [$0] } ?? [] }, graph[20])
        var changed = graph, reads: [Int32: Int] = [:]
        changed[20]?.parent = 99
        let rejected = try ProcessDiscovery.enclosingAgent(of: 10, matching: .claude) { pid in
            reads[pid, default: 0] += 1
            return (reads[pid, default: 0] > 1 ? changed[pid] : graph[pid]).map { [$0] } ?? []
        }
        try expect(rejected == nil, "A nonmatching intermediate agent is still part of the original ownership proof")
    }

    func testNativeProcessMetadataAndOriginalHostParity() throws {
        func reference() throws -> [ProcessRecord] {
            let result = try CommandRunner.run("/bin/ps", ["-axo", "pid=,ppid=,tty=,pgid=,tpgid=,lstart=,comm="], environment: ["LC_ALL":"C","LANG":"C"])
            try expectEqual(result.status, 0)
            return ProcessDiscovery.parse(result.output)
        }
        let before = try reference(), current = try ProcessDiscovery.read()
        let focused = try ProcessDiscovery.readSessions(), after = try reference()
        let old = Dictionary(before.map { ($0.pid,$0) }, uniquingKeysWith: { a,_ in a })
        let new = Dictionary(current.map { ($0.pid,$0) }, uniquingKeysWith: { a,_ in a })
        let final = Dictionary(after.map { ($0.pid,$0) }, uniquingKeysWith: { a,_ in a })
        try expectNotNil(new[getpid()]); try expectEqual(new[getpid()],old[getpid()])
        try expectEqual(try ProcessDiscovery.read(pid: getpid()).first, new[getpid()],
            "A targeted non-agent read must preserve the complete reader's identity and executable")
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
        let focusedSessions = ProcessDiscovery.sessions(focused)
        for expected in expectedSessions where old[expected.pid] == final[expected.pid] {
            let actual = try nativeValue(actualSessions.first { $0.id == expected.id })
            let focusedActual = try nativeValue(focusedSessions.first { $0.id == expected.id })
            try expectEqual(actual.pid,expected.pid); try expectEqual(actual.tty,expected.tty)
            try expectEqual(actual.started,expected.started); try expectEqual(actual.agent,expected.agent)
            try expectEqual(actual.terminal,expected.terminal); try expectEqual(actual.hostBundleID,expected.hostBundleID)
            try expectEqual(actual.tmuxHandle,expected.tmuxHandle); try expectEqual(actual.orcaHandle,expected.orcaHandle)
            try expectEqual(focusedActual.pid,actual.pid); try expectEqual(focusedActual.tty,actual.tty)
            try expectEqual(focusedActual.started,actual.started); try expectEqual(focusedActual.agent,actual.agent)
            try expectEqual(focusedActual.terminal,actual.terminal); try expectEqual(focusedActual.hostBundleID,actual.hostBundleID)
            try expectEqual(focusedActual.tmuxHandle,actual.tmuxHandle); try expectEqual(focusedActual.orcaHandle,actual.orcaHandle)
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
        try expectEqual(sqlite3_exec(db,"CREATE TABLE thread_history_projection_state(thread_id TEXT PRIMARY KEY,next_rollout_ordinal INTEGER); CREATE TABLE thread_items(thread_id TEXT,item_id TEXT,rollout_ordinal INTEGER,item_type TEXT,updated_at_ordinal INTEGER,item_json TEXT); CREATE INDEX idx_thread_items_page ON thread_items(thread_id,rollout_ordinal); CREATE INDEX idx_thread_items_updated_page ON thread_items(thread_id,updated_at_ordinal); INSERT INTO thread_history_projection_state VALUES('\(thread)',2),('\(next)',2); INSERT INTO thread_items VALUES('\(thread)','fixture-q',1,'agentMessage',1,'\(json)');",nil,nil,nil),SQLITE_OK)
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
