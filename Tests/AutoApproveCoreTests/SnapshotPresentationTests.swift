import Foundation
import Combine
import AutoApproveCore

extension ApprovalTests {
    func testPresentationHeartbeatPreservesStateAndNotificationTransitions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-presentation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] }, processReader: { [] })
        defer { engine.stop() }
        var snapshot = engine.snapshot
        var codex = AgentSession(id: "codex", agent: .codex, pid: 900001, started: "fixture", tty: "/dev/fixture",
                                 cwd: "/fixture", terminal: .terminal)
        codex.codexActivity = try JSONDecoder().decode(CodexActivitySnapshot.self, from: Data("""
        {"observedAt":1,"parent":{"id":"parent","title":"Parent","phase":"working"},
         "children":[{"id":"child","title":"Child","phase":"working"}]}
        """.utf8))
        codex.phase = .input; codex.pendingSummary = "Choose a project"; codex.pendingRequestID = "question-1"
        var child = codex; child.id = "background"
        codex.backgroundSessions = [child]
        snapshot.sessions = [codex]
        let original = snapshot
        let subject = CurrentValueSubject<EngineSnapshot, Never>(snapshot)
        var raw: [EngineSnapshot] = [], presented: [EngineSnapshot] = []
        var tracker = AttentionTracker(), requests: [[AttentionRequest]] = []
        let rawSubscription = subject.sink { raw.append($0) }
        let subscription = subject.presentationChanges().sink {
            presented.append($0); requests.append(tracker.update($0))
        }
        defer { rawSubscription.cancel(); subscription.cancel() }
        for tick in 2...101 {
            snapshot.sessions[0].codexActivity?.observedAt = Date(timeIntervalSinceReferenceDate: Double(tick))
            snapshot.sessions[0].backgroundSessions?[0].codexActivity?.observedAt = Date(timeIntervalSinceReferenceDate: Double(tick))
            subject.send(snapshot)
        }
        try expectEqual(raw.count, 101)
        try expectEqual(presented.count, 1, "Observation-only ticks must not rebuild presentation or notifications")
        try expect(original != snapshot, "Domain equality must still distinguish observation time")
        try expectEqual(raw.last?.sessions[0].codexActivity?.observedAt, Date(timeIntervalSinceReferenceDate: 101))
        try expectEqual(original.sessions[0].codexActivity?.observedAt, Date(timeIntervalSinceReferenceDate: 1))

        func changed(_ update: (inout EngineSnapshot) -> Void) throws {
            let count = presented.count
            update(&snapshot); subject.send(snapshot)
            try expectEqual(presented.count, count + 1, "A real content change was suppressed")
            try expectEqual(presented.last, snapshot, "Subscribers must receive the original, fresh snapshot")
        }
        try changed { $0.sessions[0].codexActivity?.children[0].phase = .approval }
        try changed { $0.sessions[0].codexActivity?.children[0].title = "Renamed child" }
        try changed { $0.sessions[0].codexApprovalBinding = .init(threadID: "new-conversation", title: "New") }
        try changed { $0.sessions[0].codexActivity = nil }
        try changed { $0.sessions[0].codexActivity = original.sessions[0].codexActivity }
        try changed { $0.sessions[0].lastActivity = Date(timeIntervalSinceReferenceDate: 200) }
        try changed { $0.sessions[0].codexQuestionsError = "Connection lost" }
        try changed { $0.sessions[0].codexQuestionsError = nil }
        let notice = try JSONDecoder().decode(SessionNotice.self, from: Data("""
        {"id":"notice","sourceKey":"question:test","kind":"question","summary":"Question","date":1,"isRead":false}
        """.utf8))
        try changed { $0.sessions[0].notices = [notice] }
        try changed { $0.sessions[0].notices?[0].isRead = true }
        try changed { $0.sessions[0].completion = WorkCompletion(id: "completed", date: Date(timeIntervalSinceReferenceDate: 200)) }
        guard let expiry = AttentionRequest.nextCompletionExpiration(snapshot, at: Date(timeIntervalSinceReferenceDate: 250)) else {
            throw AppError.message("Missing completion expiration")
        }
        try expectEqual(AttentionRequest.completions(snapshot, at: Date(timeIntervalSinceReferenceDate: 250)).count, 1)
        try expect(AttentionRequest.completions(snapshot, at: expiry).isEmpty)
        try expectNil(AttentionRequest.nextCompletionExpiration(snapshot, at: expiry))
        var nested = snapshot
        nested.sessions[0].completion = nil
        nested.sessions[0].backgroundSessions?[0].completion = snapshot.sessions[0].completion
        try expectEqual(AttentionRequest.nextCompletionExpiration(nested, at: Date(timeIntervalSinceReferenceDate: 250)), expiry)
        nested.sessions[0].backgroundSessions?[0].phase = .ended
        try expectNil(AttentionRequest.nextCompletionExpiration(nested, at: Date(timeIntervalSinceReferenceDate: 250)))
        try changed { $0.sessions[0].completion = nil }
        try changed { $0.health.terminalConnected.toggle() }
        try changed { $0.questionNotificationDelaySeconds = 45 }
        try changed { $0.paused.toggle() }
        try changed { $0.sessions[0].automatic.toggle() }
        try changed { $0.sessions[0].sessionGroup = .init(groupID: UUID(), groupName: "Group", memberID: UUID(), role: .member) }
        try changed { $0.sessions[0].sessionGroup?.task = .question }
        try changed { $0.sessions[0].backgroundSessions?[0].phase = .idle }
        let beforeResolution = requests.last!.map(\.id)
        try expect(!beforeResolution.isEmpty)
        try changed {
            $0.sessions[0].phase = .working; $0.sessions[0].pendingSummary = nil
            $0.sessions[0].pendingRequestID = nil; $0.sessions[0].backgroundSessions = nil
        }
        try expect(requests.last!.isEmpty, "Resolved questions must cancel pending delivery")
        try changed {
            $0.sessions[0].phase = .input; $0.sessions[0].pendingSummary = "Choose a project"
            $0.sessions[0].pendingRequestID = "question-1"
        }
        try expect(!requests.last!.isEmpty && Set(requests.last!.map(\.id)).isDisjoint(with: beforeResolution),
                   "A later identical question must receive a new notification")
        var claude = codex; claude.id = "claude"; claude.agent = .claude; claude.codexActivity = nil
        try changed { $0.sessions.append(claude) }
        try changed { $0.sessions[1].detail = "Claude question changed" }
        try changed { $0.sessions.removeLast() }
    }

    func testGroupPresentationKeepsFreshIdentitiesAndConnectionChanges() throws {
        var session = AgentSession(id: "runtime", agent: .codex, pid: 900001, started: "fixture", tty: "/dev/fixture",
                                   cwd: "/fixture", terminal: .terminal)
        session.codexActivity = try JSONDecoder().decode(CodexActivitySnapshot.self, from: Data("""
        {"observedAt":1,"parent":{"id":"parent","title":"Parent","phase":"working"},"children":[]}
        """.utf8))
        let original = SessionGroupLiveSession(session: session, conversationID: "old-id", providerHome: "/fixture/home")
        var changed = original
        changed.session.codexActivity?.observedAt = Date(timeIntervalSinceReferenceDate: 100)
        try expect(original != changed && original.hasSamePresentation(as: changed))
        let mutations: [(inout SessionGroupLiveSession) -> Void] = [
            { $0.conversationID = "new-id" }, { $0.providerHome = "/fixture/new-home" },
            { $0.messagingName = "new-name" }, { $0.session.id = "new-runtime" },
            { $0.session.phase = .ended }, { $0.session.codexActivity = nil },
            { $0.session.automatic.toggle() }
        ]
        for mutate in mutations {
            changed = original; mutate(&changed)
            try expect(!original.hasSamePresentation(as: changed), "Group identity or connection change was suppressed")
        }
    }
}
