import Foundation
import AutoApproveCore

private final class RegistryStatus: @unchecked Sendable { var value = "idle" }

extension ApprovalTests {
    /// A custom Claude status line hides the idle composer. Claude's own registry fills in idle and
    /// busy, but never a waiting request, which must still be read from the screen.
    @MainActor func testClaudeRegistryStatusFillsUnreadableScreen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-registry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("""
        1 0 ?? 1 0 Tue Sep 22 09:00:00 2026 /sbin/launchd
        20 1 ttys041 20 20 Tue Sep 22 09:00:00 2026 claude
        """)
        let status = RegistryStatus()
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), claudeRegistryReader: { rows in
            rows.filter { $0.agent == .claude }.map { .init(processID: $0.key, kind: "interactive", sessionID: "fixture-conversation", status: status.value) }
        }, processReader: { records })
        defer { engine.stop() }
        guard let record = records.first(where: { $0.pid == 20 }) else { throw AppError.message("fixture record missing") }
        var session = AgentSession(id: record.key, agent: .claude, pid: 20, started: record.started, tty: "/dev/ttys041", cwd: "/fixture", terminal: .iterm)
        session.channel = .terminalScreen
        let unreadable = "fixture | main | model | ctx 12%\n⏵⏵ auto mode on (shift+tab to cycle)"
        try expectEqual(ActivityDetector.detect(unreadable, agent: .claude).phase, .unknown, "The fixture screen must be unreadable")
        func observe(_ value: String, _ generation: String) -> SessionPhase? {
            status.value = value
            engine.updateDiscovery([session], records: records)
            engine.receiveScreen(sessionID: session.id, raw: unreadable, generation: generation, source: .terminalScreen)
            return engine.snapshot.sessions.first { $0.id == session.id }?.phase
        }
        try expectEqual(observe("idle", "g1"), .idle)
        try expectEqual(observe("busy", "g2"), .working)
        try expectEqual(observe("waiting", "g3"), .unknown, "A waiting request is never inferred from the registry")
        try expectEqual(observe("shell", "g4"), .unknown)
    }

    /// Naming is asked once: the leader names everyone, or each member names itself without a leader.
    /// The request is a system notice, so it never counts as an unacknowledged group message.
    @MainActor func testGroupNicknameRequestIsSentOncePerMember() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-nickname-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), claudeRegistryReader: { _ in [] }, processReader: { [] })
        defer { engine.stop() }
        func member(_ title: String) -> SessionGroupMember {
            SessionGroupMember(agent: .claude, title: title, cwd: "/fixture/fundservice", conversationID: UUID().uuidString.lowercased(), providerHome: nil)
        }
        let led = [member("터미널 제목 미확인"), member("터미널 제목 미확인"), member("결제 PR 리뷰")]
        let leaderless = [member("터미널 제목 미확인"), member("터미널 제목 미확인")]
        let withLeader = SessionGroup(name: "fixture led", members: led, leaderMemberID: led[0].id)
        let peers = SessionGroup(name: "fixture peers", members: leaderless)
        try SessionGroupStore(directory: directory).save([withLeader, peers])
        let box = try SessionGroupMailbox(directory: directory)

        try expectEqual(try engine.requestSessionGroupNicknames(groupID: withLeader.id, memberIDs: led.map(\.id)), 1)
        let notices = try box.list(groupID: withLeader.id, memberID: led[0].id).filter { $0.kind == .notice }
        try expectEqual(notices.count, 1)
        try expect(led.allSatisfy { notices[0].text.contains($0.id.uuidString) }, "The leader's request lists every member")
        try expect(notices[0].text.contains("set_group_member_title"))
        try expectEqual(try engine.requestSessionGroupNicknames(groupID: withLeader.id, memberIDs: led.map(\.id)), 0, "Asked members are not asked again")
        let added = member("터미널 제목 미확인")
        var grown = withLeader; grown.members.append(added)
        try SessionGroupStore(directory: directory).save([grown, peers], expected: [withLeader, peers])
        try expectEqual(try engine.requestSessionGroupNicknames(groupID: grown.id, memberIDs: grown.members.map(\.id)), 1)
        let second = try box.list(groupID: grown.id, memberID: led[0].id).filter { $0.kind == .notice }.last
        try expect(second?.text.contains(added.id.uuidString) == true && second?.text.contains(led[1].id.uuidString) == false,
                   "A later request lists only the new member")

        try expectEqual(try engine.requestSessionGroupNicknames(groupID: peers.id, memberIDs: leaderless.map(\.id)), 2)
        for peer in leaderless {
            let own = try box.list(groupID: peers.id, memberID: peer.id).filter { $0.kind == .notice }
            try expectEqual(own.count, 1); try expect(own[0].text.contains(peer.id.uuidString))
        }
        try expectEqual(try box.inboxOperations(groupID: withLeader.id)[led[0].id]?.unacknowledgedCount ?? 0, 0,
                        "A naming notice is not an unacknowledged group message")
    }

    func testMailboxDataVersionChangesOnlyAfterAnotherConnectionCommits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-data-version-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try SessionGroupMailbox(directory: directory), reader = try SessionGroupMailbox(directory: directory)
        let initial = try reader.dataVersion
        try expectEqual(try reader.dataVersion, initial, "Reading alone does not change the version")
        _ = try writer.enqueue(groupID: UUID(), senderID: UUID(), recipientID: UUID(), kind: .message, text: "fixture")
        try expect(try reader.dataVersion != initial, "A commit on another connection changes the version")
    }

    // MARK: Conversation graph presentation

    func testGraphNodeStatusUsesShapeForEveryAgent() throws {
        typealias G = SessionGroupGraph
        try expectEqual(G.status(phase: .working, blocked: false).shape, .working)
        try expectEqual(G.status(phase: .idle, blocked: false).shape, .idle)
        try expectEqual(G.status(phase: .approval, blocked: false).shape, .attention)
        try expectEqual(G.status(phase: .input, blocked: false).shape, .attention)
        for phase in [SessionPhase?.none, .unknown, .ended] {
            try expectEqual(G.status(phase: phase, blocked: false).shape, .unknown)
            try expect(!G.status(phase: phase, blocked: false).filled, "An unknown state has no fill")
        }
        let blocked = G.status(phase: .idle, blocked: true)
        try expectEqual(blocked.title, "전달 막힘")
        try expectEqual(blocked.phaseTitle, "대기 중", "The fill of a blocked node still follows its phase")
        try expectEqual(G.status(phase: nil, blocked: false).title, "상태 미확인")
        let approval = G.status(phase: .approval, blocked: false), input = G.status(phase: .input, blocked: false)
        try expectEqual([approval.title, input.title], ["응답 필요", "응답 필요"], "Legend, list and panel heading use one name")
        try expectEqual([approval.detailTitle, input.detailTitle], ["승인 대기", "입력 대기"], "Only the panel details tell them apart")
        try expect(approval.needsResponse && input.needsResponse && !G.status(phase: .working, blocked: false).needsResponse)
        try expectEqual(G.detailTitle(.working), "작업 중")
    }

    func testGraphNamesPreferNicknamesAndKeepProvisionalNamesDistinct() throws {
        func member(_ title: String, _ cwd: String) -> SessionGroupMember {
            SessionGroupMember(agent: .codex, title: title, cwd: cwd, conversationID: UUID().uuidString.lowercased())
        }
        let members = [member("터미널 제목 미확인", "/fixture/shop"), member("결제 정리", "/fixture/shop"),
                       member("터미널 제목 미확인", "/fixture/shop"), member("로그 정리", "/fixture/logs"),
                       member("중복 이름", "/fixture/a"), member("중복 이름", "/fixture/b"), member("", "")]
        let group = SessionGroup(name: "fixture", members: members)
        let names = SessionGroupGraph.names(group: group, liveNicknames: [members[0].id: "주문 검토", members[1].id: ""])
        try expectEqual(names[members[0].id], .init(text: "주문 검토", provisional: false), "A connected nickname wins")
        try expectEqual(names[members[1].id], .init(text: "shop · 2", provisional: true), "A connected member without a nickname is provisional")
        try expectEqual(names[members[2].id], .init(text: "shop · 3", provisional: true), "An unconfirmed terminal title is not a name")
        try expectEqual(names[members[3].id], .init(text: "로그 정리", provisional: false), "A unique stored title names an unconnected member")
        try expectEqual(names[members[4].id]?.provisional, true, "A stored title used twice does not tell members apart")
        try expectEqual(names[members[5].id]?.text, "b · 6")
        try expectEqual(names[members[6].id]?.text, "Codex · 7", "A member without a folder uses its agent")
    }

    func testGraphEdgesSplitRecentPendingAndOlderRecords() throws {
        let a = UUID(), b = UUID(), c = UUID(), outsider = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        var records = [SessionGroupGraph.Record]()
        for minute in [1.0, 5, 29.9] { records.append(.init(from: a, to: b, createdAt: at(minute), kind: .record)) }
        records.append(.init(from: a, to: b, createdAt: at(30.5), kind: .record))
        records.append(.init(from: b, to: a, createdAt: at(240), kind: .pendingQuestion))
        records.append(.init(from: b, to: a, createdAt: at(10), kind: .record))
        records.append(.init(from: c, to: a, createdAt: at(120), kind: .expiredQuestion))
        records.append(.init(from: c, to: b, createdAt: at(120), kind: .record))
        records.append(.init(from: a, to: outsider, createdAt: at(1), kind: .record))
        records.append(.init(from: a, to: a, createdAt: at(1), kind: .record))
        let members: Set = [a, b, c]
        let recent = SessionGroupGraph.edges(records, members: members, scope: .recent, now: now)
        try expectEqual(recent.count, 2, "Older records, expired questions, outsiders and self messages stay off the recent view")
        let ab = recent.first { $0.from == a && $0.to == b }, ba = recent.first { $0.from == b && $0.to == a }
        try expectEqual(ab?.kind, .recent); try expectEqual(ab?.count, 3); try expectEqual(ab?.width, 3)
        try expectEqual(ba?.kind, .pendingQuestion, "A waiting question shows regardless of age")
        try expectEqual(ba?.pendingQuestions, 1); try expectEqual(ba?.count, 2)
        let all = SessionGroupGraph.edges(records, members: members, scope: .all, now: now)
        try expectEqual(all.first { $0.from == a && $0.to == b }?.count, 4)
        try expectEqual(all.first { $0.from == c && $0.to == a }?.dashed, true, "An expired question is a faded dashed line")
        try expectEqual(all.first { $0.from == c && $0.to == b }?.faded, true)
        try expectEqual(all.last?.kind, .pendingQuestion, "Waiting questions are drawn last, over other lines")
        try expectEqual([1, 2, 4, 5, 9, 10, 40].map(SessionGroupGraph.width(forCount:)), [1.5, 3, 3, 4.5, 4.5, 6, 6])
        let fresh = SessionGroupGraph.freshKeys(previous: Array(recent.prefix(1)), current: all)
        try expect(fresh.allSatisfy { $0.kind == .recent || $0.kind == .pendingQuestion }, "Lines that only aged are not new")
        try expectEqual(fresh.count, 1)
    }

    func testGraphRecordsReadTheMailboxPageWithoutNotices() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-graph-records-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = try SessionGroupMailbox(directory: directory)
        let group = UUID(), a = UUID(), b = UUID()
        let question = try box.enqueue(groupID: group, senderID: a, recipientID: b, kind: .question, text: "fixture question")
        _ = try box.enqueue(groupID: group, senderID: b, recipientID: a, kind: .reply, text: "fixture answer", sourceKey: "answer:" + question.id.uuidString)
        _ = try box.enqueue(groupID: group, senderID: a, recipientID: b, kind: .question, text: "fixture open question")
        _ = try box.enqueue(groupID: group, senderID: b, recipientID: a, kind: .report, text: "fixture report")
        _ = try box.enqueue(groupID: group, senderID: a, recipientID: a, kind: .notice, text: "fixture naming notice")
        let records = SessionGroupGraph.records(try box.conversations(groupID: group))
        try expectEqual(records.count, 4, "Question, answer, open question and report; the notice is not a record")
        try expectEqual(records.filter { $0.kind == .pendingQuestion }.count, 1)
    }

    func testGraphTreeAndCircleLayoutsFollowTreeOrder() throws {
        func member(_ title: String) -> SessionGroupMember {
            SessionGroupMember(agent: .claude, title: title, cwd: "/fixture", conversationID: UUID().uuidString.lowercased())
        }
        var members = ["lead", "a", "a1", "a2", "b", "b1"].map(member)
        members[2].parentMemberID = members[1].id; members[3].parentMemberID = members[1].id; members[5].parentMemberID = members[4].id
        let group = SessionGroup(name: "fixture", members: members, leaderMemberID: members[0].id)
        let tree = SessionGroupGraph.positions(group.treeOrder, hasLeader: true, layout: .tree)
        func at(_ index: Int) -> CGPoint { tree[members[index].id] ?? CGPoint(x: -1, y: -1) }
        try expectEqual([at(2).x, at(3).x, at(5).x], [0, 144, 288], "Leaves are 144pt apart from the left")
        try expectEqual(at(1).x, 72, "A parent sits over the middle of its children")
        try expectEqual(at(4).x, 288)
        try expectEqual(at(0).x, 180, "The leader centres over its children")
        try expectEqual([at(0).y, at(1).y, at(2).y], [0, 104, 208], "Layers are 104pt apart")
        let flat = SessionGroupGraph.positions(SessionGroup(name: "peers", members: members).treeOrder, hasLeader: false, layout: .tree)
        try expect(Set(flat.values.map(\.y)) == [0], "A group without a leader is one row")
        let circle = SessionGroupGraph.positions(group.treeOrder, hasLeader: true, layout: .circle)
        try expectEqual(circle[members[0].id], .zero, "The leader is in the middle")
        let first = group.treeOrder[1].member.id, second = group.treeOrder[2].member.id
        try expectEqual(circle[first], CGPoint(x: 0, y: -160), "The ring starts at 12 o'clock with the minimum radius")
        try expect((circle[second]?.x ?? 0) > 0, "The ring goes clockwise")
        let large = SessionGroup(name: "large", members: (0..<15).map { member("m\($0)") })
        let ring = SessionGroupGraph.positions(large.treeOrder, hasLeader: false, layout: .circle)
        let radius = hypot(ring[large.members[0].id]!.x, ring[large.members[0].id]!.y)
        try expectEqual(radius, (15 * 144 / (2 * Double.pi)).rounded(), "A large ring keeps 144pt between neighbours")
        let frame = SessionGroupGraph.frame(tree)
        try expectEqual(frame.points[members[2].id].map { Double($0.x) }, SessionGroupGraph.horizontalMargin)
        try expectEqual(frame.size.width, 288 + 2 * SessionGroupGraph.horizontalMargin, "No compression: the frame grows with the graph")
    }

    func testGraphLineGeometryAvoidsFalseConnections() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let points = [a: CGPoint(x: 0, y: 0), b: CGPoint(x: 200, y: 0), c: CGPoint(x: 400, y: 4)]
        func edge(_ from: UUID, _ to: UUID) -> SessionGroupGraph.Edge { .init(from: from, to: to, kind: .recent, count: 1, pendingQuestions: 0) }
        let through = SessionGroupGraph.bends([edge(a, b), edge(b, c)], points: points)
        try expect(through[edge(a, b).key]! * through[edge(b, c).key]! < 0, "Two lines continuing straight through a node bend to opposite sides")
        let opposite = SessionGroupGraph.bends([edge(a, b), edge(c, b)], points: points)
        try expect(opposite[edge(a, b).key]! * opposite[edge(c, b).key]! > 0, "Lines already on opposite sides stay as they are")
        let bent = SessionGroupGraph.bends([edge(a, b), edge(b, c)], points: [a: .zero, b: CGPoint(x: 200, y: 0), c: CGPoint(x: 200, y: 200)])
        try expect(bent.values.allSatisfy { $0 == 1 }, "A corner is not a straight continuation")
        guard let forward = SessionGroupGraph.geometry(from: points[a]!, to: points[b]!, width: 3, bend: 1),
              let backward = SessionGroupGraph.geometry(from: points[b]!, to: points[a]!, width: 3, bend: 1) else { throw AppError.message("geometry missing") }
        try expect(forward.control.y * backward.control.y < 0, "The two directions between one pair never overlap")
        try expectEqual(hypot(forward.tip.x - 200, forward.tip.y - 0).rounded(), 22, "The arrow stops outside the node ring")
        let head = hypot(forward.tip.x - (forward.headLeft.x + forward.headRight.x) / 2, forward.tip.y - (forward.headLeft.y + forward.headRight.y) / 2)
        try expect(abs(head - 12.5) < 0.001, "Arrowhead length is width × 2.5 + 5")
        try expect(SessionGroupGraph.geometry(from: .zero, to: CGPoint(x: 30, y: 0), width: 1.5, bend: 1) == nil, "Overlapping nodes draw no line")
        guard let marked = SessionGroupGraph.geometry(from: points[a]!, to: points[b]!, width: 3, bend: 1, endClearance: SessionGroupGraph.markClearance)
        else { throw AppError.message("marked geometry missing") }
        try expectEqual(hypot(marked.tip.x - 200, marked.tip.y).rounded(), 30, "The arrow stops clear of a warning or bubble mark")
    }

    /// The leader's line to a grandchild must not run under the parent's circle or name band.
    func testGraphLinesBendAroundUnrelatedNodes() throws {
        let lead = UUID(), middle = UUID(), child = UUID(), straight = UUID(), through = UUID(), below = UUID()
        let points = [lead: CGPoint(x: 216, y: 0), middle: CGPoint(x: 360, y: 104), child: CGPoint(x: 432, y: 208),
                      straight: CGPoint(x: 600, y: 0), through: CGPoint(x: 600, y: 104), below: CGPoint(x: 600, y: 208)]
        func edge(_ from: UUID, _ to: UUID) -> SessionGroupGraph.Edge { .init(from: from, to: to, kind: .older, count: 1, pendingQuestions: 0) }
        try expect(SessionGroupGraph.crossings(from: points[lead]!, to: points[child]!, width: 1.5, bend: 1, nodes: [points[middle]!]) > 0,
                   "The fixture line starts out under the middle node")
        for line in [edge(lead, child), edge(straight, below)] {
            let bends = SessionGroupGraph.bends([line], points: points)
            let others = points.filter { $0.key != line.from && $0.key != line.to }.map(\.value)
            try expectEqual(SessionGroupGraph.crossings(from: points[line.from]!, to: points[line.to]!, width: line.width,
                                                        bend: bends[line.key]!, nodes: others), 0, "The line passes clear of other nodes")
        }
        // With a reverse line the pair keeps opposite sides, so the bend only grows on its own side.
        let pair = SessionGroupGraph.bends([edge(lead, child), edge(child, lead)], points: points)
        try expect(pair[edge(lead, child).key]! > 0 && pair[edge(child, lead).key]! > 0, "Both directions keep their own side")
        let clear = SessionGroupGraph.bends([edge(lead, middle)], points: points)
        try expectEqual(clear[edge(lead, middle).key], 1, "A line already clear keeps the normal bend")
    }

    func testGraphScreenAndGraphCoordinatesConvertBothWays() throws {
        let view = SessionGroupGraph.Viewport(scale: 2, offset: CGPoint(x: -30, y: 12))
        try expectEqual(view.screen(CGPoint(x: 100, y: 50)), CGPoint(x: 170, y: 112), "Screen = graph × scale + offset")
        try expectEqual(view.graph(CGPoint(x: 170, y: 112)), CGPoint(x: 100, y: 50), "Graph = (screen − offset) ÷ scale")
        try expectEqual(view.visible(CGSize(width: 400, height: 200)), CGRect(x: 15, y: -6, width: 200, height: 100),
                        "The visible graph part is the area divided by the scale")
        let half = SessionGroupGraph.Viewport(scale: 0.5, offset: CGPoint(x: 40, y: 0))
        let point = CGPoint(x: 333, y: -21)
        let back = half.graph(half.screen(point))
        try expect(abs(back.x - point.x) < 1e-9 && abs(back.y - point.y) < 1e-9, "A round trip returns the same point")
        // A drag of t screen points moves a node t ÷ scale graph points, so it stays under the pointer.
        let node = CGPoint(x: 120, y: 80), translation = CGVector(dx: 50, dy: -30)
        let pressed = view.screen(node)
        let moved = view.screen(CGPoint(x: node.x + translation.dx / view.scale, y: node.y + translation.dy / view.scale))
        try expectEqual(moved, CGPoint(x: pressed.x + translation.dx, y: pressed.y + translation.dy), "The dragged node follows the pointer")
    }

    func testGraphZoomKeepsThePointUnderThePointer() throws {
        let view = SessionGroupGraph.Viewport(scale: 1, offset: CGPoint(x: 20, y: 10))
        let pointer = CGPoint(x: 300, y: 200)
        let under = view.graph(pointer)
        for target in [0.5, 2, 3] {
            let zoomed = view.zoomed(to: target, around: pointer)
            try expectEqual(zoomed.scale, target)
            let after = zoomed.screen(under)
            try expect(abs(after.x - pointer.x) < 1e-9 && abs(after.y - pointer.y) < 1e-9, "The graph point under the pointer stays there at \(target)")
        }
        try expectEqual(view.zoomed(to: 9, around: pointer).scale, 3, "Zoom stops at 300%")
        try expectEqual(view.zoomed(to: 0.1, around: pointer).scale, 0.25, "Zoom stops at 25%")
        try expectEqual(SessionGroupGraph.steppedZoom(from: 1, larger: true), 1.25)
        try expectEqual(SessionGroupGraph.steppedZoom(from: 1, larger: false), 0.8)
        try expectEqual(SessionGroupGraph.steppedZoom(from: 0.9, larger: true), 1, "A scale between steps goes to the nearest step")
        try expectEqual(SessionGroupGraph.steppedZoom(from: 0.9, larger: false), 0.8)
        try expectEqual(SessionGroupGraph.steppedZoom(from: 3, larger: true), 3, "+ stays at 300%")
        try expectEqual(SessionGroupGraph.steppedZoom(from: 0.25, larger: false), 0.25, "− stays at 25%")
    }

    func testGraphFitKeepsTheWholeGraphOrTheLeaderInView() throws {
        let area = CGSize(width: 400, height: 300)
        let small = CGRect(x: 0, y: 0, width: 200, height: 100)
        let centred = SessionGroupGraph.fit(small, in: area, minimum: SessionGroupGraph.automaticFitMinimum, focus: nil)
        try expectEqual(centred.scale, 1, "A small graph is not enlarged")
        try expectEqual(centred.offset, CGPoint(x: 100, y: 100), "A small graph is centred")
        let medium = CGRect(x: -100, y: 0, width: 600, height: 300)
        let shrunk = SessionGroupGraph.fit(medium, in: area, minimum: SessionGroupGraph.automaticFitMinimum, focus: nil)
        try expect(abs(shrunk.scale - 2.0 / 3) < 1e-9, "A larger graph shrinks until it fits")
        try expect(abs(shrunk.screen(CGPoint(x: -100, y: 0)).x) < 1e-9 && abs(shrunk.screen(CGPoint(x: 500, y: 0)).x - 400) < 1e-9,
                   "The fitted graph fills the width exactly")
        let huge = CGRect(x: 0, y: 0, width: 2000, height: 300)
        let leader = CGPoint(x: 1500, y: 36)
        let floored = SessionGroupGraph.fit(huge, in: area, minimum: SessionGroupGraph.automaticFitMinimum, focus: leader)
        try expectEqual(floored.scale, 0.6, "Fitting on open never goes below 60%")
        let shown = floored.screen(leader)
        try expect(shown.x >= 0 && shown.x <= area.width, "A graph still too large keeps the leader in view")
        try expect(floored.screen(CGPoint(x: 0, y: 0)).x <= 0 && floored.screen(CGPoint(x: 2000, y: 0)).x >= area.width,
                   "No empty space shows beside a graph larger than the area")
        let everything = SessionGroupGraph.fit(huge, in: area, minimum: SessionGroupGraph.minimumZoom, focus: leader)
        try expectEqual(everything.scale, 0.25, "The fit button may go down to 25%")
        let fixed = SessionGroupGraph.fit(small, in: area, minimum: 2, maximum: 2, focus: CGPoint(x: 100, y: 36))
        try expectEqual(fixed.scale, 2, "A fixed scale keeps that scale")
        let bounds = SessionGroupGraph.contentBounds([UUID(): CGPoint(x: 10, y: 20), UUID(): CGPoint(x: 210, y: 124)])
        try expectEqual(bounds, CGRect(x: 10 - SessionGroupGraph.horizontalMargin, y: 20 - SessionGroupGraph.topMargin,
                                       width: 200 + 2 * SessionGroupGraph.horizontalMargin,
                                       height: 104 + SessionGroupGraph.topMargin + SessionGroupGraph.bottomMargin),
                        "Content bounds keep the frame margins around node centres")
    }

    func testGraphPanKeepsPartOfTheGraphInView() throws {
        let area = CGSize(width: 400, height: 300)
        let content = CGRect(x: 0, y: 0, width: 600, height: 200)
        let lost = SessionGroupGraph.Viewport(scale: 1, offset: CGPoint(x: -2000, y: 900))
        let kept = SessionGroupGraph.constrained(lost, content: content, size: area)
        try expectEqual(kept.offset, CGPoint(x: -600 + 80, y: 300 - 80), "80pt of the graph stays inside the area")
        let inside = SessionGroupGraph.Viewport(scale: 1, offset: CGPoint(x: -50, y: 20))
        try expectEqual(SessionGroupGraph.constrained(inside, content: content, size: area), inside, "A view inside the limits is unchanged")
        let tiny = CGRect(x: 0, y: 0, width: 40, height: 40)
        let gone = SessionGroupGraph.Viewport(scale: 1, offset: CGPoint(x: 1000, y: 0))
        try expectEqual(SessionGroupGraph.constrained(gone, content: tiny, size: area).offset.x, 360, "A graph smaller than 80pt stays whole")
    }

    func testGraphNodeSizeFollowsMessageSteps() throws {
        let steps = [0, 1, 4, 5, 19, 20, 300].map { SessionGroupGraph.nodeSize(forMessages: $0) }
        try expectEqual(steps, [.none, .few, .few, .some, .some, .many, .many], "Four steps: 0, 1-4, 5-19, 20 or more")
        try expectEqual(SessionGroupGraph.NodeSize.allCases.map(\.diameter), [28, 32, 36, 40])
        let a = UUID(), b = UUID(), c = UUID()
        let edges: [SessionGroupGraph.Edge] = [.init(from: a, to: b, kind: .recent, count: 3, pendingQuestions: 0),
                                               .init(from: b, to: a, kind: .recent, count: 2, pendingQuestions: 0),
                                               .init(from: c, to: b, kind: .pendingQuestion, count: 1, pendingQuestions: 1)]
        try expectEqual(SessionGroupGraph.messageCount(member: a, edges: edges), 5, "Sent and received records both count")
        try expectEqual(SessionGroupGraph.messageCount(member: b, edges: edges), 6)
        try expectEqual(SessionGroupGraph.messageCount(member: UUID(), edges: edges), 0)
    }

    /// Larger circles widen the layer below them and the ring, so no two nodes' circles and name
    /// bands overlap, and the same sizes always give the same positions.
    func testGraphLayoutMakesRoomForLargeNodes() throws {
        func member(_ title: String) -> SessionGroupMember {
            SessionGroupMember(agent: .claude, title: title, cwd: "/fixture", conversationID: UUID().uuidString.lowercased())
        }
        var members = ["lead", "a", "a1", "a2", "b", "b1", "b2"].map(member)
        members[2].parentMemberID = members[1].id; members[3].parentMemberID = members[1].id
        members[5].parentMemberID = members[4].id; members[6].parentMemberID = members[4].id
        let group = SessionGroup(name: "fixture", members: members, leaderMemberID: members[0].id)
        let order = group.treeOrder.map { (id: $0.member.id, depth: $0.depth) }
        let big = Dictionary(uniqueKeysWithValues: members.enumerated().map { ($1.id, $0 % 2 == 0 ? 40.0 : 28.0) })
        func overlaps(_ points: [UUID: CGPoint]) -> [String] {
            var found: [String] = []
            let ids = Array(points.keys)
            for i in ids.indices { for j in ids.indices where j > i {
                let first = SessionGroupGraph.nodeArea(points[ids[i]]!, radius: (big[ids[i]] ?? 32) / 2)
                let second = SessionGroupGraph.nodeArea(points[ids[j]]!, radius: (big[ids[j]] ?? 32) / 2)
                if first.intersects(second) { found.append("\(i)-\(j)") }
            } }
            return found
        }
        for layout in SessionGroupGraph.Layout.allCases {
            let points = SessionGroupGraph.positions(order, hasLeader: true, layout: layout, diameters: big)
            try expectEqual(overlaps(points), [], "No two nodes overlap in the \(layout) layout")
            try expectEqual(points, SessionGroupGraph.positions(order, hasLeader: true, layout: layout, diameters: big),
                            "The same sizes give the same positions in the \(layout) layout")
        }
        let standard = SessionGroupGraph.positions(order, hasLeader: true, layout: .tree)
        let widened = SessionGroupGraph.positions(order, hasLeader: true, layout: .tree, diameters: big)
        try expectEqual(standard[members[1].id]!.y - standard[members[0].id]!.y, 104, "32pt circles keep 104pt layers")
        // The leader layer and the next layer both hold a 40pt circle: 20 + 26 + 46 + 20.
        try expectEqual(widened[members[1].id]!.y - widened[members[0].id]!.y, 112, "A layer of large circles moves the next layer down")
        let leaves = [members[2].id, members[3].id].map { widened[$0]!.x }
        try expectEqual(leaves[1] - leaves[0], 144 + 8, "Leaves in a layer with a 40pt circle are 8pt further apart")
        let small = Dictionary(uniqueKeysWithValues: members.map { ($0.id, 28.0) })
        try expectEqual(SessionGroupGraph.positions(order, hasLeader: true, layout: .tree, diameters: small), standard,
                        "Small circles never pull the layout tighter than the standard spacing")
        let ring = SessionGroupGraph.positions(order, hasLeader: true, layout: .circle, diameters: big)
        let first = group.treeOrder[1].member.id
        try expectEqual(hypot(ring[first]!.x, ring[first]!.y), 168, "The ring radius grows by the largest circle's extra 8pt")
        guard let line = SessionGroupGraph.geometry(from: .zero, to: CGPoint(x: 200, y: 0), width: 1.5, bend: 1, startRadius: 20, endRadius: 14)
        else { throw AppError.message("geometry missing") }
        try expectEqual(hypot(line.start.x, line.start.y).rounded(), 26, "A line starts 6pt outside a 40pt circle")
        try expectEqual(hypot(line.tip.x - 200, line.tip.y).rounded(), 20, "A line ends 6pt outside a 28pt circle")
        try expectEqual(SessionGroupGraph.markClearance(radius: 20), 10, "The mark room grows with the circle")
        let frame = SessionGroupGraph.frame(widened, largestDiameter: 40)
        try expectEqual(frame.points.values.map(\.y).min(), SessionGroupGraph.topMargin + 4, "The top margin grows with the largest circle")
    }

    func testGraphAccessibilityValueDescribesRelations() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let edges: [SessionGroupGraph.Edge] = [.init(from: a, to: b, kind: .recent, count: 3, pendingQuestions: 0),
                                               .init(from: c, to: a, kind: .pendingQuestion, count: 2, pendingQuestions: 2)]
        let value = SessionGroupGraph.accessibilityValue(member: a, status: SessionGroupGraph.status(phase: .working, blocked: true),
                                                         edges: edges, names: [b: "api 정리", c: "테스트 보강"])
        try expectEqual(value, "작업 중. 주고받은 메시지 5건. 보냄 api 정리 3건. 받음 테스트 보강 2건. 답을 기다리는 질문 2건. 전달 막힘")
    }

    /// The leader is in the middle, each depth one ring further out, a subtree inside a sector that
    /// grows with its leaves, and no two nodes overlap even with large circles in a wide group.
    func testGraphRadialLayoutKeepsSubtreesInSectorsWithoutOverlap() throws {
        func member(_ title: String) -> SessionGroupMember {
            SessionGroupMember(agent: .claude, title: title, cwd: "/fixture", conversationID: UUID().uuidString.lowercased())
        }
        var members = ["lead", "a", "a1", "a2", "a3", "b", "b1"].map(member)
        for index in [2, 3, 4] { members[index].parentMemberID = members[1].id }
        members[6].parentMemberID = members[5].id
        let group = SessionGroup(name: "fixture", members: members, leaderMemberID: members[0].id)
        let radial = SessionGroupGraph.positions(group.treeOrder, hasLeader: true, layout: .radial)
        func at(_ index: Int) -> CGPoint? { radial[members[index].id] }
        try expectEqual(at(0), .zero, "The leader is in the middle")
        // Four leaves, 90 degrees each from 12 o'clock: a's three leaves take 0, 90 and 180 degrees, so
        // a sits at 90 degrees; b1 takes 270 degrees with b. The first ring is one 144pt spacing out,
        // and the second one more, which also keeps its 90-degree neighbours 144pt or more apart.
        try expectEqual(at(1), CGPoint(x: 144, y: 0), "A parent sits in the middle of its children's sector")
        try expectEqual(at(5), CGPoint(x: -144, y: 0))
        try expectEqual([at(2), at(3), at(4), at(6)], [CGPoint(x: 0, y: -288), CGPoint(x: 288, y: 0), CGPoint(x: 0, y: 288), CGPoint(x: -288, y: 0)],
                        "Leaves go clockwise from 12 o'clock on the next ring")
        let peers = SessionGroupGraph.positions(SessionGroup(name: "peers", members: members).treeOrder, hasLeader: false, layout: .radial)
        // Seven members 51.4 degrees apart need a 166pt ring to keep neighbours 144pt apart.
        try expect(peers.values.allSatisfy { abs(hypot($0.x, $0.y) - 166) < 1 }, "Without a leader every member is on the first ring")
        try expectEqual(peers[members[0].id], CGPoint(x: 0, y: -166), "The first ring starts at 12 o'clock")
        // A wide group: three branches of four, two with a deeper member, large and small circles mixed.
        var wide = [member("lead")]
        for branch in 0..<3 {
            var head = member("h\(branch)"); head.parentMemberID = nil
            wide.append(head)
            for leaf in 0..<4 {
                var child = member("h\(branch)-\(leaf)"); child.parentMemberID = head.id
                wide.append(child)
                if leaf == 1 && branch < 2 { var deep = member("d\(branch)"); deep.parentMemberID = child.id; wide.append(deep) }
            }
        }
        let wideGroup = SessionGroup(name: "wide", members: wide, leaderMemberID: wide[0].id)
        let sizes = Dictionary(uniqueKeysWithValues: wide.enumerated().map { ($1.id, $0 % 3 == 0 ? 40.0 : 28.0) })
        let points = SessionGroupGraph.positions(wideGroup.treeOrder, hasLeader: true, layout: .radial, diameters: sizes)
        try expectEqual(points.count, wide.count, "Every member is placed")
        let ids = Array(points.keys)
        var overlaps = 0
        for i in ids.indices { for j in ids.indices where j > i {
            let first = SessionGroupGraph.nodeArea(points[ids[i]]!, radius: sizes[ids[i]]! / 2)
            if first.intersects(SessionGroupGraph.nodeArea(points[ids[j]]!, radius: sizes[ids[j]]! / 2)) { overlaps += 1 }
        } }
        try expectEqual(overlaps, 0, "No two nodes overlap in a wide radial layout with 40pt circles")
        try expectEqual(points, SessionGroupGraph.positions(wideGroup.treeOrder, hasLeader: true, layout: .radial, diameters: sizes),
                        "The same sizes give the same positions")
        try expectEqual(SessionGroupGraph.radialSpacing(largestDiameter: 40), 152, "Rings move apart by the largest circle's extra size")
        try expect(SessionGroupGraph.positions(group.treeOrder, hasLeader: true, layout: .matrix).isEmpty, "The matrix places no nodes")
    }

    /// Rows are senders and columns recipients in tree order; a cell holds the current view's
    /// records and waiting questions, shaded in the line width steps.
    func testGraphMatrixCountsSentAndReceivedRecords() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let edges: [SessionGroupGraph.Edge] = [.init(from: a, to: b, kind: .recent, count: 3, pendingQuestions: 0),
                                               .init(from: c, to: a, kind: .pendingQuestion, count: 2, pendingQuestions: 2)]
        let grid = SessionGroupGraph.matrix(order: [a, b, c], edges: edges)
        try expectEqual(grid.count, 3)
        try expectEqual(grid[0][1], .init(from: a, to: b, count: 3, pendingQuestions: 0), "Row a, column b: a sent 3 to b")
        try expectEqual(grid[1][0].count, 0, "b sent nothing to a; the reverse direction is its own cell")
        try expectEqual(grid[2][0].pendingQuestions, 2, "Questions waiting for a's answer are in c's row")
        try expect(grid[1][1].isSelf && grid[1][1].count == 0, "The diagonal is empty")
        try expectEqual([0, 1, 2, 4, 5, 9, 10, 40].map(SessionGroupGraph.matrixShade(forCount:)), [0, 1, 2, 2, 3, 3, 4, 4],
                        "Shades follow the line width steps")
        try expectEqual(SessionGroupGraph.matrixCellRect(row: 1, column: 2), CGRect(x: 320, y: 124, width: 76, height: 40))
        try expectEqual(SessionGroupGraph.matrixRowHeaderRect(1), CGRect(x: 16, y: 124, width: 152, height: 40))
        try expectEqual(SessionGroupGraph.matrixColumnHeaderRect(2), CGRect(x: 320, y: 16, width: 76, height: 68))
        try expectEqual(SessionGroupGraph.matrixContent(count: 3), CGRect(x: 0, y: 0, width: 412, height: 220))
        try expectEqual(SessionGroupGraph.matrixCellAccessibility(from: "api 정리", to: "테스트 보강", cell: grid[0][1]),
                        "api 정리 → 테스트 보강: 3건, 미응답 0건")
    }

    func testGraphMatrixKeyboardMovesBetweenCellsAndHeaders() throws {
        typealias Spot = SessionGroupGraph.MatrixSpot
        func move(_ spot: Spot, _ direction: SessionGroupGraph.MatrixDirection) -> Spot {
            SessionGroupGraph.matrixMove(spot, direction, count: 3)
        }
        try expectEqual(move(.cell(row: 1, column: 1), .right), .cell(row: 1, column: 2))
        try expectEqual(move(.cell(row: 1, column: 2), .right), .cell(row: 1, column: 2), "The last column stops")
        try expectEqual(move(.cell(row: 2, column: 0), .down), .cell(row: 2, column: 0), "The last row stops")
        try expectEqual(move(.cell(row: 1, column: 0), .left), .rowHeader(1), "Left of the first column is the row header")
        try expectEqual(move(.cell(row: 0, column: 2), .up), .columnHeader(2), "Above the first row is the column header")
        try expectEqual(move(.rowHeader(1), .right), .cell(row: 1, column: 0))
        try expectEqual(move(.rowHeader(0), .up), .rowHeader(0))
        try expectEqual(move(.rowHeader(0), .down), .rowHeader(1))
        try expectEqual(move(.columnHeader(2), .down), .cell(row: 0, column: 2))
        try expectEqual(move(.columnHeader(0), .left), .columnHeader(0))
        try expectEqual(move(.columnHeader(0), .right), .columnHeader(1))
    }
}
