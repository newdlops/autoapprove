import Foundation
import AutoApproveCore

private let choiceMenu = "어떤 화면을 테스트할까요?\n\n› 1. 휴대폰 세로 화면\n  2. 데스크톱 화면\n  3. 두 화면 모두\n\nPress enter to confirm or esc to cancel"
private let codexInputMenu = "Question 1/2 (2 unanswered)\n\n어떤 화면을 점검할까요?\n\n› 1. 휴대폰 화면\n     휴대폰의 세로 화면을 확인합니다.\n  2. 데스크톱 화면\n     넓은 화면을 확인합니다.\n  3. None of the above\n     Optionally, add details in notes (tab)\n\ntab to add notes | enter to submit answer | ←/→ to navigate questions | esc to interrupt"

private func choiceValue<T>(_ value: T?) throws -> T {
    guard let value else { throw AppError.message("Expected a current terminal question") }
    return value
}

@MainActor private func expectChoiceRejection(_ operation: () async throws -> JSONObject) async throws {
    var rejected = false
    do { _ = try await operation() } catch { rejected = true }
    try expect(rejected, "A stale or repeated choice must be rejected")
}

private final class ChoiceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = choiceMenu
    private var inputs: [RemoteTerminalInput] = []
    var nextScreen: String?
    var uncertain = false
    var screen: String { get { lock.lock(); defer { lock.unlock() }; return value } set { lock.lock(); defer { lock.unlock() }; value = newValue } }
    var sent: [RemoteTerminalInput] { lock.lock(); defer { lock.unlock() }; return inputs }
    func write(_ input: RemoteTerminalInput) throws -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }
        inputs.append(input)
        if uncertain { throw AppError.message("합성 부분 입력 결과 미확인") }
        if let nextScreen { value = nextScreen; self.nextScreen = nil }
        return .sent
    }
}

extension ApprovalTests {
    func testTerminalChoiceDetectionAndBounds() throws {
        let question = try choiceValue(TerminalChoiceQuestion.detect(choiceMenu, agent: .codex))
        try expectEqual(question.question, "어떤 화면을 테스트할까요?")
        try expectEqual(question.options, ["휴대폰 세로 화면", "데스크톱 화면", "두 화면 모두"])
        try expectEqual(question.selected, 0)
        let moved = choiceMenu.replacingOccurrences(of: "› 1.", with: "  1.").replacingOccurrences(of: "  3.", with: "› 3.")
        try expectEqual(TerminalChoiceQuestion.detect(moved, agent: .codex)?.id, question.id)
        try expectEqual(TerminalChoiceQuestion.detect(moved, agent: .codex)?.selected, 2)
        let wrapped = choiceMenu.replacingOccurrences(of: "휴대폰 세로 화면", with: "휴대폰 세로\n     화면")
        try expectEqual(TerminalChoiceQuestion.detect(wrapped, agent: .codex)?.id, question.id)
        try expectEqual(TerminalChoiceQuestion.detect(wrapped, agent: .codex)?.options, question.options)
        try expect(TerminalChoiceQuestion.detect(choiceMenu.replacingOccurrences(of: "?", with: "."), agent: .claude) != nil)
        let numberInLabel = choiceMenu.replacingOccurrences(of: "데스크톱 화면", with: "데스크톱 화면\n     3. 줄의 내용을 확인")
        try expectEqual(TerminalChoiceQuestion.detect(numberInLabel, agent: .codex)?.options.count, 3)
        for invalid in ["```\n" + choiceMenu + "\n```", choiceMenu + "\n› 새 메시지", choiceMenu.replacingOccurrences(of: "  2.", with: "  7."), choiceMenu.replacingOccurrences(of: "Press enter to confirm or esc to cancel", with: "진행 중…")] {
            try expectNil(TerminalChoiceQuestion.detect(invalid, agent: .codex))
        }
        try expectNil(TerminalChoiceQuestion.detect("Would you like to run this command?\n\n$ test\n\n› 1. Yes, proceed (y)\n  2. No, and tell Codex what to do differently (esc)\n\nPress enter to confirm or esc to cancel", agent: .codex))
        for delta in [-19, -1, 0, 1, 19] { let input = RemoteTerminalInput(kind: .choice, text: String(delta)); try input.validate(); try expectEqual(input.bytes.filter { $0 == "\r" }.count, 1) }
        for invalid in ["20", "-20", "01", "-0", "", "1\n", "\u{1b}", String(Int.min)] { try expectThrows(try RemoteTerminalInput(kind: .choice, text: invalid).validate()) }
    }

    @MainActor func testTerminalChoiceExactFrameSingleUseAndRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-choice-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = ProcessDiscovery.parse("42 1 ttys099 42 42 Mon Oct 5 09:00:00 2026 codex")[0]
        var session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/ttys099", cwd: "/fixture", terminal: .iterm)
        session.channel = .itermScreen
        let probe = ChoiceProbe(), tty = session.tty
        let adapter = ScreenHostAdapter(screens: { _ in TerminalSnapshot(screens: [TerminalScreen(tty: tty, contents: probe.screen)]) }, approve: { _,_,_ in .missingTarget }, reveal: { _ in nil }, input: { _,_,_,input in try probe.write(input) })
        let paths = AppPaths(directory: directory)
        let engine = try ApprovalEngine(paths: paths, processReader: { [record] }, screenAdapters: [.iterm: adapter])
        defer { engine.stop() }
        engine.updateDiscovery([session], records: [record]); await engine.connectScreenHost(.iterm); try engine.setAutomatic(session.id, enabled: true); try engine.setPaused(true)
        let frame = try await engine.remoteTerminal(sessionID: session.id, realtime: true), question = try choiceValue(frame.question)
        try expect(probe.sent.isEmpty, "General choices must not be auto-approved")
        let payload: JSONObject = ["action": "replyTerminalQuestion", "sessionID": session.id, "questionID": question.id, "revision": frame.revision, "choice": 2]
        _ = try await engine.remoteAction(payload)
        try expectEqual(probe.sent.map(\.bytes), ["\u{1b}[B\u{1b}[B\r"])
        let after = try await engine.remoteTerminal(sessionID: session.id, realtime: true)
        try expectEqual(after.question?.reply?.phase, .queued)
        try await expectChoiceRejection { try await engine.remoteAction(payload) }
        engine.stop()
        let reopened = try ApprovalEngine(paths: paths, processReader: { [record] }, screenAdapters: [.iterm: adapter])
        defer { reopened.stop() }
        reopened.updateDiscovery([session], records: [record]); await reopened.connectScreenHost(.iterm)
        let fresh = try await reopened.remoteTerminal(sessionID: session.id, realtime: true)
        var repeatPayload = payload; repeatPayload["revision"] = fresh.revision
        try await expectChoiceRejection { try await reopened.remoteAction(repeatPayload) }
        try expectEqual(probe.sent.count, 1)
        probe.screen = choiceMenu.replacingOccurrences(of: "테스트", with: "점검")
        _ = try await reopened.remoteTerminal(sessionID: session.id, realtime: true)
        try await expectChoiceRejection { try await reopened.remoteAction(repeatPayload) }
        try expectEqual(probe.sent.count, 1)
        try expect(reopened.managedPTY.inventory.isEmpty)
    }

    @MainActor func testTerminalChoiceUncertainWriteCannotRepeat() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-choice-unknown-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = ProcessDiscovery.parse("43 1 ttys098 43 43 Mon Oct 5 09:00:00 2026 codex")[0], probe = ChoiceProbe(); probe.uncertain = true
        var session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/ttys098", cwd: "/fixture", terminal: .iterm); session.channel = .itermScreen
        let adapter = ScreenHostAdapter(screens: { _ in TerminalSnapshot(screens: [TerminalScreen(tty: "/dev/ttys098", contents: probe.screen)]) }, approve: { _,_,_ in .missingTarget }, reveal: { _ in nil }, input: { _,_,_,input in try probe.write(input) })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, screenAdapters: [.iterm: adapter]); defer { engine.stop() }
        engine.updateDiscovery([session], records: [record]); await engine.connectScreenHost(.iterm)
        let frame = try await engine.remoteTerminal(sessionID: session.id), question = try choiceValue(frame.question)
        var payload: JSONObject = ["action": "replyTerminalQuestion", "sessionID": session.id, "questionID": question.id, "revision": frame.revision, "choice": 1]
        do { _ = try await engine.remoteAction(payload); throw AppError.message("Uncertain write accepted") } catch let error as RemoteHTTPError { try expectEqual(error.diagnostics?["delivery"], "unknown") }
        let next = try await engine.remoteTerminal(sessionID: session.id, realtime: true); payload["revision"] = next.revision
        try expectEqual(next.question?.reply?.phase, .uncertain)
        try await expectChoiceRejection { try await engine.remoteAction(payload) }; try expectEqual(probe.sent.count, 1)
    }

    @MainActor func testCodexInteractiveChoiceAdvancesWithoutExtraEnter() async throws {
        let first = try choiceValue(TerminalChoiceQuestion.detect(codexInputMenu, agent: .codex))
        try expectEqual(first.numericSubmission, true); try expectEqual(first.command(for: 1), "digit:2")
        try expectEqual(TerminalChoiceQuestion.detect(codexInputMenu.replacingOccurrences(of: " | ", with: "\n"), agent: .codex)?.id, first.id)
        let notes = codexInputMenu.components(separatedBy: "\ntab to add notes")[0] + "\n\n› Add notes\n\ntab or esc to clear notes | enter to submit answer"
        try expectNil(TerminalChoiceQuestion.detect(notes, agent: .codex)); try expect(TerminalChoiceQuestion.hasCodexOverlay(notes))
        try expectNil(TerminalChoiceQuestion.detect(codexInputMenu.replacingOccurrences(of: "enter to submit", with: "ctrl+j to submit"), agent: .codex))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-codex-input-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = ProcessDiscovery.parse("44 1 ttys097 44 44 Mon Oct 5 09:00:00 2026 codex")[0], probe = ChoiceProbe()
        probe.screen = codexInputMenu
        let second = codexInputMenu.replacingOccurrences(of: "Question 1/2 (2 unanswered)", with: "Question 2/2 (1 unanswered)").replacingOccurrences(of: "enter to submit answer", with: "enter to submit all")
        probe.nextScreen = second
        var session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/ttys097", cwd: "/fixture", terminal: .iterm); session.channel = .itermScreen
        let adapter = ScreenHostAdapter(screens: { _ in TerminalSnapshot(screens: [TerminalScreen(tty: "/dev/ttys097", contents: probe.screen)]) }, approve: { _,_,_ in .missingTarget }, reveal: { _ in nil }, input: { _,_,_,input in try probe.write(input) })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, screenAdapters: [.iterm: adapter]); defer { engine.stop() }
        engine.updateDiscovery([session], records: [record]); await engine.connectScreenHost(.iterm)
        let frame = try await engine.remoteTerminal(sessionID: session.id), menu = try choiceValue(frame.question)
        try expectEqual(engine.snapshot.sessions.first?.phase, .input)
        try await expectChoiceRejection { try await engine.remoteAction(["action":"sendMessage","transport":"terminal","sessionID":session.id,"revision":frame.revision,"text":"현재 질문에 새 대화 입력을 보내지 않습니다."]) }
        try expect(probe.sent.isEmpty)
        _ = try await engine.remoteAction(["action":"replyTerminalQuestion","sessionID":session.id,"questionID":menu.id,"revision":frame.revision,"choice":1])
        try expectEqual(probe.sent.map(\.bytes), ["2"])
        let next = try await engine.remoteTerminal(sessionID: session.id, realtime: true), nextMenu = try choiceValue(next.question)
        try expect(nextMenu.id != menu.id); try expectEqual(nextMenu.numericSubmission, true)
        try expectEqual(probe.sent.count, 1, "The next question must wait for the user's next choice")
        _ = try await engine.remoteAction(["action":"replyTerminalQuestion","sessionID":session.id,"questionID":nextMenu.id,"revision":next.revision,"choice":0])
        try expectEqual(probe.sent.map(\.bytes), ["2", "1"])
    }
}
