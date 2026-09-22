import Foundation
import AutoApproveCore

private let parentRecords = ProcessDiscovery.parse("""
1 0 ?? 1 0 Sat Sep 19 16:00:00 2026 /sbin/launchd
10 1 ?? 10 0 Sat Sep 19 16:00:01 2026 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
11 10 ttys032 11 12 Sat Sep 19 16:00:02 2026 /bin/zsh
12 11 ttys032 12 12 Sat Sep 19 16:38:43 2026 claude
13 10 ttys033 13 14 Sat Sep 19 16:00:04 2026 /bin/zsh
14 13 ttys033 14 14 Sat Sep 19 16:00:05 2026 claude
20 1 ?? 20 0 Sat Sep 19 16:55:10 2026 /Users/test/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude
21 20 ttys037 21 21 Sat Sep 19 16:55:12 2026 claude
22 20 ttys038 22 22 Sat Sep 19 16:55:13 2026 claude
""")
private let parentSessions = ProcessDiscovery.sessions(parentRecords)
private func fixtureSession(_ pid: Int32) -> AgentSession { parentSessions.first { $0.pid == pid }! }
private let mainID = fixtureSession(12).id
private let childID = fixtureSession(21).id
private let secondChildID = fixtureSession(22).id
private let parentRegistrations: [ClaudeSessionRegistration] = [
    .init(processID: mainID, kind: "interactive", parkedJobID: "ca35b27f"),
    .init(processID: childID, kind: "bg", jobID: "ca35b27f")
]
private let permissionQuestion: JSONObject = ["questions": [["header": "확인", "multiSelect": false,
    "question": "이 작업을 허용할까요?", "options": [["label": "거부"], ["label": "항상 허용"], ["label": "허용"]]]]]
private let manualQuestion: JSONObject = ["questions": [["question": "어느 환경을 검토할까요?",
    "options": [["label": "개발"], ["label": "운영"]]]]]
private func childPayload(_ pid: Int32 = 21, event: String = "PreToolUse", id: String = UUID().uuidString, manual: Bool = false) -> JSONObject {
    let session = fixtureSession(pid)
    return ["hook_event_name": event, "agentPID": pid, "agentStarted": session.started, "tty": session.tty,
        "cwd": "/tmp/same-project", "session_id": "provider-\(pid)", "requestID": id, "tool_use_id": id,
        "tool_name": "AskUserQuestion", "tool_input": manual ? manualQuestion : permissionQuestion]
}
@MainActor private func groupEngine(_ paths: AppPaths) throws -> ApprovalEngine {
    try ApprovalEngine(paths: paths, claudeRegistryReader: { _ in parentRegistrations }, processReader: { parentRecords })
}

extension ApprovalTests {
    func testClaudeRestoresWaitingBackgroundWithoutAHook() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-claude-recovery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(directory: root), engine = try groupEngine(paths)
        let store = try AuditStore(path: paths.database)
        try store.set("automatic:\(mainID)", "true")
        var registrations = parentRegistrations
        let date = Date().addingTimeInterval(-60)
        let summary = QuestionDetector.hookSummary(tool: "AskUserQuestion", input: permissionQuestion)
        registrations[1].activity = .init(providerID: "provider-21", status: "waiting", waitingFor: "input needed", changedAt: date, questionSummary: summary)
        engine.updateDiscovery(parentSessions, records: parentRecords, claudeRegistrations: registrations)
        var main = engine.snapshot.sessions.first { $0.id == mainID }!
        try expectEqual(main.phase, .input)
        try expectEqual(main.backgroundChildren.first?.pendingSummary, summary)
        try expectEqual(AttentionRequest.candidates(main, paused: false).count, 1)
        try expect(main.automatic)
        try expect(main.activityDetail?.contains("이번 요청은 터미널에서") == true)
        try expect(engine.snapshot.events.isEmpty, "Restoring metadata must not fabricate a reply")
        try await Task.sleep(nanoseconds: 900_000_000); engine.refreshNotices()
        try expectEqual(engine.snapshot.sessions.first { $0.id == mainID }?.unreadNoticeCount, 1)
        try engine.markNotificationsRead(mainID)
        let restarted = try groupEngine(paths)
        restarted.updateDiscovery(parentSessions, records: parentRecords, claudeRegistrations: registrations)
        try expectEqual(restarted.snapshot.sessions.first { $0.id == mainID }?.phase, .input)
        try expectEqual(restarted.snapshot.sessions.first { $0.id == mainID }?.unreadNoticeCount, 0)
        // A fresh supported hook still answers through the actual child and parent's ON policy.
        try expect(!engine.handleHook(childPayload(id: "next-question")).isEmpty)
        engine.updateDiscovery(parentSessions, records: parentRecords, claudeRegistrations: registrations)
        main = engine.snapshot.sessions.first { $0.id == mainID }!
        try expectEqual(main.backgroundChildren.first?.phase, .working)
        try expect(main.backgroundChildren.first?.pendingSummary == nil, "An old waiting snapshot cannot reopen an answered hook")
        try expectEqual(engine.snapshot.events.first?.answer, "허용")
        _ = engine.handleHook(childPayload(id: "fresh-manual", manual: true))
        registrations[1].activity?.changedAt = Date()
        registrations[1].activity?.questionSummary = nil
        engine.updateDiscovery(parentSessions, records: parentRecords, claudeRegistrations: registrations)
        let fresh = engine.snapshot.sessions.first { $0.id == mainID }!.backgroundChildren.first!
        try expectEqual(fresh.pendingSummary, QuestionDetector.hookSummary(tool: "AskUserQuestion", input: manualQuestion))
        try expectEqual(fresh.pendingRequestID, "hook:provider-21:fresh-manual", "A later waiting status must not duplicate the hook's question")
        try expect(fresh.activityDetail?.contains("복원") != true)
        registrations[1].activity?.questionSummary = summary
        engine.updateDiscovery(parentSessions, records: parentRecords, claudeRegistrations: registrations)
        let replaced = engine.snapshot.sessions.first { $0.id == mainID }!.backgroundChildren.first!
        try expectEqual(replaced.pendingSummary, summary, "A different current question must still be recovered when its hook was missed")
        try expect(replaced.pendingRequestID?.hasPrefix("claude-state:") == true)
    }

    func testClaudeRecoveredWaitingTransitionsAndUnavailableMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-claude-state-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try groupEngine(AppPaths(directory: root))
        var registrations = parentRegistrations
        func update(_ status: String, _ waiting: String? = nil) {
            registrations[1].activity = .init(providerID: "provider-21", status: status, waitingFor: waiting, changedAt: Date())
            engine.updateDiscovery(parentSessions, records: parentRecords, claudeRegistrations: registrations)
        }
        update("waiting", "permission prompt")
        try expectEqual(engine.snapshot.sessions.first { $0.id == mainID }?.phase, .approval)
        try expectEqual(AttentionRequest.candidates(engine.snapshot.sessions.first { $0.id == mainID }!, paused: false).count, 1)
        update("busy")
        try expectNil(engine.snapshot.sessions.first { $0.id == mainID }?.backgroundChildren.first?.pendingSummary)
        try expectEqual(engine.snapshot.sessions.first { $0.id == mainID }?.phase, .working)
        update("idle")
        try expectEqual(engine.snapshot.sessions.first { $0.id == mainID }?.phase, .idle)
        update("waiting", "dialog open")
        try expectEqual(engine.snapshot.sessions.first { $0.id == mainID }?.phase, .input)
        engine.updateDiscovery(parentSessions, records: parentRecords, claudeRegistrations: parentRegistrations)
        try expectEqual(engine.snapshot.sessions.first { $0.id == mainID }?.phase, .unknown)
        try expectNil(engine.snapshot.sessions.first { $0.id == mainID }?.backgroundChildren.first?.pendingSummary)
        update("waiting", "input needed")
        engine.updateDiscovery(parentSessions.filter { $0.id != childID }, records: parentRecords.filter { $0.pid != 21 }, claudeRegistrations: registrations)
        try expectEqual(engine.snapshot.sessions.first { $0.id == mainID }?.backgroundChildren.count, 0)
        try expect(engine.snapshot.events.isEmpty)
    }

    func testClaudeRecoveryMetadataIdentityAndStaleness() throws {
        let process = parentRecords.first { $0.pid == 21 }!
        let changed = Date().addingTimeInterval(-60)
        let registry: JSONObject = ["pid": 21, "pidDomain": "darwin", "procStart": "Sat Sep 19 07:55:12 2026",
            "kind": "bg", "jobId": "ca35b27f", "sessionId": "provider-21", "status": "waiting", "waitingFor": "input needed",
            "statusUpdatedAt": changed.timeIntervalSince1970 * 1000]
        let decoded = ClaudeSessionRegistry.decode(try JSONSerialization.data(withJSONObject: registry), process: process, processTimeZone: TimeZone(identifier: "Asia/Seoul")!)!
        try expectEqual(decoded.activity?.status, "waiting")
        let activity = decoded.activity!
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let valid: JSONObject = ["daemonShort": "ca35b27f", "backend": "daemon", "state": "working", "tempo": "blocked",
            "sessionId": "job-conversation", "resumeSessionId": "provider-21", "updatedAt": formatter.string(from: changed.addingTimeInterval(1)), "block": permissionQuestion]
        func summary(_ json: JSONObject) throws -> String? {
            ClaudeSessionRegistry.questionSummary(try JSONSerialization.data(withJSONObject: json), jobID: "ca35b27f", activity: activity)
        }
        try expectEqual(try summary(valid), QuestionDetector.hookSummary(tool: "AskUserQuestion", input: permissionQuestion))
        for (key, value) in [("daemonShort", "another-job"), ("resumeSessionId", "another-conversation"), ("state", "done"),
                             ("tempo", "flowing"), ("backend", "peer"), ("updatedAt", formatter.string(from: changed.addingTimeInterval(-1)))] {
            var invalid = valid; invalid[key] = value
            try expect(try summary(invalid) == nil, "Reject mismatched or stale \(key)")
        }
        var invalid = valid; invalid["block"] = ["questions": [["question": "incomplete", "options": [["label": ""]]]]]
        try expectNil(try summary(invalid))
        var invalidRegistry = registry; invalidRegistry["statusUpdatedAt"] = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        let future = ClaudeSessionRegistry.decode(try JSONSerialization.data(withJSONObject: invalidRegistry), process: process, processTimeZone: TimeZone(identifier: "Asia/Seoul")!)
        try expectNotNil(future, "Bad activity must not discard a valid parent relationship")
        try expectNil(future?.activity)
        // Exercise the actual bounded filesystem reader, including degraded question metadata.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-claude-registry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("jobs/ca35b27f"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: registry).write(to: directory.appendingPathComponent("sessions/21.json"))
        try JSONSerialization.data(withJSONObject: valid).write(to: directory.appendingPathComponent("jobs/ca35b27f/state.json"))
        // Convert fixture ps lstart to the host zone, just as ProcessDiscovery does.
        var localProcess = process
        let psFormatter = DateFormatter(); psFormatter.locale = Locale(identifier: "en_US_POSIX"); psFormatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        psFormatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        let started = psFormatter.date(from: process.started)!
        psFormatter.timeZone = ProcessInfo.processInfo.environment["TZ"].flatMap(TimeZone.init(identifier:)) ?? .current
        localProcess.started = psFormatter.string(from: started)
        try expect(ClaudeSessionRegistry.read(records: [localProcess], directory: directory).first?.activity?.questionSummary?.contains("항상 허용") == true)
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("jobs/ca35b27f/state.json"))
        let fallback = ClaudeSessionRegistry.read(records: [localProcess], directory: directory).first
        try expectEqual(fallback?.activity?.status, "waiting")
        try expectNil(fallback?.activity?.questionSummary)
    }

    func testClaudeRegistryIdentityAndExactParent() throws {
        let process = parentRecords.first { $0.pid == 12 }!
        var json: JSONObject = ["pid": 12, "pidDomain": "darwin", "procStart": "Sat Sep 19 07:38:43 2026",
            "kind": "interactive", "parkedJobId": "ca35b27f"]
        func decode() throws -> ClaudeSessionRegistration? {
            ClaudeSessionRegistry.decode(try JSONSerialization.data(withJSONObject: json), process: process,
                processTimeZone: TimeZone(identifier: "Asia/Seoul")!)
        }
        try expectEqual(try decode()?.processID, mainID)
        json["pid"] = 99; try expectNil(try decode())
        json["pid"] = 12; json["procStart"] = "Sat Sep 19 07:38:44 2026"; try expectNil(try decode())
        json["procStart"] = "Sat Sep 19 07:38:43 2026"; json["pidDomain"] = "linux"; try expectNil(try decode())
        let mapped = ClaudeSessionRegistry.parents(sessions: parentSessions, records: parentRecords, registrations: parentRegistrations)
        try expectEqual(mapped, [childID: mainID], "Daemon reparenting must retain the parked main terminal")
        try expect(ClaudeSessionRegistry.parents(sessions: parentSessions, records: parentRecords, registrations: []).isEmpty,
            "Identical projects and one daemon are not parent evidence")
        let ambiguous = parentRegistrations + [.init(processID: fixtureSession(14).id, kind: "interactive", parkedJobID: "ca35b27f")]
        try expect(ClaudeSessionRegistry.parents(sessions: parentSessions, records: parentRecords, registrations: ambiguous).isEmpty)
        var direct = parentRecords
        direct[direct.firstIndex { $0.pid == 20 }!].parent = 12
        let directParents = ClaudeSessionRegistry.parents(sessions: ProcessDiscovery.sessions(direct), records: direct, registrations: [])
        try expectEqual(directParents, [childID: mainID, secondChildID: mainID])
    }

    func testBackgroundHookInheritsMainAndAuditsOrigin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-parent-policy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(directory: root), engine = try groupEngine(paths)
        let store = try AuditStore(path: paths.database)
        try store.set("automatic:\(childID)", "true")
        engine.updateDiscovery(parentSessions, records: parentRecords)
        try expect(engine.handleHook(childPayload(id: "off")).isEmpty, "Main OFF overrides a child's previously saved ON")
        try expectEqual(engine.snapshot.sessions.filter { $0.phase != .ended }.count, 3)
        try expect(!engine.snapshot.sessions.contains { $0.id == childID })
        let main = engine.snapshot.sessions.first { $0.id == mainID }!
        try expect(main.canApprove, "A child hook connects the group's approval switch")
        try expectEqual(main.phase, .input)
        try expectEqual(main.backgroundChildren.first?.pendingRequestID, "hook:provider-21:off")
        try expect(main.matchesSearch("ttys037"))
        try engine.setAutomatic(mainID, enabled: true)
        let response = engine.handleHook(childPayload(id: "allowed"))
        let output = response["hookSpecificOutput"] as? JSONObject
        let updated = output?["updatedInput"] as? JSONObject
        try expectEqual(updated?["answers"] as? [String: String], ["이 작업을 허용할까요?": "허용"])
        try expect(engine.handleHook(childPayload(event: "PermissionRequest", id: "allowed")).isEmpty)
        let audit = engine.snapshot.events.first { $0.answer == "허용" }!
        try expectEqual(audit.sessionID, mainID)
        try expectEqual(audit.originSessionID, childID)
        try expectEqual(audit.context?.tty, "/dev/ttys037")
        try expectEqual(audit.context?.pid, 21)
        try expectEqual(store.value("automatic:\(childID)"), "true", "Inheritance does not rewrite independent preferences")
        try engine.setPaused(true)
        try expect(engine.handleHook(childPayload(id: "paused")).isEmpty)
        try engine.setPaused(false)
        var permission = childPayload(event: "PermissionRequest", id: "bash")
        permission["tool_name"] = "Bash"; permission["tool_input"] = ["command": "echo fixture"]
        try expect(!engine.handleHook(permission).isEmpty, "General permissions use the same parent policy")
        try engine.setAutomatic(mainID, enabled: false)
        permission["requestID"] = "off-bash"
        try expect(engine.handleHook(permission).isEmpty)
    }

    func testGroupedQuestionsNoticesAndReadPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-parent-notices-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(directory: root)
        var records = parentRecords
        records[records.firstIndex { $0.pid == 20 }!].parent = 12
        let liveRecords = records
        let engine = try ApprovalEngine(paths: paths, claudeRegistryReader: { _ in [] }, processReader: { liveRecords })
        engine.updateDiscovery(ProcessDiscovery.sessions(records), records: records)
        for pid: Int32 in [12, 21, 22] { _ = engine.handleHook(childPayload(pid, id: "same", manual: true)) }
        var main = engine.snapshot.sessions.first { $0.id == mainID }!
        try expectEqual(main.backgroundChildren.count, 2)
        try expectEqual(AttentionRequest.candidates(main, paused: false).count, 3, "Concurrent equal text must not overwrite or deduplicate another process")
        var tracker = AttentionTracker()
        let requests = tracker.update(engine.snapshot)
        try expectEqual(requests.count, 3)
        try expect(requests.allSatisfy { $0.sessionID == mainID })
        try expectEqual(Set(requests.compactMap(\.originSessionID)), Set([mainID, childID, secondChildID]))
        try expectEqual(try AttentionRequest.target(sessionID: requests[0].sessionID, sessions: engine.snapshot.sessions).id, mainID)
        try expectEqual(try AttentionRequest.target(sessionID: childID, sessions: engine.snapshot.sessions).id, mainID,
            "An existing child notification opens its verified main after grouping")
        try await Task.sleep(nanoseconds: 900_000_000)
        engine.refreshNotices()
        main = engine.snapshot.sessions.first { $0.id == mainID }!
        try expectEqual(main.unreadNoticeCount, 3)
        try engine.markNotificationsRead(mainID)
        try expectEqual(engine.snapshot.sessions.first { $0.id == mainID }?.unreadNoticeCount, 0)
        try expect(requests.allSatisfy { engine.isNotificationRead(sessionID: $0.originSessionID!, sourceKey: $0.notificationKey) })
        _ = engine.handleHook(childPayload(12, event: "UserPromptSubmit", manual: true))
        try expectEqual(AttentionRequest.candidates(engine.snapshot.sessions.first { $0.id == mainID }!, paused: false).count, 2,
            "Main activity cannot erase child questions")
        _ = engine.handleHook(childPayload(21, event: "PostToolUse"))
        var completion = childPayload(21, event: "Stop")
        completion["last_assistant_message"] = "검토 완료"
        _ = engine.handleHook(completion)
        let completed = AttentionRequest.completions(engine.snapshot)
        try expectEqual(completed.first?.sessionID, mainID)
        try expectEqual(completed.first?.originSessionID, childID)
        try expectEqual(engine.snapshot.sessions.first { $0.id == mainID }?.phase, .input, "The second child's question still needs review")
        let restarted = try ApprovalEngine(paths: paths, claudeRegistryReader: { _ in [] }, processReader: { liveRecords })
        restarted.updateDiscovery(ProcessDiscovery.sessions(records), records: records)
        try expectEqual(restarted.snapshot.sessions.first { $0.id == mainID }?.backgroundChildren.count, 2)
        try expectEqual(restarted.snapshot.sessions.first { $0.id == mainID }?.unreadNoticeCount, 0)
    }

    func testBackgroundFirstHookRestartAndParentExit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-parent-lifecycle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(directory: root), engine = try groupEngine(paths)
        let store = try AuditStore(path: paths.database)
        try store.set("automatic:\(mainID)", "true")
        try store.set("automatic:\(childID)", "true")
        try expect(!engine.handleHook(childPayload(id: "early")).isEmpty, "First hook discovers the main and restores its policy")
        try expectEqual(engine.snapshot.events.first?.sessionID, mainID)
        let restarted = try groupEngine(paths)
        try expect(!restarted.handleHook(childPayload(id: "restart")).isEmpty)
        let orphanRecords = parentRecords.filter { $0.pid != 12 }
        let orphan = try ApprovalEngine(paths: paths, claudeRegistryReader: { _ in [] }, processReader: { orphanRecords })
        try expect(orphan.handleHook(childPayload(id: "orphan")).isEmpty)
        try expectEqual(orphan.snapshot.sessions.first { $0.id == childID }?.automatic, false)
        var reusedRecords = orphanRecords
        var reused = parentRecords.first { $0.pid == 12 }!
        reused.started = "Sat Sep 19 17:38:43 2026"; reusedRecords.append(reused)
        orphan.updateDiscovery(ProcessDiscovery.sessions(reusedRecords), records: reusedRecords)
        try expect(orphan.snapshot.sessions.contains { $0.id == childID }, "A reused main PID and TTY cannot inherit the old relationship")
        try expectEqual(orphan.snapshot.sessions.first { $0.id == childID }?.automatic, false)
        try orphan.setAutomatic(childID, enabled: true)
        try expect(!orphan.handleHook(childPayload(id: "independent")).isEmpty)
    }

    func testParentScreenCannotDuplicateChildHook() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-parent-screen-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try groupEngine(AppPaths(directory: root))
        var found = parentSessions
        found[found.firstIndex { $0.id == mainID }!].channel = .terminalScreen
        engine.updateDiscovery(found, records: parentRecords)
        _ = engine.handleHook(childPayload(manual: true))
        let before = engine.snapshot.sessions.first { $0.id == mainID }!
        let screen = "Do you want to proceed?\n❯ 1. Yes\n  2. No\nEsc to cancel"
        engine.receiveScreen(sessionID: mainID, raw: screen, generation: "mirror", source: .terminalScreen)
        let after = engine.snapshot.sessions.first { $0.id == mainID }!
        try expectEqual(after.backgroundChildren, before.backgroundChildren)
        try expectNil(after.pendingSummary)
        try expectEqual(AttentionRequest.candidates(after, paused: false).count, 1)
    }

    func testParentGroupingAndReadSaveFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-parent-save-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(directory: root), engine = try groupEngine(paths)
        _ = engine.handleHook(childPayload(manual: true))
        _ = engine.handleHook(childPayload(12, manual: true))
        try await Task.sleep(nanoseconds: 900_000_000); engine.refreshNotices()
        let before = engine.snapshot.sessions.first { $0.id == mainID }!.unreadNoticeCount
        _ = try CommandRunner.run("/usr/bin/sqlite3", [paths.database,
            "CREATE TRIGGER fail_parent_read BEFORE INSERT ON settings WHEN NEW.key = 'inbox:\(mainID)' BEGIN SELECT RAISE(ABORT, 'fixture'); END;"])
        try expectThrows(try engine.markNotificationsRead(mainID))
        try expectEqual(engine.snapshot.sessions.first { $0.id == mainID }?.unreadNoticeCount, before)
        let restored = try groupEngine(paths)
        restored.updateDiscovery(parentSessions, records: parentRecords)
        try expectEqual(restored.snapshot.sessions.first { $0.id == mainID }?.unreadNoticeCount, before, "Read receipts commit together")
        _ = try CommandRunner.run("/usr/bin/sqlite3", [paths.database, "DROP TABLE settings"])
        let failed = try ApprovalEngine(paths: paths, claudeRegistryReader: { _ in [] }, processReader: { parentRecords })
        var connected = parentSessions
        connected[connected.firstIndex { $0.id == mainID }!].channel = .hook
        failed.updateDiscovery(connected, records: parentRecords, claudeRegistrations: [])
        try failed.setAutomatic(mainID, enabled: true)
        // Break storage after enabling the main, before the first relationship is saved.
        _ = try CommandRunner.run("/usr/bin/sqlite3", [paths.database, "DROP TABLE settings"])
        failed.updateDiscovery(connected, records: parentRecords, claudeRegistrations: parentRegistrations)
        try expect(failed.handleHook(childPayload()).isEmpty)
        try expect(failed.snapshot.sessions.first { $0.id == mainID }?.detail.contains("저장하지 못해") == true)
    }
}
