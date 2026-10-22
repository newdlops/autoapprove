import Foundation
import AutoApproveCore

private let safetyRecords = ProcessDiscovery.parse("""
1 0 ?? 1 0 Tue Oct 13 09:00:00 2026 /sbin/launchd
20 1 ?? 20 0 Tue Oct 13 09:00:00 2026 /fixture/iTerm2/iTermServer
40 20 ttys980 40 41 Tue Oct 13 09:00:00 2026 /bin/zsh
41 40 ttys980 41 41 Tue Oct 13 09:00:00 2026 codex
50 20 ttys981 50 51 Tue Oct 13 09:00:00 2026 /bin/zsh
51 50 ttys981 51 51 Tue Oct 13 09:00:00 2026 claude
""")
private let safetyCodex = safetyRecords.first { $0.pid == 41 }!
private let safetyClaude = safetyRecords.first { $0.pid == 51 }!
private func safetyPrompt(_ command: String = "cp artifacts/report.plist ~/Library/LaunchAgents/com.fixture.hourly.plist") -> String {
    "Would you like to run the following command?\n\nReason: fixture command review\n\n$ " + command + "\n\n› 1. Yes, proceed (y)\n  2. No, and tell Codex what to do differently (esc)\n\nPress enter to confirm or esc to cancel"
}
private func safetyReady(_ agent: AgentKind = .codex, body: String = "") -> String {
    "Synthetic original conversation\n\n" + (agent == .codex ? "› " : "❯ ") + body + "\n\n" + (agent == .codex ? "fixture-model · /fixture · 90% context left\n? for shortcuts" : "? for shortcuts")
}
private final class SafetyProbe: @unchecked Sendable {
    private let lock = NSLock()
    var screen = safetyPrompt(), records = safetyRecords
    var inputs: [RemoteTerminalInput] = [], approvals = 0, newlineFirst = false, userDraft = false, uncertain = false
    var afterCancel: (() -> Void)?
    var validationOnly = false
    private var validationReads = 0
    var validationReadCount: Int { lock.withLock { validationReads } }
    var counts: [Int] { lock.withLock { [inputs.filter { $0.kind == .escape }.count, inputs.filter { $0.kind == .characters }.count, inputs.filter { $0.kind == .enter }.count, approvals] } }
    func read() -> String { lock.withLock { screen } }
    func processes() -> [ProcessRecord] { lock.withLock { records } }
    func write(_ expected: String, _ input: RemoteTerminalInput) throws -> TerminalDelivery {
        try lock.withLock {
            guard screen == expected else { return .screenChanged }
            inputs.append(input)
            if input.kind == .escape { screen = safetyReady(body: userDraft ? "사용자가 작성 중인 내용" : ""); afterCancel?() }
            if input.kind == .characters {
                screen = safetyReady(body: input.text)
                if uncertain { throw AppError.message("fixture: lost write acknowledgement") }
            }
            if input.kind == .enter {
                if newlineFirst, inputs.filter({ $0.kind == .enter }).count == 1 {
                    screen = screen.replacingOccurrences(of: "\n\nfixture-model", with: "\n\n\nfixture-model")
                } else {
                    let message = inputs.last { $0.kind == .characters }!.text
                    screen = "Synthetic original conversation\n\n› " + message + "\n\n• Working · esc to interrupt\n\n› \nfixture-model · /fixture · 89% context left"
                }
            }
            return .sent
        }
    }
    var adapter: ScreenHostAdapter {
        ScreenHostAdapter(screens: { [self] targets in
            if lock.withLock({ validationOnly }) { throw AppError.message("Fixture presentation read is unavailable") }
            return TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: read()) }) },
            approve: { [self] _,_,_ in lock.withLock { approvals += 1 }; return .sent }, reveal: { _ in nil },
            input: { [self] _,expected,_,input in try write(expected,input) },
            validationScreens: { [self] targets in
                lock.withLock { validationReads += 1 }
                return TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: read()) }) })
    }
}
@MainActor private func safetyEngine(_ paths: AppPaths, probe: SafetyProbe) throws -> ApprovalEngine {
    let engine = try ApprovalEngine(paths: paths, claudeRegistryReader: { _ in [] }, processReader: { probe.processes() }, screenAdapters: [.iterm: probe.adapter])
    var session = AgentSession(id: safetyCodex.key, agent: .codex, pid: safetyCodex.pid, started: safetyCodex.started, tty: "/dev/ttys980", cwd: "/fixture", terminal: .iterm)
    session.channel = .itermScreen; engine.updateDiscovery([session], records: probe.processes())
    return engine
}
private func safetyHook(_ date: Date, event: String = "PermissionRequest", command: String = "launchctl bootstrap gui/501 ~/Library/LaunchAgents/com.fixture.plist") -> JSONObject {
    ["autoapproveProtocol": 1, "requestID": UUID().uuidString, "autoapproveExpiresAt": date.addingTimeInterval(600).timeIntervalSince1970,
     "hook_event_name": event, "session_id": "fixture-claude", "agentPID": NSNumber(value: safetyClaude.pid), "agentStarted": safetyClaude.started,
     "cwd": "/fixture", "tty": "/dev/ttys981", "tool_name": "Bash", "tool_use_id": UUID().uuidString, "tool_input": ["command": command]]
}
@MainActor private func safetyHookEngine(_ paths: AppPaths, probe: SafetyProbe) throws -> ApprovalEngine {
    try expectEqual(safetyClaude.pid, 51)
    let engine = try ApprovalEngine(paths: paths, claudeRegistryReader: { _ in [] }, processReader: { probe.processes() })
    engine.updateDiscovery(ProcessDiscovery.sessions(probe.processes()), records: probe.processes())
    _ = engine.handleHook(["requestID": UUID().uuidString, "hook_event_name": "SessionStart", "session_id": "fixture-claude", "agentPID": NSNumber(value: safetyClaude.pid), "agentStarted": safetyClaude.started])
    try expectEqual(engine.snapshot.sessions.first { $0.id == safetyClaude.key }?.channel, .hook, "Hook origin: \(safetyClaude.key); live: \(probe.processes().map(\.key)); health: \(engine.snapshot.health.claude)")
    return engine
}
@MainActor private func waitSafety(_ check: () -> Bool) async throws {
    let until = Date().addingTimeInterval(5)
    while !check(), Date() < until { try await Task.sleep(for: .milliseconds(20)) }
    try expect(check(), "Expected the original-session safety action to finish")
}

extension ApprovalTests {
    func testSystemRiskByteCompactionKeepsControlPathsAndLateCandidates() throws {
        let whitespace: Set<UInt8> = [9, 10, 11, 12, 13, 32]
        for byte in UInt8(0)..<128 {
            let separator = String(decoding: [byte], as: UTF8.self)
            let text = "cp fixture ~/Library/Lau" + separator + "nchAgents/com.fixture.plist"
            let expected: SystemCommandRisk.Kind? = whitespace.contains(byte) ? .persistence : nil
            for source in [text, NSAppleEventDescriptor(string: text).stringValue!] {
                let original = Array(source.utf8), storage = source.isContiguousUTF8
                try expectEqual(SystemCommandRisk.detect(source)?.kind, expected, "Preserve control byte \(byte) in a startup path")
                try expect(source.utf8.elementsEqual(original) && source.isContiguousUTF8 == storage)
            }
        }
        let history = String(repeating: "Completed ordinary local project checks.\n", count: 160)
        for prefix in ["", history, "한글 e\u{301} 👩🏽‍💻\n" + history] {
            for source in [prefix + "\nsudo id", NSAppleEventDescriptor(string: prefix + "\nsudo id").stringValue!] {
                try expectEqual(SystemCommandRisk.detect(source)?.kind, .privileged, "Preserve candidates after a long history")
            }
            try expectNil(SystemCommandRisk.detect(prefix + "\nnpm test"))
        }
        try expectEqual(SystemCommandRisk.detect("sudo")?.kind, .privileged)
        try expectNil(SystemCommandRisk.detect(String(repeating: "fixture", count: 1024)))
        try expectNil(SystemCommandRisk.detect(String(repeating: " \t\r\n\u{000b}\u{000c}", count: 1024)))
        for command in ["ſudo id", "syﬆemctl start fixture", "cp fixture ~/Library/LaunchA\ngents/a.plist"] {
            try expectNotNil(SystemCommandRisk.detect(command), "Preserve Unicode and wrapped candidates")
        }
    }

    func testSystemRiskCandidateSearchPreservesCaseFoldingAndUnicodeBarriers() throws {
        for command in ["sudo id", "SUDO id", "ſudo id", "syﬆemctl start fixture", "SyStemCtl start fixture",
            "한글 e\u{301} 👩🏽‍💻\nsudo id", "cp fixture ~/Library/LaunchA\ngents/a.plist",
            "write_text /Library/Preferences/com.fixture.plist", "tccutil reset Accessibility"] {
            try expectNotNil(SystemCommandRisk.detect(command), command)
        }
        for command in ["npm test", "su👩🏽‍💻do id", "su\u{0378}do id", "l\u{200d}aunchctl bootstrap fixture",
            "echo e\u{301} 한글 👩🏽‍💻", "cat ~/Library/LaunchAgents/fixture.plist", "networksetup -getairportpower en0"] {
            try expect(SystemCommandRisk.detect(command) == nil, command)
        }
        let ordinary = String(repeating: "합성 출력 e\u{301} 👩🏽‍💻 completed local checks\n", count: 128)
        try expectNil(SystemCommandRisk.detect(ordinary))
        try expectEqual(SystemCommandRisk.detect(ordinary + "\nsudo id")?.kind, .privileged)
        try expectEqual(SystemCommandRisk.detect(NSAppleEventDescriptor(string: ordinary + "\nsudo id").stringValue!)?.kind, .privileged)
    }

    func testSystemRiskMutationsAndReadOnlyBoundaries() throws {
        for command in ["launchctl bootstrap gui/501 a.plist", "launchctl kickstart gui/501/a", "crontab tasks.txt",
            "cp a.plist ~/Library/LaunchAgents/a.plist", "mkdir -p ~/Library/LaunchDaemons", "echo payload > /Library/LaunchDaemons/a.plist",
            "python3 -c 'Path.home().joinpath(\"Library/LaunchAgents/a.plist\").write_text(payload)'", "sudo pmset -a sleep 0",
            "tccutil reset Accessibility", "spctl --master-disable", "csrutil authenticated-root disable", "defaults write a b c",
            "networksetup -setairportpower en0 off", "systemsetup -setremotelogin on", "chmod 777 /etc/fixture", "cp x /etc/hosts",
            "cat x; cp x ~/Library/LaunchAgents/a.plist", "cat x | tee ~/Library/LaunchAgents/a.plist",
            "cp x ~/Library/LaunchA\ngents/a.plist", "cp x /Library/LaunchDae\nmons/a.plist"] {
            try expectNotNil(SystemCommandRisk.detect(command), command)
        }
        for command in ["launchctl print gui/501/com.fixture", "launchctl list", "crontab -l", "plutil -p ~/Library/LaunchAgents/a.plist",
            "cat ~/Library/LaunchAgents/a.plist", "stat ~/Library/LaunchAgents/a.plist", "defaults read a", "pmset -g assertions",
            "networksetup -getairportpower en0", "git status --short", "npm test", "python3 tools/report.py",
            "cp template.plist /Users/test/project/AutoApprove.app/Contents/Library/LaunchDaemons/local.fixture.plist",
            "cp fixture /Users/test/project/etc/hosts"] {
            try expect(SystemCommandRisk.detect(command) == nil, command)
        }
        try expectEqual(SystemCommandRisk.detect(tool: "Write", input: ["file_path": "/Users/test/Library/LaunchAgents/a.plist", "content": "fixture"])?.kind, .persistence)
        try expectNil(SystemCommandRisk.detect(tool: "Read", input: ["file_path": "/Users/test/Library/LaunchAgents/a.plist"]))
        try expectNil(SystemCommandRisk.detect(tool: "Write", input: ["file_path": "/Users/test/project/tools/installer.py", "content": "Path.home().joinpath('Library/LaunchAgents/a.plist').write_text(payload)"]))
    }

    func testSystemRiskLocalInstallerIsBoundedAndNeverExecuted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-risk-installer-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tools"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("tools/install_hourly_learning_status.py")
        let source = "from pathlib import Path\nPath.home().joinpath('Library/LaunchAgents/com.fixture.plist').write_bytes(payload)\n"
        try source.write(to: file, atomically: true, encoding: .utf8)
        for command in [".venv/bin/python tools/install_hourly_learning_status.py --install", ".venv/bin/python tools/install_hourly_learning_status\n.py --install"] {
            try expectEqual(SystemCommandRisk.detect(command, cwd: root.path)?.kind, .persistence)
        }
        try expect(SystemCommandRisk.detect(".venv/bin/python tools/report.py --show", cwd: root.path) == nil, "A normal project report doesn't inherit installation privileges")
        try (String(repeating: "#", count: 131_073) + source).write(to: file, atomically: true, encoding: .utf8)
        try expectNil(SystemCommandRisk.detect("python3 tools/install_hourly_learning_status.py --install", cwd: root.path))
        try expectNil(SystemCommandRisk.detect("python3 ../install_hourly_learning_status.py --install", cwd: root.path))
        try expectEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["tools"], "Detection never runs the installer")
    }

    func testSystemSafetyComposerOwnershipAndSubmission() throws {
        let risk = SystemCommandRisk.detect("launchctl bootstrap gui/501 fixture")!, text = risk.guidance
        for agent in [AgentKind.codex, .claude] {
            let before = safetyReady(agent), composer = SystemSafetyComposer.capture(before, agent: agent, text: text)!
            let draft = safetyReady(agent, body: text)
            try expect(composer.draftReady(draft)); try expect(!composer.submitted(draft))
            try expect(composer.draftReady(draft.replacingOccurrences(of: "\n\n? for shortcuts", with: "\n\n\n? for shortcuts")))
            try expect(!composer.draftReady(draft.replacingOccurrences(of: "? for shortcuts", with: "추가 사용자 입력\n? for shortcuts")))
            try expect(!composer.draftReady(draft.replacingOccurrences(of: "Synthetic original conversation", with: "Another conversation")))
            let submitted = "Synthetic original conversation\n\n" + (agent == .codex ? "› " : "❯ ") + text + "\n\n" + safetyReady(agent)
            try expect(composer.submitted(submitted))
            try expectNil(SystemSafetyComposer.capture(safetyReady(agent, body: "사용자 초안"), agent: agent, text: text))
        }
        try expectNil(SystemSafetyComposer.capture(safetyPrompt(), agent: .codex, text: text))
        try expectNil(SystemSafetyComposer.capture("$ ", agent: .codex, text: text))
        try expectNil(SystemSafetyComposer.capture(safetyReady().replacingOccurrences(of: "? for shortcuts", with: "Goal paused"), agent: .codex, text: text))
    }

    @MainActor func testSystemSafetyClaudeDeniesAndContinuesWithDurableReplay() throws {
        let paths = AppPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent("aa-safety-hook-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let probe = SafetyProbe(), now = Date(); var engine = try safetyHookEngine(paths, probe: probe)
        try engine.setAutomatic(safetyClaude.key, enabled: true)
        for event in ["PreToolUse", "PermissionRequest"] {
            let request = safetyHook(now, event: event), result = try engine.handleClaudeHook(request, at: now)
            let response = (result["autoapproveBridge"] as! JSONObject)["response"] as! JSONObject
            let output = response["hookSpecificOutput"] as! JSONObject
            if event == "PreToolUse" { try expectEqual(output["permissionDecision"] as? String, "deny"); try expect((output["permissionDecisionReason"] as! String).contains("계속 진행")) }
            else { let decision = output["decision"] as! JSONObject; try expectEqual(decision["behavior"] as? String, "deny"); try expectEqual(decision["interrupt"] as? Bool, false) }
            try expectEqual(engine.snapshot.sessions.first { $0.id == safetyClaude.key }?.systemSafety?.phase, .submitting)
            try engine.acknowledgeClaudeHook(request, at: now)
            try expectEqual(engine.snapshot.sessions.first { $0.id == safetyClaude.key }?.systemSafety?.phase, .guided)
            let originalCount = engine.snapshot.events.count
            engine.stop(); engine = try safetyHookEngine(paths, probe: probe)
            let replay = try engine.handleClaudeHook(request, at: now)
            try expectEqual(try JSONSerialization.data(withJSONObject: replay, options: .sortedKeys), try JSONSerialization.data(withJSONObject: result, options: .sortedKeys))
            try expectEqual(engine.snapshot.events.count, originalCount, "Replay doesn't create another denial or answer")
            var permission = request; permission["requestID"] = UUID().uuidString; permission["hook_event_name"] = "PermissionRequest"
            let next = ((try engine.handleClaudeHook(permission, at: now))["autoapproveBridge"] as! JSONObject)["response"] as! JSONObject
            try expectEqual(((next["hookSpecificOutput"] as! JSONObject)["decision"] as! JSONObject)["behavior"] as? String, "deny")
        }
        try expect(engine.snapshot.events.allSatisfy { $0.outcome.hasPrefix("시스템 변경 거절") && $0.answer?.contains("우회는 하지") == true })
        engine.stop()
    }

    @MainActor func testSystemSafetyClaudePauseManualAndReadOnlyApproval() throws {
        let paths = AppPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent("aa-safety-controls-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let engine = try safetyHookEngine(paths, probe: SafetyProbe()), now = Date(); defer { engine.stop() }
        let request = safetyHook(now)
        try expectEqual((try engine.handleClaudeHook(request, at: now)["autoapproveBridge"] as! JSONObject)["waiting"] as? Bool, true)
        try engine.setAutomatic(safetyClaude.key, enabled: true); try engine.setPaused(true)
        try expectEqual((try engine.handleClaudeHook(request, at: now)["autoapproveBridge"] as! JSONObject)["waiting"] as? Bool, true)
        let approval = engine.snapshot.sessions.first { $0.id == safetyClaude.key }!.claudeApprovals!.first!
        try expectEqual(approval.buttonTitle, "안전한 방법으로 계속"); try expectNil(approval.automaticAt)
        try engine.answerClaudeApproval(sessionID: safetyClaude.key, requestID: request["requestID"] as! String, at: now)
        let response = (try engine.handleClaudeHook(request, at: now)["autoapproveBridge"] as! JSONObject)["response"] as! JSONObject
        try expectEqual(((response["hookSpecificOutput"] as! JSONObject)["decision"] as! JSONObject)["interrupt"] as? Bool, false)
        try engine.setPaused(false)
        let read = safetyHook(now, command: "launchctl print gui/501/com.fixture")
        _ = try engine.handleClaudeHook(read, at: now)
        let allowed = (try engine.handleClaudeHook(read, at: now.addingTimeInterval(5))["autoapproveBridge"] as! JSONObject)["response"] as! JSONObject
        try expectEqual(((allowed["hookSpecificOutput"] as! JSONObject)["decision"] as! JSONObject)["behavior"] as? String, "allow")
    }

    @MainActor func testSystemSafetyScreenRedirectHandlesNewlineWithoutApproval() async throws {
        let paths = AppPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent("aa-safety-screen-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let probe = SafetyProbe(); probe.newlineFirst = true; probe.validationOnly = true
        let engine = try safetyEngine(paths, probe: probe); defer { engine.stop() }
        try engine.setAutomatic(safetyCodex.key, enabled: true)
        engine.receiveScreen(sessionID: safetyCodex.key, raw: probe.read(), generation: "fixture-original")
        try await waitSafety { engine.snapshot.sessions.first?.systemSafety?.phase == .guided }
        try expectEqual(probe.counts, [1, 1, 2, 0], "Escape, one guidance text and Enter-only retry; never Yes")
        try expect(probe.validationReadCount >= 3, "Safety reads and immediate write rechecks use the content-only channel")
        try expectEqual(engine.snapshot.sessions.first?.pid, safetyCodex.pid)
        try expect(engine.snapshot.events.contains { $0.outcome == "안전한 대안 안내 전달 확인" })
        try expectEqual(engine.snapshot.sessions.first?.notices?.first?.isSystemSafety, true, "Strong warning is immediate without the ordinary question delay")
        try engine.markNotificationsRead(safetyCodex.key)
        try expect(AttentionRequest.candidates(engine.snapshot.sessions.first!, paused: false).isEmpty, "Read safety notices don't keep an unresolved question count")
        let firstNotice = engine.snapshot.sessions.first!.systemSafety!.id
        probe.screen = safetyPrompt()
        engine.receiveScreen(sessionID: safetyCodex.key, raw: probe.read(), generation: "fixture-original")
        try await waitSafety { engine.snapshot.sessions.first?.systemSafety?.phase == .guided && probe.counts[0] == 2 }
        try expectEqual(probe.counts, [2,2,3,0], "A repeated dangerous command after completed guidance is denied again without approval")
        try expect(engine.snapshot.sessions.first!.systemSafety!.id != firstNotice)
    }

    @MainActor func testSystemSafetyScreenPauseAndUserDraftArePreserved() async throws {
        let paths = AppPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent("aa-safety-draft-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let probe = SafetyProbe(); probe.userDraft = true
        let engine = try safetyEngine(paths, probe: probe); defer { engine.stop() }
        engine.receiveScreen(sessionID: safetyCodex.key, raw: probe.read(), generation: "fixture-original")
        try await Task.sleep(for: .milliseconds(100)); try expectEqual(probe.counts, [0,0,0,0])
        try engine.setPaused(true); try engine.setAutomatic(safetyCodex.key, enabled: true)
        try await Task.sleep(for: .milliseconds(100)); try expectEqual(probe.counts, [0,0,0,0])
        try engine.setPaused(false); try await waitSafety { probe.counts[0] == 1 }
        try await Task.sleep(for: .milliseconds(400)); try engine.setPaused(true)
        try expectEqual(probe.counts, [1,0,0,0]); try expect(probe.read().contains("사용자가 작성 중인 내용"))
    }

    @MainActor func testSystemSafetyScreenUncertainWriteNeverReplaysAfterRestart() async throws {
        let paths = AppPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent("aa-safety-restart-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let probe = SafetyProbe(); probe.uncertain = true
        var engine = try safetyEngine(paths, probe: probe)
        try engine.setAutomatic(safetyCodex.key, enabled: true)
        engine.receiveScreen(sessionID: safetyCodex.key, raw: probe.read(), generation: "fixture-original")
        try await waitSafety { engine.snapshot.sessions.first?.systemSafety?.phase == .uncertain }
        engine.stop(); engine = try safetyEngine(paths, probe: probe); defer { engine.stop() }
        engine.receiveScreen(sessionID: safetyCodex.key, raw: probe.read(), generation: "fixture-original")
        try await Task.sleep(for: .milliseconds(300)); try expectEqual(probe.counts, [1,1,0,0])
        try expectEqual(engine.snapshot.sessions.first?.systemSafety?.phase, .uncertain)
    }

    @MainActor func testSystemSafetyScreenRechecksProcessAndForegroundBeforeGuidance() async throws {
        for reuse in [true,false] {
            let paths = AppPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent("aa-safety-identity-" + UUID().uuidString))
            defer { try? FileManager.default.removeItem(at: paths.directory) }
            let probe = SafetyProbe()
            probe.afterCancel = { [unowned probe] in
                let index = probe.records.firstIndex { $0.pid == safetyCodex.pid }!
                if reuse { probe.records[index].started = "Tue Oct 13 10:00:00 2026" }
                else { probe.records[index].foregroundGroup = 99 }
            }
            let engine = try safetyEngine(paths, probe: probe); defer { engine.stop() }
            try engine.setAutomatic(safetyCodex.key, enabled: true)
            engine.receiveScreen(sessionID: safetyCodex.key, raw: probe.read(), generation: "fixture-original")
            try await waitSafety { probe.counts[0] == 1 }
            try await Task.sleep(for: .milliseconds(500)); try engine.setPaused(true)
            try expectEqual(probe.counts, [1,0,0,0], "A reused PID or another foreground program receives no guidance or Enter")
        }
    }

    @MainActor func testSystemSafetyConcurrentClaudeReceiptsMatchTheirOwnRequest() throws {
        let paths = AppPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent("aa-safety-concurrent-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let engine = try safetyHookEngine(paths, probe: SafetyProbe()), now = Date(); defer { engine.stop() }
        try engine.setAutomatic(safetyClaude.key, enabled: true)
        let first = safetyHook(now), second = safetyHook(now, command: "sudo pmset -a sleep 0")
        _ = try engine.handleClaudeHook(first, at: now); _ = try engine.handleClaudeHook(second, at: now)
        try expectEqual(engine.snapshot.sessions.first { $0.id == safetyClaude.key }?.systemSafety?.risk.kind, .privileged)
        try engine.acknowledgeClaudeHook(first, at: now)
        try expectEqual(engine.snapshot.sessions.first { $0.id == safetyClaude.key }?.systemSafety?.phase, .submitting, "An old acknowledgement cannot confirm a newer safety instruction")
        try engine.acknowledgeClaudeHook(second, at: now)
        try expectEqual(engine.snapshot.sessions.first { $0.id == safetyClaude.key }?.systemSafety?.phase, .guided)
        try expectEqual(engine.snapshot.events.filter { $0.outcome == "시스템 변경 거절 · 안전한 대안 안내 전달 확인" }.count, 2)
    }
}
