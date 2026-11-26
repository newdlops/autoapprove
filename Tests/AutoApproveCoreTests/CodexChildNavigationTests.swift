import Foundation
import TerminalInputSupport
#if DEBUG
@testable import AutoApproveCore
#else
import AutoApproveCore
#endif

private let navigationParent = "00000000-0000-4000-8000-000000000001"
private let navigationChild = "00000000-0000-4000-8000-000000000002"
private let navigationLabel = "/root/approval_fixture"
private let navigationOwn = """
Would you like to run the following command?

Environment: local
Reason: Owned harmless child approval regression
$ printf APPROVAL_FIX_OK

› 1. Yes, proceed (y)
  2. No, and tell Codex what to do differently (esc)

Press enter to confirm or esc to cancel
"""
private let navigationOverlay = navigationOwn.replacingOccurrences(of: "Environment: local", with: "Thread: \(navigationLabel)\n\nEnvironment: local") + " or o to open thread"
private let navigationMain = navigationOverlay.replacingOccurrences(of: navigationLabel, with: "Main [default]")
private let mainDraft = "› OWNED_DRAFT_MUST_SURVIVE\nfixture-model default · ~ · Main [default]"
private let navigationReady = "› Viewing sub-agent — direct input is disabled\nfixture-model default · ~ · \(navigationLabel)"
private let navigationPicker = """
Subagents
Select an agent to watch. ⌥← previous, ⌥→ next.
  1. • Main [default] \(navigationParent)
› 2. • \(navigationLabel) (current) \(navigationChild)
enter select · esc back
"""
private final class NavigationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var frame = navigationOverlay
    private var writes: [String] = []
    let resolved: Bool
    let followingMain: Bool
    private var openedMain = false
    var uncertainAt: String?
    var rejectOpen = false
    init(resolved: Bool = false, initial: String = navigationOverlay, followingMain: Bool = false) {
        self.resolved = resolved; self.frame = initial; self.followingMain = followingMain
    }
    var inputs: [String] { lock.lock(); defer { lock.unlock() }; return writes }
    var screen: String { lock.lock(); defer { lock.unlock() }; return frame }
    var adapter: ScreenHostAdapter {
        ScreenHostAdapter(screens: { targets in .init(screens: targets.map { .init(tty: $0.tty, contents: self.screen) }) },
            approve: { _, raw, _ in try self.write("approve", raw: raw) }, reveal: { _ in nil },
            input: { _, raw, _, value in try self.write(value.kind == .characters ? value.text : value.kind.rawValue, raw: raw) })
    }
    private func write(_ value: String, raw: String) throws -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }
        guard raw == frame else { return .screenChanged }
        if rejectOpen && value == "o" { return .screenChanged }
        writes.append(value)
        if uncertainAt == value { throw AppError.message("Owned uncertain input") }
        switch value {
        case "o":
            openedMain = frame == navigationMain
            frame = resolved ? (openedMain ? mainDraft : navigationReady) : navigationOwn
        case "approve": frame = openedMain ? mainDraft : (followingMain ? navigationMain : navigationReady)
        case "/subagents": frame = "› /subagents"
        case "up": frame = navigationPicker.replacingOccurrences(of: "  1.", with: "› 1.").replacingOccurrences(of: "› 2.", with: "  2.")
        case "enter": frame = frame == "› /subagents" ? navigationPicker : mainDraft
        default: throw AppError.message("Unexpected input")
        }
        return .sent
    }
}
extension ApprovalTests {
    func testMainApprovalOverlayAndConsecutiveWorkerRequests() async throws {
        for (first, resolved) in [(navigationMain, false), (navigationMain, true), (navigationOverlay, false)] {
            let queued = first == navigationOverlay
            let probe = NavigationProbe(resolved: resolved, initial: first, followingMain: queued)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let records = ProcessDiscovery.parse("82001 1 ttys891 82001 82001 Wed Oct 28 22:00:00 2026 /fixture/codex")
            let record = records[0]
            let engine = try ApprovalEngine(paths: .init(directory: directory), processReader: { records },
                screenAdapters: [.iterm: probe.adapter], isolateByDefault: true)
            defer { engine.stop(); try? FileManager.default.removeItem(at: directory) }
            var session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started,
                tty: "/dev/ttys891", cwd: directory.path, terminal: .iterm)
            session.channel = .itermScreen
            engine.updateDiscovery([session], records: records)
            try engine.setAutomatic(session.id, enabled: true)
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                engine.receiveScreen(sessionID: session.id, raw: probe.screen, generation: "fixture")
                if probe.screen == mainDraft && engine.snapshot.events.contains(where: {
                    $0.outcome == (resolved ? "처리된 승인창 정리" : "원래 대화에서 승인 입력 전달")
                }) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try expectEqual(probe.inputs, queued ? ["o", "approve", "o", "approve"] : resolved ? ["o"] : ["o", "approve"])
            try expectEqual(probe.screen, mainDraft)
            try expectEqual(engine.snapshot.sessions.first?.automatic, true)
        }
    }
#if DEBUG
    func testOfficialChildNavigationEngineReservationAndUncertainReplay() async throws {
        for scenario in ["terminal", "missingIdentity", "uncertain"] {
            let uncertain = scenario == "uncertain"
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-official-navigation-" + UUID().uuidString)
            let paths = AppPaths(directory: directory), probe = NavigationProbe()
            if uncertain { probe.uncertainAt = "approve" }
            let identity = TTYInputIdentity(pid: 82001, processGroup: 82001, uid: getuid(), effectiveUID: geteuid(), device: 42, startSeconds: 1800000000, startMicroseconds: 123)
            let records = ProcessDiscovery.parse("82001 1 ttys891 82001 82001 \(identity.processStart) /usr/local/bin/codex")
            let process = records[0]
            var session = AgentSession(id: process.key, agent: .codex, pid: process.pid, started: process.started,
                tty: "/dev/ttys891", cwd: "/tmp/approval-fixture", terminal: uncertain ? .iterm : .terminal)
            session.channel = uncertain ? .itermScreen : .terminalScreen
            try paths.prepare()
            try AuditStore(path: paths.database).set("codexApprovalBinding:" + session.id,
                String(decoding: try JSONEncoder().encode(CodexApprovalBinding(threadID: navigationParent, title: "owned fixture")), as: UTF8.self))
            let offline = CodexReplyTransport(prepare: { _, _ in throw AppError.message("owned fixture offline") },
                send: { _, _ in throw AppError.message("owned fixture offline") }, prepareMessage: { _ in throw AppError.message("owned fixture offline") })
            var adapter = probe.adapter
            let input = adapter.input
            if !uncertain {
                adapter.input = { target, raw, agent, value in
                    guard target.sourceIdentity == identity else { return .agentMissing }
                    return try input(target, raw, agent, value)
                }
            }
            let engine = try ApprovalEngine(paths: paths, questionTransport: offline, processReader: { records },
                screenAdapters: [uncertain ? .iterm : .terminal: adapter],
                terminalInputIdentity: { _ in scenario == "missingIdentity" ? nil : identity })
            defer { engine.stop(); try? FileManager.default.removeItem(at: directory) }
            engine.updateDiscovery([session], records: records)
            try engine.setAutomatic(session.id, enabled: true)
            engine.receiveScreen(sessionID: session.id, raw: navigationOverlay, generation: "owned")
            for _ in 0..<150 {
                if uncertain ? engine.snapshot.sessions.first?.automatic == false : probe.inputs.count == 6 { break }
                if probe.inputs.contains("o") { engine.receiveScreen(sessionID: session.id, raw: navigationOwn, generation: "owned") }
                try await Task.sleep(for: .milliseconds(10))
            }
            if scenario == "missingIdentity" {
                try expectEqual(probe.inputs, [])
                try expectEqual(engine.snapshot.sessions.first?.pendingInTerminal, true)
                try expectEqual(engine.snapshot.sessions.first?.automatic, true)
                engine.receiveScreen(sessionID: session.id, raw: navigationOverlay, generation: "owned")
                try await Task.sleep(for: .milliseconds(650))
                try expectEqual(engine.snapshot.events.filter { $0.outcome.contains("agentMissing") }.count, 1)
            } else if uncertain {
                try expectEqual(engine.snapshot.sessions.first?.automatic, false)
                try expectEqual(try AuditStore(path: paths.database).value("automatic:" + session.id), "false", "Uncertain child approval cannot replay after restart")
                engine.receiveScreen(sessionID: session.id, raw: navigationOwn, generation: "resized")
                try await Task.sleep(for: .milliseconds(100))
                try expectEqual(probe.inputs, ["o", "approve"])
            } else {
                try expectEqual(probe.inputs, ["o", "approve", "/subagents", "enter", "up", "enter"])
                try expectEqual(engine.snapshot.sessions.first?.automatic, true)
            }
        }
    }
    func testOfficialChildNavigationPendingAndResolved() async throws {
        for resolved in [false, true] {
            let probe = NavigationProbe(resolved: resolved)
            let result = try await CodexChildApprovalNavigation.approve(target: .init(tty: "/dev/fixture"),
                initial: navigationOverlay, parentThreadID: navigationParent, adapter: probe.adapter, valid: { true })
            try expectEqual(result.delivery, .sent)
            try expectEqual(result.approved, !resolved)
            try expectEqual(probe.inputs, ["o"] + (resolved ? [] : ["approve"]) + ["/subagents", "enter", "up", "enter"])
            try expect(probe.screen.contains("OWNED_DRAFT_MUST_SURVIVE"), "Parent draft remains owned by its TUI")
        }
    }
    func testOfficialChildNavigationStopsOnUncertainAndChangedSource() async throws {
        for uncertain in ["o", "approve", "/subagents", "enter", "up"] {
            let probe = NavigationProbe(); probe.uncertainAt = uncertain
            do {
                _ = try await CodexChildApprovalNavigation.approve(target: .init(tty: "/dev/fixture"),
                    initial: navigationOverlay, parentThreadID: navigationParent, adapter: probe.adapter, valid: { true })
                throw AppError.message("Uncertain navigation unexpectedly succeeded")
            } catch {
                try expectEqual(probe.inputs.last, uncertain, "No later input can follow an uncertain write")
                try expectEqual(probe.inputs.filter { $0 == uncertain }.count, 1, "Uncertain input is never repeated")
            }
        }
        let changed = NavigationProbe()
        do {
            _ = try await CodexChildApprovalNavigation.approve(target: .init(tty: "/dev/fixture"), initial: navigationOverlay,
                parentThreadID: navigationParent, adapter: changed.adapter, valid: { changed.inputs.isEmpty })
        } catch { /* A new PID, user input or pause invalidates the caller's reservation. */ }
        try expectEqual(changed.inputs, ["o"])
        let rejected = NavigationProbe(); rejected.rejectOpen = true
        let result = try await CodexChildApprovalNavigation.approve(target: .init(tty: "/dev/fixture"), initial: navigationOverlay,
            parentThreadID: navigationParent, adapter: rejected.adapter, valid: { true })
        try expectEqual(result.delivery, .screenChanged)
        try expectEqual(rejected.inputs, [])
    }
    func testOfficialChildNavigationScreenIdentity() throws {
        try expectEqual(CodexChildApprovalNavigation.request(navigationOverlay)?.label, navigationLabel)
        try expectNil(CodexChildApprovalNavigation.request(navigationOwn))
        try expectNil(CodexChildApprovalNavigation.request(navigationOverlay + "\n› new input"))
        let wrapped=navigationOverlay.replacingOccurrences(of:navigationLabel,with:"/root/approval_\nfixture")
        try expectEqual(CodexChildApprovalNavigation.request(wrapped),CodexChildApprovalNavigation.request(navigationOverlay))
        try expectNil(CodexChildApprovalNavigation.request(navigationOverlay.replacingOccurrences(of:navigationLabel,with:"/root/approval_…")))
        try expect(CodexChildApprovalNavigation.childReady(navigationReady, label: navigationLabel), "Exact empty child composer and footer")
        try expect(!CodexChildApprovalNavigation.childReady(navigationReady + "\n› new draft", label: navigationLabel), "A later draft stops return navigation")
        try expect(CodexChildApprovalNavigation.childReady(navigationReady.replacingOccurrences(of:navigationLabel,with:"/root/approval_\nfixture"),label:navigationLabel),"Wrapped complete footer retains exact child identity")
        let picker = CodexChildApprovalNavigation.picker(navigationPicker)
        try expectEqual(picker?.first?.id, navigationParent)
        try expectEqual(picker?.first?.primary, true)
        try expectEqual(picker?.last?.selected, true)
        try expectEqual(CodexChildApprovalNavigation.picker(navigationPicker.replacingOccurrences(of:"(current) "+navigationChild,with:"(current)\n"+navigationChild)),picker)
        try expectNil(CodexChildApprovalNavigation.picker(navigationPicker + "\nunknown footer"))
        try expectNil(CodexChildApprovalNavigation.picker(navigationPicker.replacingOccurrences(of: navigationChild, with: navigationParent)))
    }
#endif
}
