import Foundation
import CSQLite
import JavaScriptCore
import TerminalInputSupport
import AutoApproveCore

/// The caller is cleared last. During the brief UUID transition, strict
/// membership intentionally rejects reads until the new ID is verified/saved.
@MainActor private func clearFixtureAction(_ engine:ApprovalEngine,_ args:JSONObject) async throws -> JSONObject {
    for attempt in 0..<30 {
        do {return try await engine.mcpAction(args)}
        catch let error as RemoteHTTPError where args["tool"] as? String == "get_group_clear_status" && error.status == 403 && attempt < 29 {
            try await Task.sleep(for:.milliseconds(100))
        }
    }
    throw AppError.message("The caller's refreshed membership did not become available")
}

private final class GroupClearFixture: @unchecked Sendable {
    private let lock = NSLock()
    var records: [ProcessRecord]
    private var ids: [String]
    private var screens: [String]
    private var clears = [0, 0, 0]
    private var statusReads = [0, 0, 0]
    private var labels: [String: String] = [:]
    private var labelWrites = 0
    private var activeTTY: String?
    private var keyboardOnMain=false
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
    func setLabel(_ target: ScreenTarget, _ label: TerminalTabLabel) -> String {
        lock.lock(); defer { lock.unlock() }; labels[target.tty] = label.rendered; labelWrites += 1; return label.rendered
    }
    func labelCount() -> Int { lock.lock(); defer { lock.unlock() }; return labelWrites }
    func setActiveTTY(_ tty:String?) {lock.lock();defer {lock.unlock()};activeTTY=tty}
    func keyboardTTY() -> String? {lock.lock();defer {lock.unlock()};keyboardOnMain = keyboardOnMain || Thread.isMainThread;return activeTTY}
    func readKeyboardOnMain() -> Bool {lock.lock();defer {lock.unlock()};return keyboardOnMain}
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
    func testKeyboardTargetReadRejectsChangingAndAmbiguousFocus() throws {
        for values in [["/dev/one"],["/dev/one","/dev/two"],[]] {
            var reads=0
            let reader=TerminalAppleEventReader(timeout:0.4) {_,timeout in
                try expect(timeout <= 0.2)
                let list=NSAppleEventDescriptor.list()
                for (index,value) in values.enumerated() {list.insert(.init(string:value),at:index+1)}
                reads += 1;return list
            }
            try expectEqual(try reader.keyboardTargetTTY(),values.count == 1 ? values[0]:nil)
            try expectEqual(reads,values.count == 1 ? 2:1)
        }
        var reads=0
        let changing=TerminalAppleEventReader(timeout:0.4) {_,_ in
            reads += 1;return .init(string:reads == 1 ? "/dev/one":"/dev/two")
        }
        try expectNil(try changing.keyboardTargetTTY());try expectEqual(reads,2)
    }

    private nonisolated static func evaluateBackgroundScript(_ script:String,tty:String,raw:String,agent:AgentKind,conflict:Bool = false) throws -> String {
        func literal(_ value:Any) throws -> String {String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed]),as:UTF8.self)}
        let context=JSContext()!
        context.evaluateScript("""
        const raw=\(try literal(raw)), tty=\(try literal(tty)), agent=\(try literal(agent.rawValue)), writes=[];
        const chosen={tty:()=>tty,contents:()=>raw,processes:()=>[agent]};
        const alias={tty:()=>tty,contents:()=>raw+\(try literal(conflict ? " changed" : "")),processes:()=>[agent]};
        const other={tty:()=>'/dev/unrelated',contents:()=>{throw Error('unrelated screen read')},processes:()=>[]};
        const app={running:()=>true,windows:()=>[{tabs:()=>{throw Error('closed window')}},{tabs:()=>[other,chosen]},{tabs:()=>[alias]}],doScript:(text,options)=>{if(options.in!==chosen)throw Error('wrong tab');writes.push(text);}};
        function Application(){return app;}
        """)
        let result=context.evaluateScript(script)?.toString() ?? ""
        try expect(context.exception == nil,context.exception?.toString() ?? "Background script failed")
        try expectEqual(context.evaluateScript("writes.length")?.toInt32(),conflict ? 0:1)
        if !conflict,agent == .claude {try expectEqual(context.evaluateScript("writes[0]")?.toString(),"/clear")}
        for forbidden in ["activate", "selectedTab", "System Events"] {try expectFalse(script.contains(forbidden))}
        return result
    }

    @MainActor func testGroupClearBackgroundWindowsPreserveActiveInput() async throws {
        for leader in [AgentKind.codex,.claude] {
            let fixture=GroupClearFixture(leader:leader)
            let directory=URL(fileURLWithPath:"/private/tmp/aa-clear-windows-"+UUID().uuidString)
            defer {try? FileManager.default.removeItem(at:directory)}
            let records=fixture.records
            let sessions=records.map {AgentSession(id:$0.key,agent:$0.agent!,pid:$0.pid,started:$0.started,tty:"/dev/"+$0.tty,cwd:"/project",terminal:.terminal)}
            let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.timeZone = .current;formatter.dateFormat="EEE MMM d HH:mm:ss yyyy"
            let identities=Dictionary(uniqueKeysWithValues:records.map {record in (record.pid,TTYInputIdentity(pid:record.pid,processGroup:record.pid,uid:getuid(),effectiveUID:geteuid(),device:UInt32(record.pid),startSeconds:UInt64(formatter.date(from:record.started)!.timeIntervalSince1970),startMicroseconds:71))})
            let probe=ScreenTarget(tty:sessions[1].tty,jobPIDs:[sessions[1].pid],sourcePID:sessions[1].pid,sourceStarted:sessions[1].started,sourceIdentity:identities[sessions[1].pid])
            let raw=fixture.screen(probe.tty),agent=sessions[1].agent
            let conflict=try TerminalDeviceInput.deliverBackground(target:probe,screen:raw,agent:agent,input:.init(kind:.submit,text:"/clear"),captureIdentity:{identities[$0]!},run:{script in
                try Self.evaluateBackgroundScript(script,tty:probe.tty,raw:raw,agent:agent,conflict:true)
            })
            try expectEqual(conflict,.screenChanged,"Disagreeing aliases must never select an arbitrary input target")
            if agent == .claude {
                let unrelated=try TerminalDeviceInput.deliverBackground(target:probe,screen:raw,agent:agent,input:.init(kind:.submit,text:"unrelated command"),captureIdentity:{identities[$0]!},run:{_ in throw AppError.message("Only fixed /clear may use this Claude path")})
                try expectEqual(unrelated,.agentMissing)
            }
            var adapter=ScreenHostAdapter(screens:{targets in .init(screens:targets.map {.init(tty:$0.tty,contents:fixture.screen($0.tty))})},approve:{_,_,_ in .missingTarget},reveal:{_ in throw AppError.message("No window reveal allowed")},input:{_,_,_,_ in throw AppError.message("No foreground keyboard input allowed")},presentationScreens:{_ in throw AppError.message("No cursor/window capture required")})
            adapter.backgroundInput={target,raw,agent,input in
                try TerminalDeviceInput.deliverBackground(target:target,screen:raw,agent:agent,input:input,captureIdentity:{identities[$0]!},run:{script in
                    let result=try Self.evaluateBackgroundScript(script,tty:target.tty,raw:raw,agent:agent)
                    guard result == "sent" else {return result}
                    _ = try fixture.send(target,input);return result
                })
            }
            let keyboard=NativeKeyboardActivity(idleSeconds:{0},frontmostBundle:{ScreenHost.terminal.bundleID},inputTargetTTY:{_ in fixture.keyboardTTY()})
            let engine=try ApprovalEngine(paths:.init(directory:directory),claudeRegistryReader:{records in records.compactMap {record in
                guard record.agent == .claude,let index=fixture.records.firstIndex(where:{$0.key==record.key}) else {return nil}
                return .init(processID:record.key,kind:"interactive",sessionID:fixture.id(index),status:"idle")
            }},processReader:{records},screenAdapters:[.terminal:adapter],terminalInputAvailable:{true},terminalInputIdentity:{identities[$0]},codexGroupReader:{record in
                guard record.agent == .codex,let index=records.firstIndex(where:{$0.key==record.key}) else {return nil}
                return .init(threadID:fixture.id(index),database:"/fixture/home/thread_history_1.sqlite")
            },isolateByDefault:true,nativeKeyboardActivity:keyboard)
            defer {engine.stop()};engine.groupClearInterval=0.05
            engine.updateDiscovery(sessions,records:records);await engine.connectScreenHost(.terminal)
            let live=try await engine.sessionGroupSessions(),members=sessions.map {session in live.first {$0.id==session.id}!.member}
            let group=SessionGroup(name:"background windows",members:Array(members.prefix(2)),leaderMemberID:members[0].id)
            try SessionGroupStore(directory:directory).save([group])
            fixture.setActiveTTY(sessions[0].tty)
            func call(_ tool:String,member:Int,request:UUID) async throws -> JSONObject {
                try await clearFixtureAction(engine,["owner":UUID().uuidString,"tool":tool,"groupID":group.id.uuidString,"memberID":members[member].id.uuidString,"requestID":request.uuidString,"sessionID":sessions[0].id])
            }
            let request=UUID();_ = try await call("clear_group_member",member:1,request:request)
            var result:JSONObject=[:]
            for _ in 0..<150 {
                result=try await call("get_group_clear_status",member:1,request:request)
                if result["done"] as? Bool == true {break};try await Task.sleep(for:.milliseconds(100))
            }
            try expectEqual(result["status"] as? String,"completed",String(describing:result))
            try expectEqual(fixture.counts(),[0,1,0],"Typing in another window must not block the exact background tab")
            let selfRequest=UUID();_ = try await call("clear_group_member",member:0,request:selfRequest)
            try await Task.sleep(for:.milliseconds(300));try expectEqual(fixture.counts(),[0,1,0],"The actual keyboard target must remain protected")
            fixture.setActiveTTY(nil)
            try await Task.sleep(for:.milliseconds(200));try expectEqual(fixture.counts(),[0,1,0],"Unknown focus must remain protected")
            fixture.setActiveTTY(sessions[2].tty)
            for _ in 0..<150 {
                result=try await call("get_group_clear_status",member:0,request:selfRequest)
                if result["done"] as? Bool == true {break};try await Task.sleep(for:.milliseconds(100))
            }
            try expectEqual(result["status"] as? String,"completed",String(describing:result))
            try expectEqual(fixture.counts(),[1,1,0])
            try expectFalse(fixture.readKeyboardOnMain(),"Native focus queries must never block the UI thread")
            let saved=try SessionGroupStore(directory:directory).load()[0]
            for index in 0..<2 {try expectEqual(saved.members[index].conversationID.lowercased(),fixture.id(index))}
        }
    }

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
                try await clearFixtureAction(engine,["owner": UUID().uuidString, "tool": tool, "groupID": group.id.uuidString, "requestID": requestID ?? request, "sessionID": sessions[caller].id])
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
            let latest = try await clearFixtureAction(engine,["owner":UUID().uuidString,"tool":"get_group_clear_status","groupID":group.id.uuidString,"sessionID":sessions[0].id])
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

    @MainActor func testManualClaudeClearPreservesGroupAuthority() async throws {
        let fixture = GroupClearFixture(leader: .claude, loseFirstReply: false)
        let directory = URL(fileURLWithPath: "/private/tmp/aa-manual-clear-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = fixture.records.map {
            AgentSession(id: $0.key, agent: $0.agent!, pid: $0.pid, started: $0.started, tty: "/dev/" + $0.tty, cwd: "/project", terminal: .iterm)
        }
        let engine = try ApprovalEngine(paths: .init(directory: directory), claudeRegistryReader: { records in
            records.compactMap { record in
                guard record.agent == .claude, let index = fixture.records.firstIndex(where: { $0.key == record.key }) else { return nil }
                return .init(processID: record.key, kind: "interactive", sessionID: fixture.id(index), status: "idle")
            }
        }, processReader: { fixture.records }, codexGroupReader: { record in
            guard record.agent == .codex, let index = fixture.records.firstIndex(where: { $0.key == record.key }) else { return nil }
            return .init(threadID: fixture.id(index), database: "/fixture/home/thread_history_1.sqlite")
        }, isolateByDefault: true)
        defer { engine.stop() }
        engine.updateDiscovery(sessions, records: fixture.records)
        let live = try await engine.sessionGroupSessions()
        let members = sessions.map { session in live.first { $0.id == session.id }!.member }
        let group = SessionGroup(name: "manual clear", members: Array(members.prefix(2)), leaderMemberID: members[0].id)
        let store = SessionGroupStore(directory: directory)
        try store.save([group])
        fixture.resetIdentity(0)
        let status = try await engine.mcpAction(["owner": UUID().uuidString, "tool": "get_group_status", "sessionID": sessions[0].id])
        let groups = status["groups"] as? [JSONObject]
        let roster = groups?.first?["members"] as? [JSONObject]
        try expectEqual(roster?.first(where: { $0["id"] as? String == members[1].id.uuidString })?["canAssign"] as? Bool, true)
        let saved = try store.load()[0]
        try expectEqual(saved.members.map(\.id), group.members.map(\.id))
        try expectEqual(saved.leaderMemberIDs, group.leaderMemberIDs)
        try expectEqual(saved.parentID(of: members[1].id), members[0].id)
        try expectEqual(saved.members[0].conversationID, fixture.id(0))
        try expectEqual(fixture.counts(), [0,0,0], "Observation sends no /clear")
    }

    @MainActor func testGroupClearSelectedMemberOnlyAndRequestScope() async throws {
        for leader in [AgentKind.codex, .claude] {
            let fixture = GroupClearFixture(leader: leader, loseFirstReply: true)
            let directory = URL(fileURLWithPath: "/private/tmp/aa-member-clear-" + UUID().uuidString)
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
            let members = try await engine.sessionGroupSessions().map(\.member)
            let ordered = sessions.map { session in members.first { $0.runtimeID == session.id }! }
            let group = SessionGroup(name: "selected member", members: Array(ordered.prefix(2)), leaderMemberID: ordered[0].id)
            let store = SessionGroupStore(directory: directory); try store.save([group])
            let request = UUID().uuidString, originalLeaderID = fixture.id(0), originalOutsideID = fixture.id(2)
            func call(_ tool: String = "clear_group_member", member: String? = nil, caller: Int = 0, requestID: String? = nil) async throws -> JSONObject {
                var args: JSONObject = ["owner": UUID().uuidString, "tool": tool, "groupID": group.id.uuidString, "requestID": requestID ?? request, "sessionID": sessions[caller].id]
                if let member { args["memberID"] = member }
                return try await clearFixtureAction(engine,args)
            }
            for member in [nil, "bad-id"] as [String?] {
                do { _ = try await call(member: member); throw AppError.message("Invalid target accepted") } catch let error as RemoteHTTPError { try expectEqual(error.status, 400) }
            }
            do { _ = try await call(member: ordered[2].id.uuidString); throw AppError.message("Outside target accepted") } catch let error as RemoteHTTPError { try expectEqual(error.status, 404) }
            do { _ = try await call(member: ordered[1].id.uuidString, caller: 1); throw AppError.message("Member reset without leader authority") } catch let error as RemoteHTTPError { try expectEqual(error.status, 403) }
            do { _ = try await call(member: ordered[1].id.uuidString, caller: 2); throw AppError.message("Outside caller reset a member") } catch let error as RemoteHTTPError { try expectEqual(error.status, 403) }
            fixture.draft(1, enabled: true)
            let receipt = try await call(member: ordered[1].id.uuidString)
            try expectEqual(receipt["accepted"] as? Bool, true); try expectEqual(receipt["total"] as? Int, 1)
            try expectEqual(receipt["scope"] as? String, "member"); try expectEqual(receipt["memberID"] as? String, ordered[1].id.uuidString)
            try await Task.sleep(for: .milliseconds(350)); try expectEqual(fixture.counts(), [0,0,0])
            do { _ = try await call(member: ordered[0].id.uuidString); throw AppError.message("Reused request changed its target") } catch let error as RemoteHTTPError { try expectEqual(error.status, 409) }
            do { _ = try await call("clear_session_group"); throw AppError.message("Member request became whole-group reset") } catch let error as RemoteHTTPError { try expectEqual(error.status, 409) }
            do { _ = try await call("clear_session_group", requestID: UUID().uuidString); throw AppError.message("Overlapping whole-group reset accepted") } catch let error as RemoteHTTPError { try expectEqual(error.status, 409) }
            fixture.draft(1, enabled: false)
            var result: JSONObject = [:]
            for _ in 0..<120 {
                result = try await call("get_group_clear_status")
                if result["done"] as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try expectEqual(result["status"] as? String, "completed", String(describing: result))
            _ = try await call(member: ordered[1].id.uuidString)
            try expectEqual(fixture.counts(), [0,1,0], "Only the selected Codex/Claude receives /clear, even after a lost reply")
            try expectEqual(fixture.id(0), originalLeaderID); try expectEqual(fixture.id(2), originalOutsideID)
            let saved = try store.load()[0]
            try expectEqual(saved.leaderMemberID, group.leaderMemberID); try expectEqual(saved.members.map(\.id), group.members.map(\.id))
            try expectEqual(saved.members[0].conversationID, group.members[0].conversationID)
            try expectEqual(saved.members[1].conversationID.lowercased(), fixture.id(1))
            let job = SessionGroupClearOperation(id: UUID(), groupID: group.id, callerMemberID: ordered[0].id, targets: [], selectedMemberID: ordered[1].id)
            try expectEqual(try JSONDecoder().decode(SessionGroupClearOperation.self, from: JSONEncoder().encode(job)).selectedMemberID, ordered[1].id)
            var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! JSONObject
            legacy.removeValue(forKey: "selectedMemberID")
            let decoded = try JSONDecoder().decode(SessionGroupClearOperation.self, from: JSONSerialization.data(withJSONObject: legacy))
            try expectNil(decoded.selectedMemberID); try expectEqual(decoded.json["scope"] as? String, "group")
            // Selecting the caller does not wait on other members' drafts.
            fixture.draft(1, enabled: true)
            let selfRequest = UUID().uuidString
            _ = try await call(member: ordered[0].id.uuidString, requestID: selfRequest)
            for _ in 0..<120 {
                result = try await call("get_group_clear_status", requestID: selfRequest)
                if result["done"] as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try expectEqual(result["status"] as? String, "completed", String(describing: result))
            try expectEqual(fixture.counts(), [1,1,0])
        }
    }

    @MainActor func testGroupTabLabelUsesExactMemberAndPreservesWork() async throws {
        let fixture = GroupClearFixture(leader: .codex)
        let directory = URL(fileURLWithPath: "/private/tmp/aa-group-tab-label-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var sessions = fixture.records.map { AgentSession(id: $0.key, agent: $0.agent!, pid: $0.pid, started: $0.started, tty: "/dev/" + $0.tty, cwd: "/project", terminal: .iterm) }
        sessions[1].terminalTitle="🔴 원래 이름"
        let adapter = ScreenHostAdapter(screens: { targets in .init(screens: targets.map { .init(tty: $0.tty, contents: fixture.screen($0.tty)) }) }, approve: { _,_,_ in .missingTarget }, reveal: { _ in nil }, input: { try fixture.send($0, $3) }, setTabLabel: { fixture.setLabel($0,$1) })
        let engine = try ApprovalEngine(paths: .init(directory: directory), claudeRegistryReader: { records in records.filter { $0.agent == .claude }.map { .init(processID: $0.key, kind: "interactive", sessionID: fixture.id(1), status: "working") } }, processReader: { fixture.records }, screenAdapters: [.iterm: adapter], codexGroupReader: { record in
            guard record.agent == .codex, let index = fixture.records.firstIndex(where: { $0.key == record.key }) else { return nil }
            return .init(threadID: fixture.id(index), database: "/fixture/home/thread_history_1.sqlite")
        }, isolateByDefault: true, nativeKeyboardActivity: .inactive)
        defer { engine.stop() }
        engine.updateDiscovery(sessions, records: fixture.records); await engine.connectScreenHost(.iterm)
        let live = try await engine.sessionGroupSessions(), members = sessions.map { session in live.first { $0.id == session.id }!.member }
        let group = SessionGroup(name: "tab label", members: Array(members.prefix(2)), leaderMemberID: members[0].id)
        try SessionGroupStore(directory: directory).save([group])
        try engine.setCustomization(sessions[1].id, value: .init(note: "keep note"))
        fixture.draft(1, enabled: true)
        func call(_ tool: String, _ values: JSONObject, caller: Int = 0, member: Int = 1) async throws -> JSONObject {
            var args = values; args["tool"] = tool; args["owner"] = UUID().uuidString; args["groupID"] = group.id.uuidString; args["memberID"] = members[member].id.uuidString; args["sessionID"] = sessions[caller].id
            return try await engine.mcpAction(args)
        }
        let colored = try await call("set_group_member_tab_color", ["color":"blue"])
        try expectEqual(colored["tabTitle"] as? String, "🔵 원래 이름"); try expectEqual(colored["colorMode"] as? String,"title_marker")
        _ = try await call("set_group_member_tab_color", ["color":"blue"])
        let renamed = try await call("set_group_member_title", ["title":"새 이름 'quoted' 🤖"])
        try expectEqual(renamed["tabTitle"] as? String, "🔵 새 이름 'quoted' 🤖")
        let reset = try await call("set_group_member_tab_color", ["color":"default"])
        try expectEqual(reset["tabTitle"] as? String, "새 이름 'quoted' 🤖")
        let customization = engine.snapshot.sessions.first { $0.id == sessions[1].id }?.customization
        try expectEqual(customization?.note,"keep note"); try expectEqual(customization?.title,"새 이름 'quoted' 🤖"); try expectNil(customization?.color)
        try expectEqual(fixture.counts(), [0,0,0]); try expectEqual(fixture.queries(),0,"Display edits must never send /status or CLI input, including during work")
        try expectEqual(fixture.labelCount(),4)
        for (tool,values) in [("set_group_member_tab_color",["color":"bad"]), ("set_group_member_title",["title":"bad\u{1b}input"]), ("set_group_member_title",["title":""])] {
            var rejected = false
            do { _ = try await call(tool, values) } catch { rejected = true }
            try expect(rejected,"Invalid appearance accepted")
        }
        for caller in [1,2] {
            do { _ = try await call("set_group_member_tab_color", ["color":"red"], caller: caller); throw AppError.message("Unauthorized appearance accepted") } catch let error as RemoteHTTPError { try expectEqual(error.status,403) }
        }
        do { _ = try await call("set_group_member_title", ["title":"outside"], member:2); throw AppError.message("Outside member renamed") } catch let error as RemoteHTTPError { try expectEqual(error.status,404) }
        try expectEqual(fixture.labelCount(),4)
        try expectNil(engine.snapshot.sessions.first { $0.id == sessions[0].id }?.customization)
        var named = group; named.members[1].nickname = "새 이름 'quoted' 🤖"
        try expectEqual(try SessionGroupStore(directory: directory).load()[0], named)
        // The same verified Claude member gains the exact role the Codex member has.
        let peers = group.addingLeader(members[1].id)
        try SessionGroupStore(directory: directory).save([peers])
        _ = try await call("set_group_member_title", ["title":"co-leader"], caller: 1, member: 0)
        let status = try await call("get_group_status", [:], caller: 1)
        let data = (status["groups"] as? [JSONObject])?.first
        try expectEqual(data?["leaderMemberIDs"] as? [String], peers.leaderMemberIDs.map(\.uuidString))
        try expectEqual((data?["members"] as? [JSONObject])?.filter { $0["isLeader"] as? Bool == true }.count, 2)
        try SessionGroupStore(directory: directory).save([peers.removingLeader(members[1].id)])
        do { _ = try await call("set_group_member_title", ["title":"revoked"], caller: 1, member: 0); throw AppError.message("Removed leader retained role") }
        catch let error as RemoteHTTPError { try expectEqual(error.status, 403) }

    }

    func testNativeTabLabelScriptsDoNotWriteInputOrChangeAppearance() throws {
        let title = "QA 'quote' \\\" 🤖"
        for host in [ScreenHost.terminal, .iterm] {
            let context = JSContext()!
            context.evaluateScript("""
            const chosen={tty:()=>'/dev/owned'}, other={tty:()=>'/dev/other'};
            function labelProperty(object,key,initial) { let value=initial; Object.defineProperty(object,key,{get:()=>()=>value,set:next=>{value=next;}}); }
            for(const item of [chosen,other]) {labelProperty(item,'customTitle','original'); labelProperty(item,'name','original');labelProperty(item,'titleDisplaysCustomTitle',false);}
            const nativeTab={sessions:()=>[other,chosen]};labelProperty(nativeTab,'title','original');
            const app={running:()=>true,windows:()=>[{tabs:()=>HOST==='terminal'?[other,chosen]:[nativeTab]}],activate:()=>{throw Error('focus changed')},doScript:()=>{throw Error('input written')}};
            function Application() {return app;}
            """.replacingOccurrences(of: "HOST", with: "'" + host.rawValue + "'"))
            let script = try TerminalTabLabelAdapter.script(host: host, tty:"/dev/owned",label:.init(title:title,color:"purple"))
            let output = context.evaluateScript(script)?.toString() ?? ""
            try expect(context.exception == nil, context.exception?.toString() ?? "Script failed")
            let result = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! JSONObject
            try expectEqual(result["title"] as? String,"🟣 " + title)
            try expectEqual(context.evaluateScript("other.name() + other.customTitle()")?.toString(),"originaloriginal")
            for forbidden in ["doScript(",".write(",".activate(","backgroundColor", "foregroundColor", "currentSettings", "selectedTab ="] { try expectFalse(script.contains(forbidden),forbidden) }
        }
        for title in ["", "bad\nline", "bad\u{2028}line", "bad\u{1b}code", String(repeating:"x",count:81)] { try expectThrows(try TerminalTabLabel(title:title).validated()) }
        try expectThrows(try TerminalTabLabel(title:"owned",color:"#ffffff").validated())
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
        let job = SessionGroupClearOperation(id: UUID(), groupID: group.id, callerMemberID: members[0].id, targets: [target], selectedMemberID: members[1].id)
        try AuditStore(path: paths.database).set("sessionGroupClearOperations", String(decoding: JSONEncoder().encode([job]), as: UTF8.self))
        let adapter = ScreenHostAdapter(screens: { targets in .init(screens: targets.map { .init(tty: $0.tty, contents: fixture.screen($0.tty)) }) }, approve: { _,_,_ in .missingTarget }, reveal: { _ in nil }, input: { try fixture.send($0, $3) })
        let engine = try ApprovalEngine(paths: paths, claudeRegistryReader: { records in records.filter { $0.agent == .claude }.map { .init(processID: $0.key, kind: "interactive", sessionID: fixture.id(0), status: "idle") } }, processReader: { fixture.records }, screenAdapters: [.iterm: adapter], codexGroupReader: { _ in .init(threadID: fixture.id(1), database: "/fixture/home/thread_history_1.sqlite") }, isolateByDefault: true, nativeKeyboardActivity: .inactive)
        defer { engine.stop() }; engine.groupClearInterval = 0.05
        await engine.connectScreenHost(.iterm)
        try engine.start(poll: false)
        // The production app starts before its asynchronous discovery returns.
        try await Task.sleep(for: .milliseconds(350))
        let stored = try AuditStore(path: paths.database).value("sessionGroupClearOperations")
        let undiscovered = try JSONDecoder().decode([SessionGroupClearOperation].self, from: Data((stored ?? "").utf8))
        try expectEqual(undiscovered, [job], "No expiry or resend before the first successful inventory")
        try expectEqual(fixture.counts(), [0,0,0])
        engine.updateDiscovery(sessions, records: fixture.records)
        var result: JSONObject = [:]
        for _ in 0..<100 {
            result = try await clearFixtureAction(engine,["owner": UUID().uuidString, "tool": "get_group_clear_status", "groupID": group.id.uuidString, "requestID": job.id.uuidString, "sessionID": sessions[0].id])
            if result["done"] as? Bool == true { break }; try await Task.sleep(for: .milliseconds(100))
        }
        try expectEqual(result["status"] as? String, didClear ? "completed" : "needs_review")
        try expectEqual(fixture.counts(), [0,0,0], "An uncertain pre-crash write must never be replayed")
        let queries = fixture.queries(); try await Task.sleep(for:.milliseconds(250))
        try expectEqual(fixture.queries(), queries, "A finished or uncertain reset must not accumulate status scripts")
        }
    }
}
