import Foundation
import AutoApproveCore

private final class ProfileReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var reading = 0
    private var maximum = 0
    private var visits: [String] = []
    var peak: Int { lock.withLock { maximum } }
    var reads: [String] { lock.withLock { visits } }

    func read(_ id: String) {
        lock.withLock { reading += 1; maximum = max(maximum, reading); visits.append(id) }
        Thread.sleep(forTimeInterval: 0.02)
        lock.withLock { reading -= 1 }
    }
}

extension ApprovalTests {
    func testGroupPolicyUsesCorroboratedTerminal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("""
        993900 1 ttys990 993900 993901 Wed Oct 28 22:00:00 2026 /bin/zsh
        993901 993900 ttys990 993901 993901 Wed Oct 28 22:01:00 2026 /fixture/codex
        """)
        let tab = UUID().uuidString, path = directory.path
        let engine = try ApprovalEngine(paths: .init(directory: directory), processReader: { records },
            codexGroupReader: { _ in nil }, codexGroupEnvironment: { _ in ["TERM_SESSION_ID":tab, "CODEX_HOME":path] }, isolateByDefault: true)
        defer { engine.stop() }
        var session = ProcessDiscovery.sessions(records)[0]
        session.terminal = .terminal; session.cwd = path
        engine.updateDiscovery([session], records: records)
        var rows = try await engine.sessionGroupSessions()
        var member = rows[0].member
        member.conversationID = UUID().uuidString.lowercased()
        try expectNotNil(member.tabShell)
        try expectNil(SessionGroupMatching.match(member, in: rows))
        let group = SessionGroup(name:"Policy",members:[member])
        try SessionGroupStore(directory:directory).save([group])
        try expectEqual(try await engine.applyGroupOSPermissions(group,kinds:[.camera],allow:true).first?.outcome,.changed)
        try expectEqual(engine.snapshot.sessions.first?.osPermissionPolicy?.allowed,[.camera])
        var unanchored = member; unanchored.tabShell = nil
        try expectNil(SessionGroupMatching.policySession(unanchored,in:rows))
        var other = rows[0]; other.session.id = "different"; other.conversationID = member.conversationID
        try expectNil(SessionGroupMatching.policySession(member,in:rows+[other]))
        rows[0].conversationID = UUID().uuidString
        try expectNil(SessionGroupMatching.policySession(member,in:rows))
        rows[0].conversationID = nil; rows[0].providerHome = "/other"
        try expectNil(SessionGroupMatching.policySession(member,in:rows))
    }

    func testSelectedProfileUsesBoundedMetadataReads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let records = ProcessDiscovery.parse((0..<12).map { "9939\(10+$0) 1 ttys\(900+$0) 1 1 Wed Oct 28 22:00:00 2026 /fixture/codex" }.joined(separator:"\n"))
        let ids = Dictionary(uniqueKeysWithValues:records.map { ($0.pid,UUID().uuidString.lowercased()) })
        let counter = ProfileReadCounter()
        let engine = try ApprovalEngine(paths:.init(directory:directory),processReader:{records},
            codexGroupReader:{ row in
                counter.read(row.key)
                return .init(threadID:ids[row.pid]!,database:"/fixture/home/state_5.sqlite")
            }, profileExecutionSettingsReader:{ live in
                counter.read(live.id)
                return .init(model:"model",reasoningEffort:"high",serviceTier:"default")
            }, isolateByDefault:true)
        defer { engine.stop() }
        engine.updateDiscovery(ProcessDiscovery.sessions(records),records:records)
        let selected = Set(records.prefix(8).map(\.key))
        async let save = engine.terminalProfileCandidates(includeLayout:false,refreshForSaving:true,sessionIDs:selected)
        async let restore = engine.terminalProfileCandidates(includeLayout:false,sessionIDs:selected)
        let (saved, active) = try await (save,restore)
        try expectEqual(Set(saved.map(\.id)),selected); try expectEqual(saved.map(\.id),active.map(\.id))
        try expectEqual(saved.map(\.entry.conversationID),active.map(\.entry.conversationID))
        try expect(saved.allSatisfy { $0.entry.executionSettings?.reasoningEffort == "high" })
        try expect(active.allSatisfy { $0.entry.executionSettings == nil })
        try expectEqual(counter.reads.count,selected.count*3)
        try expectEqual(Set(counter.reads), selected)
        try expect((2...4).contains(counter.peak))
    }

    func testRestoreChecksAllReceiptsWithOneSnapshot() async throws {
        let entries = (0..<4).map { TerminalProfileEntry(title:"tab \($0)",agent:"codex",cwd:"/tmp",conversationID:UUID().uuidString.lowercased(),host:.terminal) }
        let profile = TerminalSessionProfile(name:"Receipts",entries:entries), selected = Set(entries.map(\.id))
        let restorer = TerminalProfileRestorer(), counter = ProfileReadCounter()
        let ttys = Dictionary(uniqueKeysWithValues:entries.enumerated().map { ($1.id,"/dev/ttys\(981+$0)") })
        _ = try await restorer.restore(profile,selected:selected,active:[],launch:{ entry,_ in ttys[entry.id]! })
        let results = try await restorer.restore(profile,selected:selected,active:[],openTerminalTTYs:{
            counter.read("snapshot")
            return Set(ttys.values)
        },launch:{ _,_ in throw AppError.message("Duplicate launch") })
        try expectEqual(counter.reads,["snapshot"]); try expect(results.allSatisfy { $0.phase == .alreadyOpen })
    }

    func testGroupGoalNotifiesAncestorBeforeResume() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = ProcessDiscovery.parse("993901 1 ttys990 993901 993901 Wed Oct 28 22:00:00 2026 /fixture/codex")[0]
        let sends = ProfileReadCounter()
        let adapter = ScreenHostAdapter(screens:{_ in .init()},approve:{_,_,_ in .sent},reveal:{_ in nil},
            resume:{_,_,text in sends.read(text); return .sent},completeResume:{_,_ in sends.read("enter"); return .sent})
        let leader = SessionGroupMember(agent:.claude,title:"leader",cwd:"/tmp",conversationID:UUID().uuidString)
        let parent = SessionGroupMember(agent:.claude,title:"member",cwd:"/tmp",conversationID:UUID().uuidString)
        var worker = SessionGroupMember(agent:.codex,title:"worker",cwd:"/tmp",conversationID:UUID().uuidString)
        worker.runtimeID = record.key; worker.parentMemberID = parent.id
        let group = SessionGroup(name:"Nested",members:[leader,parent,worker],leaderMemberID:leader.id)
        try expect(group.canManageGoal(leader.id,member:worker.id))
        try expect(!group.canManageGoal(parent.id,member:worker.id))
        var branch = group.addingLeader(parent.id)
        branch.members[1].parentMemberID = leader.id
        try expect(branch.canManageGoal(parent.id,member:worker.id))
        try expect(!branch.canManageGoal(leader.id,member:worker.id))
        let store = SessionGroupStore(directory:directory), box = try SessionGroupMailbox(directory:directory)
        func start() throws -> ApprovalEngine {
            let engine = try ApprovalEngine(paths:.init(directory:directory),processReader:{[record]},
                screenAdapters:[.terminal:adapter],isolateByDefault:true)
            var live = AgentSession(id:record.key,agent:.codex,pid:record.pid,started:record.started,tty:"/dev/"+record.tty,cwd:"/tmp",terminal:.terminal)
            live.channel = .terminalScreen; engine.updateDiscovery([live],records:[record]); engine.goalBlockedResumeDelays = [0.08]
            try engine.setAutomatic(record.key,enabled:true)
            return engine
        }
        let frame = "• Waiting for build approval.\n\n› Ask Codex to do anything\n\n? for shortcuts · Goal stalled (/goal resume)"
        func notices() throws -> [SessionGroupMessage] { try box.list(groupID:group.id,memberID:leader.id,includeAcknowledged:true).filter { $0.kind == .notice } }
        let engine = try start(); defer { engine.stop() }
        engine.receiveScreen(sessionID:record.key,raw:frame,generation:"first")
        try store.save([group])
        try await Task.sleep(for:.milliseconds(220))
        let notice = try notices().first
        try expectEqual(notice?.senderID,worker.id); try expectEqual(notice?.recipientID,leader.id)
        try expect(notice?.text.contains("Waiting for build approval.") == true)
        try expectEqual(sends.reads,[])
        if let notice { try box.acknowledge([notice.id],groupID:group.id,recipientID:leader.id) }
        engine.stop()
        let reopened = try start(); defer { reopened.stop() }
        let draft = frame.replacingOccurrences(of:"› Ask Codex to do anything",with:"› /goal resume")
        reopened.receiveScreen(sessionID:record.key,raw:draft,generation:"draft")
        reopened.receiveScreen(sessionID:record.key,raw:frame,generation:"unchanged")
        try await Task.sleep(for:.milliseconds(180))
        try expectEqual(try notices().count,1); try expectEqual(sends.reads,[])
    }

    func testRootGoalRecoversAfterDependencyClears() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = ProcessDiscovery.parse("993901 1 ttys990 993901 993901 Wed Oct 28 22:00:00 2026 /fixture/codex")[0]
        let thread = UUID().uuidString.lowercased(), home = "/fixture/home"
        var leader = SessionGroupMember(agent: .codex, title: "leader", cwd: "/project", conversationID: thread, providerHome: home)
        leader.runtimeID = record.key
        let parent = SessionGroupMember(agent: .claude, title: "other leader", cwd: "/project", conversationID: UUID().uuidString)
        let group = SessionGroup(name: "Leaders", members: [leader, parent], leaderMemberID: parent.id).addingLeader(leader.id)
        let store = SessionGroupStore(directory: directory)
        try store.save([group])
        let sends = ProfileReadCounter()
        let adapter = ScreenHostAdapter(screens: { _ in .init() }, approve: { _,_,_ in .sent }, reveal: { _ in nil },
            resume: { _,_,text in sends.read(text); return .sent })
        func start() throws -> ApprovalEngine {
            let engine = try ApprovalEngine(paths: .init(directory: directory), processReader: { [record] },
                screenAdapters: [.terminal: adapter],
                codexGroupReader: { _ in .init(threadID: thread, database: home + "/thread_history_1.sqlite") },
                isolateByDefault: true)
            var session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started,
                tty: "/dev/" + record.tty, cwd: "/project", terminal: .terminal)
            session.channel = .terminalScreen
            engine.updateDiscovery([session], records: [record])
            engine.goalBlockedResumeDelays = [0.04]
            try engine.setAutomatic(record.key, enabled: true)
            return engine
        }
        let engine = try start()
        defer { engine.stop() }
        let waitID = UUID().uuidString
        let args: JSONObject = ["groupID": group.id.uuidString, "sessionID": record.key, "owner": UUID().uuidString, "waitID": waitID]
        let waiting = try await engine.mcpAction(args.merging(["tool": "wait_group_dependencies", "external": true]) { _, new in new })
        try expectEqual(waiting["state"] as? String, "waiting")
        let frame = "• Checking progress.\n\n› Ask Codex to do anything\n\n? for shortcuts · Goal stalled (/goal resume)"
        let box = try SessionGroupMailbox(directory: directory)
        func notices(_ member: UUID) throws -> [SessionGroupMessage] {
            try box.list(groupID: group.id, memberID: member, includeAcknowledged: true).filter { $0.kind == .notice }
        }
        engine.receiveScreen(sessionID: record.key, raw: frame, generation: "waiting")
        try expectNil(engine.snapshot.sessions.first?.capacityResume)
        try expectEqual(try notices(leader.id).count, 0)
        let cancelled = try await engine.mcpAction(args.merging(["tool": "update_group_wait", "action": "cancel"]) { _, new in new })
        try expectEqual(cancelled["state"] as? String, "cancelled")
        engine.receiveScreen(sessionID: record.key, raw: frame, generation: "cleared")
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while engine.snapshot.sessions.first?.interruption?.resumeConfirmedAt == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try expectEqual(sends.reads, ["/goal resume"])
        try expectNotNil(engine.snapshot.sessions.first?.interruption?.resumeConfirmedAt)
        try expectEqual(try notices(leader.id).count, 0)
        try expectEqual(try notices(parent.id).count, 0)
        engine.stop()
        let reopened = try start()
        defer { reopened.stop() }
        reopened.receiveScreen(sessionID: record.key, raw: frame, generation: "restarted")
        try await Task.sleep(for: .milliseconds(120))
        try expectEqual(sends.reads, ["/goal resume"])
        let next = "• New failed attempt.\n\n" + frame
        reopened.receiveScreen(sessionID: record.key, raw: next, generation: "new")
        try expectEqual(reopened.snapshot.sessions.first?.capacityResume?.phase, .scheduled)
        reopened.cancelCapacityResume(record.key)
        reopened.stop()
        let afterCancel = try start()
        defer { afterCancel.stop() }
        afterCancel.receiveScreen(sessionID: record.key, raw: next, generation: "cancelled")
        try await Task.sleep(for: .milliseconds(120))
        try expectEqual(sends.reads, ["/goal resume"])
        try store.save([try group.linkingParent(parent.id, to: leader.id, connected: true)])
        afterCancel.receiveScreen(sessionID: record.key, raw: next, generation: "nested")
        try expectEqual(try notices(parent.id).first?.senderID, leader.id)
        try expectEqual(try notices(leader.id).count, 0)
        try expectEqual(sends.reads, ["/goal resume"])
    }

    func testLegacyGoalSelfNoticesLeavePendingInbox() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = try SessionGroupMailbox(directory: directory)
        let group = UUID(), leader = UUID(), worker = UUID()
        func enqueue(_ sender: UUID, key: String?) throws -> SessionGroupMessage {
            try box.enqueue(groupID: group, senderID: sender, recipientID: leader, kind: .notice, text: "fixture", sourceKey: key)
        }
        func source(_ sender: UUID) -> String {
            "goalBlocked:" + [group, sender, leader, UUID()].map(\.uuidString).joined(separator: ":")
        }
        let obsolete = try enqueue(leader, key: source(leader))
        let child = try enqueue(worker, key: source(worker))
        let ordinary = try enqueue(leader, key: nil)
        let reopened = try SessionGroupMailbox(directory: directory)
        try expectEqual(try reopened.message(obsolete.id)?.lastResult, "superseded")
        try expectEqual(Set(try reopened.list(groupID: group, memberID: leader).map(\.id)), [child.id, ordinary.id])
    }
}
