import SwiftUI
import AppKit
import Combine
import QuartzCore
import CSQLite
import AutoApproveCore

private final class GroupRefreshReads: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func read() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor enum GroupRefreshProbe {
    static var bodies = 0
    static var names: [String] = []
    static func observe(_ groups: [SessionGroup]) { bodies += 1; names = groups.map(\.name) }
}

/// The render script inserts calls to this probe into the graph sources for
/// `--verify-drag` and `--verify-graph-refresh`. Nothing else calls it.
@MainActor enum GraphProbe {
    static var roots = 0
    static var canvases = 0
    static var frames = 0
    static var firstFrame: CFTimeInterval?
    static var messageCount = -1
    static func root() { roots += 1 }
    static func root(_ messages: Int?) { roots += 1; messageCount = messages ?? -1 }
    static func canvas() { canvases += 1 }
    static var places: [String: CGPoint] = [:]
    /// Each node's circle and name band in SwiftUI global coordinates.
    static var rects: [String: CGRect] = [:]
    static func place(_ name: String, _ point: CGPoint) { places[name] = point }
    static func place(_ name: String, _ point: CGPoint, frame: CGRect) { places[name] = point; rects[name] = frame }
    /// Pairs of nodes whose circle and name band overlap, ignoring a sliver of half a point.
    static func overlaps() -> [String] {
        let names = rects.keys.sorted()
        var found: [String] = []
        for (i, a) in names.enumerated() { for b in names[(i + 1)...] {
            let shared = rects[a]!.intersection(rects[b]!)
            if !shared.isNull, shared.width > 0.5, shared.height > 0.5 { found.append(a + " / " + b) }
        } }
        return found
    }
    /// SwiftUI global coordinates start at the top left of the hosting view.
    static func center(_ name: String, in host: NSView) -> CGPoint? {
        places[name].map { CGPoint(x: $0.x, y: host.bounds.height - $0.y) }
    }
    static func frame() { frames += 1; if firstFrame == nil { firstFrame = CACurrentMediaTime() } }
    static var beganAt: CFTimeInterval?
    static func began() { if beganAt == nil { beganAt = CACurrentMediaTime() } }
    /// The zoom and pan of the graph area at its last body evaluation.
    static var view: SessionGroupGraph.Viewport?
    static func viewport(_ value: SessionGroupGraph.Viewport) { view = value }
    /// The lifted node's circle centre in window coordinates at the last display frame.
    static var previewCenter: CGPoint?
    static func preview(_ point: CGPoint) { previewCenter = point }
}

/// Counts storage checks and records whether any ran on the main thread.
final class GraphReadProbe: @unchecked Sendable {
    static let shared = GraphReadProbe()
    private let lock = NSLock()
    private var checks = 0, onMain = 0
    func check() {
        lock.lock(); defer { lock.unlock() }
        checks += 1
        if pthread_main_np() != 0 { onMain += 1 }
    }
    var value: (checks: Int, onMain: Int) { lock.lock(); defer { lock.unlock() }; return (checks, onMain) }
}

/// Invented members, folders and messages only. The repository is public.
@MainActor struct GraphFixture {
    let engine: ApprovalEngine
    let group: SessionGroup
    let directory: URL
    let now: Date
    let id: [String: UUID]

    nonisolated static let fixedNow = Date(timeIntervalSince1970: 1_795_149_725) // 2026-11-20 13:42:05 +0900

    /// `extra` adds that many unconnected members under the four deepest members, for a graph wider than the window.
    /// `burst` adds that many recent messages from the leader to "api 정리", so message amounts differ widely.
    static func make(root: URL, name: String, now: Date = fixedNow, heavy: Bool = false, empty: Bool = false, extra: Int = 0,
                     burst: Int = 0) throws -> GraphFixture {
        let directory = root.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: directory)
        // key, agent, connected nickname (nil: no nickname), stored title, folder, parent key
        let plan: [(String, AgentKind, String?, String, String, String?)] = [
            ("lead", .claude, "결제 총괄", "결제 총괄", "/fixture/payments", nil),
            ("api", .codex, "api 정리", "api 정리", "/fixture/payments/api", "lead"),
            ("test", .codex, "테스트 보강", "테스트 보강", "/fixture/payments/tests", "api"),
            ("fix", .claude, nil, "터미널 제목 미확인", "/fixture/payments/fixture", "api"),
            ("doc", .claude, "문서 검토", "문서 검토", "/fixture/payments/docs", "lead"),
            ("mig", .codex, "마이그레이션", "마이그레이션", "/fixture/payments/migrate", "doc"),
            ("log", .codex, nil, "로그 정리", "/fixture/payments/logs", "mig"),
            ("ui", .claude, "화면 점검", "화면 점검", "/fixture/payments/screens", "doc")
        ] + (0..<extra).map { index -> (String, AgentKind, String?, String, String, String?) in
            ("extra\(index)", index % 2 == 0 ? AgentKind.codex : .claude, nil, "보조 작업 \(index + 1)",
             "/fixture/payments/extra\(index + 1)", ["test", "fix", "log", "ui"][index % 4])
        }
        let connected = plan.filter { $0.2 != nil }
        let lines = connected.enumerated().map { index, entry in
            "\(100_600 + index) 1 graph\(index) \(100_600 + index) \(100_600 + index) Fri Nov 20 09:00:00 2026 /fixture/\(entry.1 == .codex ? "codex" : "claude")"
        }
        let records = ProcessDiscovery.parse(lines.joined(separator: "\n"))
        var sessions: [String: AgentSession] = [:]
        for (index, entry) in connected.enumerated() {
            guard let record = records.first(where: { $0.pid == 100_600 + index }) else { throw AppError.message("fixture record missing") }
            sessions[entry.0] = AgentSession(id: record.key, agent: entry.1, pid: record.pid, started: record.started,
                                             tty: "/dev/" + record.tty, cwd: entry.4, terminal: .terminal)
        }
        let transport = CodexReplyTransport(prepare: { _, _ in throw AppError.message("unused") },
            send: { _, _ in throw AppError.message("never send") },
            queueHome: { _ in .init(executable: "", home: "/tmp/graph-fixture-home", threadID: "") })
        let queue = CodexQueueTransport(list: { _ in [] }, delete: { _, _ in .init(removed: []) }, validate: { _, _ in })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), questionTransport: transport,
            claudeRegistryReader: { _ in [] }, processReader: { records }, codexQueue: queue)
        engine.updateDiscovery(Array(sessions.values), records: records)
        for entry in connected {
            if let session = sessions[entry.0], let nickname = entry.2 {
                try engine.setCustomization(session.id, value: SessionCustomization(title: nickname))
            }
        }
        var ids: [String: UUID] = [:]
        var members: [SessionGroupMember] = []
        for entry in plan {
            var member = SessionGroupMember(agent: entry.1, title: entry.3, cwd: entry.4,
                                            conversationID: UUID().uuidString.lowercased(), providerHome: "/tmp/graph-fixture-home")
            member.runtimeID = sessions[entry.0]?.id
            ids[entry.0] = member.id
            members.append(member)
        }
        for (index, entry) in plan.enumerated() {
            if let parent = entry.5, parent != "lead" { members[index].parentMemberID = ids[parent] }
        }
        let group = empty ? SessionGroup(name: "디자인 회의", members: [])
            : SessionGroup(name: "결제 리뷰", members: members, leaderMemberID: ids["lead"])
        try SessionGroupStore(directory: directory).save([group])
        if !empty { try seedMessages(directory: directory, group: group, id: ids, now: now, heavy: heavy, burst: burst) }
        return GraphFixture(engine: engine, group: group, directory: directory, now: now, id: ids)
    }

    private static func seedMessages(directory: URL, group: SessionGroup, id: [String: UUID], now: Date, heavy: Bool, burst: Int = 0) throws {
        let box = try SessionGroupMailbox(directory: directory)
        var acknowledged: [(UUID, UUID)] = []
        func send(_ from: String, _ to: String, _ kind: SessionGroupMessage.Kind, _ text: String,
                  minutes: Double, keep: Bool = false) throws -> SessionGroupMessage {
            guard let sender = id[from], let recipient = id[to] else { throw AppError.message("fixture member missing") }
            let message = try box.enqueue(groupID: group.id, senderID: sender, recipientID: recipient, kind: kind, text: text,
                                          at: now.addingTimeInterval(-minutes * 60))
            if !keep { acknowledged.append((message.id, recipient)) }
            return message
        }
        // Recent 30 minutes
        for i in 0..<3 { _ = try send("lead", "api", .message, "api 응답 형식을 정리해 주세요 \(i + 1)", minutes: Double(4 + i * 6)) }
        _ = try send("api", "lead", .report, "응답 형식 초안을 올렸습니다", minutes: 2)
        _ = try send("lead", "doc", .message, "결제 실패 안내 문구를 검토해 주세요", minutes: 12)
        _ = try send("api", "fix", .message, "샘플 데이터 3건을 추가해 주세요", minutes: 29)
        _ = try send("api", "fix", .message, "환불 케이스도 넣어 주세요", minutes: 9)
        for i in 0..<10 { _ = try send("doc", "mig", .message, "마이그레이션 문서 항목 \(i + 1)을 확인해 주세요", minutes: Double(1 + i * 2)) }
        for i in 0..<6 { _ = try send("mig", "doc", .report, "항목 \(i + 1) 반영했습니다", minutes: Double(2 + i * 3)) }
        _ = try send("ui", "doc", .message, "결제 화면 문구가 바뀌었습니다", minutes: 1)
        _ = try send("doc", "mig", .message, "다음 단계 확인 부탁드립니다", minutes: 3, keep: true)
        // Questions that still wait for an answer, regardless of age
        _ = try send("test", "api", .question, "새 스키마에 맞춰 fixture 를 다시 만들까요?", minutes: 4)
        _ = try send("test", "api", .question, "결제 실패 응답도 테스트에 넣을까요?", minutes: 120)
        // Older than 30 minutes
        _ = try send("log", "mig", .message, "로그 형식을 바꿨습니다", minutes: 31)
        _ = try send("lead", "fix", .message, "fixture 폴더를 정리해 주세요", minutes: 120)
        for i in 0..<3 { _ = try send("ui", "mig", .message, "화면 점검 결과 \(i + 1)", minutes: Double(118 + i)) }
        _ = try send("lead", "ui", .message, "결제 화면을 점검해 주세요", minutes: 125)
        _ = try send("mig", "log", .message, "로그 보관 기간을 알려 주세요", minutes: 122)
        let answered = try send("api", "lead", .question, "응답 코드를 문자열로 바꿔도 될까요?", minutes: 64)
        _ = try box.enqueue(groupID: group.id, senderID: id["lead"]!, recipientID: id["api"]!, kind: .reply,
                            text: "네, 문자열로 바꿔 주세요", sourceKey: "answer:" + answered.id.uuidString,
                            at: now.addingTimeInterval(-60 * 60))
        let expired = try send("test", "lead", .question, "테스트 계정을 새로 만들어도 될까요?", minutes: 118)
        for i in 0..<burst { _ = try send("lead", "api", .message, "응답 필드 \(i + 1)을 확인해 주세요", minutes: 1 + Double(i % 25)) }
        if heavy {
            let keys = ["lead", "api", "test", "doc", "mig", "ui"]
            for i in 0..<300 {
                let from = keys[i % keys.count], to = keys[(i * 7 + 1) % keys.count]
                guard from != to else { continue }
                _ = try send(from, to, .message, "지난 작업 기록 \(i + 1)", minutes: Double(40 + i))
            }
        }
        for (message, recipient) in acknowledged {
            try box.acknowledge([message], groupID: group.id, recipientID: recipient, at: now)
        }
        try insertExpiredWait(directory: directory, group: group.id, member: id["test"]!, question: expired.id, now: now)
    }

    /// The mailbox has no public writer for waits, so the fixture stores an expired wait row directly.
    private static func insertExpiredWait(directory: URL, group: UUID, member: UUID, question: UUID, now: Date) throws {
        guard let parent = realpath(directory.path, nil) else { throw AppError.message("fixture directory missing") }
        let path = String(cString: parent) + "/group-messages.sqlite"; free(parent)
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw AppError.message("fixture database") }
        defer { sqlite3_close(db) }
        let wait = UUID()
        let request = #"{"id":"\#(wait.uuidString)","group":"\#(group.uuidString)","member":"\#(member.uuidString)","tasks":[],"questions":["\#(question.uuidString)"],"external":false,"mode":"all","seconds":600}"#
        let sql = "INSERT INTO group_waits(id,group_id,owner_task,request,state,deadline) VALUES('\(wait.uuidString)','\(group.uuidString)','fixture','\(request)','expired',\(now.addingTimeInterval(-100 * 60).timeIntervalSince1970))"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw AppError.message("fixture wait: " + String(cString: sqlite3_errmsg(db))) }
    }
}

/// A transparent window that never takes mouse events or focus. The harness
/// sends events to its hosting view directly, so the user's front app keeps focus.
@MainActor func hiddenHarnessWindow<Content: View>(_ view: Content, size: CGSize) -> (NSWindow, NSHostingView<Content>) {
    // A prohibited app can never become active, so nothing here can take focus from the user's front app.
    NSApp.setActivationPolicy(.prohibited)
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let window = NSWindow(contentRect: NSRect(origin: screen.origin, size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // 1% opacity: invisible to the user, but the window server still composites it, so display links fire.
    window.alphaValue = 0.01
    window.isOpaque = false
    window.backgroundColor = .clear
    window.ignoresMouseEvents = true
    window.hasShadow = false
    window.level = .floating
    window.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: size)
    window.contentView = host
    window.orderFrontRegardless()
    return (window, host)
}

@MainActor func mouse(_ type: NSEvent.EventType, _ point: CGPoint, _ window: NSWindow, delta: CGVector = .zero) -> NSEvent {
    let base = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                  pressure: type == .leftMouseUp ? 0 : 1)!
    // Drag events also carry the movement deltas a real mouse reports.
    guard type == .leftMouseDragged, let copy = base.cgEvent?.copy() else { return base }
    copy.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.dx))
    copy.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.dy))
    if let value = NSEvent(cgEvent: copy), value.window === window { return value }
    return base
}

/// Measures main-thread time from the moment the app dequeues a drag event until the
/// main run loop is about to sleep again, which includes SwiftUI updates and the Core Animation commit.
@MainActor final class MainBusyMeter {
    var durations: [Double] = []
    var origin: CGPoint = .zero
    var dragStart: CFTimeInterval?
    private var started: CFTimeInterval?
    private var monitor: Any?
    private var observer: CFRunLoopObserver?
    func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                self.started = now
                // The first pointer movement, whatever distance each version waits for before lifting the node.
                if self.dragStart == nil { self.dragStart = now }
            }
            return event
        }
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, let started = self.started else { return }
                self.durations.append((CACurrentMediaTime() - started) * 1000)
                self.started = nil
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
    }
}

/// Same procedure before and after the rewrite: a transparent window that cannot take focus,
/// the same fixture, a press on one node, 60 drag events 2pt apart at about 120 events per
/// second through the app's event queue, and a release. Three trials at each of 100%, 60% and
/// 200%. At each zoom the lifted node's circle centre is compared with the pointer before the
/// release, and the dropped node's centre with the release point.
@MainActor func verifyDrag(root: URL) async throws {
    let frontApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let size = CGSize(width: 1040, height: 680)
    var zooms: [[String: Any]] = []
    var allDurations: [Double] = []
    var allRoots = 0, allCanvases = 0
    var worstPreview = 0.0, worstDrop = 0.0
    var eventDeltaCarried = false
    for zoom in [1.0, 0.6, 2.0] {
        // Relative to the real clock, so the recent view draws its lines and nodes have different sizes.
        let fixture = try GraphFixture.make(root: root, name: "drag-state-\(Int(zoom * 100))", now: Date(), heavy: true)
        GraphProbe.places = [:]; GraphProbe.view = nil
        let (window, host) = hiddenHarnessWindow(SessionGroupConversationGraph(groupID: fixture.group.id, engine: fixture.engine, zoom: zoom)
            .frame(width: size.width, height: size.height), size: size)
        try await Task.sleep(for: .seconds(2.5))
        host.layoutSubtreeIfNeeded()
        // The node nearest the middle of the graph area (left of the 320pt panel, below the controls),
        // so a 120pt by 60pt drag stays inside the visible part at every zoom.
        let middle = CGPoint(x: (size.width - 320) / 2, y: 245)
        guard let name = GraphProbe.places.keys.compactMap({ key in GraphProbe.center(key, in: host).map { (key, $0) } })
                .min(by: { hypot($0.1.x - middle.x, $0.1.y - middle.y) < hypot($1.1.x - middle.x, $1.1.y - middle.y) })?.0,
              let start = GraphProbe.center(name, in: host) else { throw AppError.message("drag node not found") }
        eventDeltaCarried = mouse(.leftMouseDragged, start, window, delta: CGVector(dx: 1, dy: 0)).deltaX == 1
        var trials: [[String: Any]] = []
        for trial in 0..<3 {
            GraphProbe.firstFrame = nil; GraphProbe.frames = 0; GraphProbe.beganAt = nil; GraphProbe.previewCenter = nil
            host.layoutSubtreeIfNeeded()
            let origin = trial == 0 ? start : (GraphProbe.center(name, in: host) ?? start)
            let meter = MainBusyMeter(); meter.origin = origin; meter.start()
            NSApp.postEvent(mouse(.leftMouseDown, origin, window), atStart: false)
            try await Task.sleep(for: .milliseconds(40))
            let rootsBefore = GraphProbe.roots, canvasesBefore = GraphProbe.canvases
            let direction: CGFloat = trial % 2 == 0 ? -1 : 1
            // Window y grows upward: a node below the middle moves up, so the edge limit never holds it.
            let rise: CGFloat = origin.y < middle.y ? 1 : -1
            for step in 1...60 {
                let point = CGPoint(x: origin.x + CGFloat(step) * 2 * direction, y: origin.y + CGFloat(step) * rise)
                NSApp.postEvent(mouse(.leftMouseDragged, point, window, delta: CGVector(dx: 2 * direction, dy: -rise)), atStart: false)
                try await Task.sleep(for: .milliseconds(8))
            }
            try await Task.sleep(for: .milliseconds(40))
            let rootsDuring = GraphProbe.roots - rootsBefore, canvasesDuring = GraphProbe.canvases - canvasesBefore
            meter.stop()
            let end = CGPoint(x: origin.x + 120 * direction, y: origin.y + 60 * rise)
            let previewError = GraphProbe.previewCenter.map { hypot($0.x - end.x, $0.y - end.y) }
            NSApp.postEvent(mouse(.leftMouseUp, end, window), atStart: false)
            try await Task.sleep(for: .milliseconds(500))
            host.layoutSubtreeIfNeeded()
            let dropped = GraphProbe.center(name, in: host)
            let dropError = dropped.map { hypot($0.x - end.x, $0.y - end.y) }
            var firstFrame: Double?
            if let frame = GraphProbe.firstFrame, let dragStart = meter.dragStart { firstFrame = (frame - dragStart) * 1000 }
            var liftedNode: Double?
            if let began = GraphProbe.beganAt, let dragStart = meter.dragStart { liftedNode = (began - dragStart) * 1000 }
            let durations = meter.durations
            trials.append(["rootBodiesDuringDrag": rootsDuring, "canvasBodiesDuringDrag": canvasesDuring,
                           "rootBodiesIncludingRelease": GraphProbe.roots - rootsBefore, "measuredEvents": durations.count,
                           "medianMs": percentile(durations, 0.5), "p95Ms": percentile(durations, 0.95), "maxMs": durations.max() ?? 0,
                           "firstDisplayFrameMs": firstFrame as Any, "previewBeginMs": liftedNode as Any, "displayFrames": GraphProbe.frames,
                           "previewPointerErrorPt": previewError as Any, "dropPointerErrorPt": dropError as Any])
            guard let previewError, let dropError else {
                throw AppError.message("Preview or dropped node missing at \(Int(zoom * 100))% trial \(trial + 1): node \(name) at \(origin), "
                    + "drag events seen \(meter.durations.count), began \(GraphProbe.beganAt != nil), frames \(GraphProbe.frames), preview \(String(describing: GraphProbe.previewCenter)), "
                    + "dropped \(String(describing: dropped)), view \(String(describing: GraphProbe.view)), places \(GraphProbe.places)")
            }
            worstPreview = max(worstPreview, previewError); worstDrop = max(worstDrop, dropError)
            allDurations += durations; allRoots += rootsDuring; allCanvases += canvasesDuring
        }
        zooms.append(["zoomPercent": Int(zoom * 100), "node": name, "scale": GraphProbe.view?.scale as Any,
                      "windowVisible": window.occlusionState.contains(.visible), "trials": trials])
        window.close(); fixture.engine.stop()
    }
    let result: [String: Any] = [
        "events": allDurations.count, "rootBodiesDuringDrag": allRoots, "canvasBodiesDuringDrag": allCanvases,
        "medianMs": percentile(allDurations, 0.5), "p95Ms": percentile(allDurations, 0.95),
        "worstPreviewPointerErrorPt": worstPreview, "worstDropPointerErrorPt": worstDrop, "zooms": zooms,
        "harnessBecameActive": NSApp.isActive,
        "frontAppUnchanged": NSWorkspace.shared.frontmostApplication?.processIdentifier == frontApp,
        "eventDeltaCarried": eventDeltaCarried
    ]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: root.appendingPathComponent("drag-measure.json"))
    print(String(decoding: data, as: UTF8.self))
}

/// A two-finger scroll of `dy` pixels at a window point, with ⌘ held when `command` is set,
/// addressed to the harness window like the mouse events above.
@MainActor func scroll(_ point: CGPoint, _ window: NSWindow, dy: Int32, command: Bool) throws -> NSEvent {
    // A mouse event made for the window keeps the window when its CGEvent copy becomes a scroll.
    guard let base = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0),
          let event = base.cgEvent?.copy() else { throw AppError.message("scroll event") }
    event.type = .scrollWheel
    event.flags = command ? .maskCommand : []
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
    event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(dy > 0 ? 1 : -1))
    guard let value = NSEvent(cgEvent: event) else { throw AppError.message("scroll event conversion") }
    guard value.window === window, value.type == .scrollWheel else {
        throw AppError.message("scroll event is not addressed to the harness window (window \(String(describing: value.window)), type \(value.type.rawValue))")
    }
    return value
}

/// Fixed states for the five node shapes: working, idle, waiting for input, delivery blocked, unknown.
@MainActor func fixedSources(_ fixture: GraphFixture) -> ConversationGraphModel.Sources {
    let id = fixture.id
    let phases: [UUID: SessionPhase] = [id["lead"]!: .working, id["api"]!: .idle, id["test"]!: .approval,
                                        id["doc"]!: .working, id["mig"]!: .idle, id["ui"]!: .idle]
    let blocked = id["mig"]!
    let live = ConversationGraphModel.Sources.live(fixture.engine)
    return ConversationGraphModel.Sources(
        now: { GraphFixture.fixedNow },
        operations: { group, inboxes in
            Dictionary(uniqueKeysWithValues: group.members.map { member in
                let inbox = inboxes[member.id], phase = phases[member.id]
                let reason = "터미널에서 승인 또는 입력 대기"
                return (member.id, GraphMemberOperation(
                    phase: phase, input: member.id == blocked ? .deferred(reason) : phase == nil ? .unverified : .idle,
                    unacknowledgedCount: inbox?.unacknowledgedCount ?? 0, lastAcknowledgedAt: inbox?.lastAcknowledgedAt,
                    firstPendingAt: inbox?.firstPendingAt, lastDeliveryFailure: member.id == blocked ? reason : inbox?.lastDeliveryFailure,
                    isDeliveryBlocked: member.id == blocked))
            })
        },
        liveNicknames: live.liveNicknames,
        sessions: Empty<[ConversationGraphModel.SessionKey], Never>().eraseToAnyPublisher())
}

/// Twelve scenes, two window sizes, light and dark: 48 PNG files. Scenes 1 to 8 and 11 to 12 open
/// fitted as the app does; 8 is a group wider than the window, 9 and 10 fix the zoom at 50% and 200%,
/// 11 and 12 mix members with very different message amounts in the tree and circle layouts.
@MainActor func renderGraphScenes(root: URL) async throws {
    let fixture = try GraphFixture.make(root: root, name: "graph-state")
    let empty = try GraphFixture.make(root: root, name: "graph-empty", empty: true)
    let wide = try GraphFixture.make(root: root, name: "graph-wide", extra: 12)
    let uneven = try GraphFixture.make(root: root, name: "graph-uneven", burst: 24)
    let groupFile = fixture.directory.appendingPathComponent("session-groups.json")
    let original = try Data(contentsOf: groupFile)
    let scenes: [(String, GraphFixture, UUID?, SessionGroupGraph.Scope, SessionGroupGraph.Layout, Bool, Double?)] = [
        ("1-none", fixture, nil, .recent, .tree, false, nil),
        ("2-leader-selected", fixture, fixture.id["lead"], .recent, .tree, false, nil),
        ("3-blocked-selected", fixture, fixture.id["mig"], .recent, .tree, false, nil),
        ("4-circle", fixture, nil, .recent, .circle, false, nil),
        ("5-all", fixture, nil, .all, .tree, false, nil),
        ("6-empty-group", empty, nil, .recent, .tree, false, nil),
        ("7-read-failure", fixture, nil, .recent, .tree, true, nil),
        ("8-fit-wide-group", wide, nil, .recent, .tree, false, nil),
        ("9-zoom-50", fixture, nil, .recent, .tree, false, 0.5),
        ("10-zoom-200", fixture, nil, .recent, .tree, false, 2),
        ("11-size-tree", uneven, nil, .recent, .tree, false, nil),
        ("12-size-circle", uneven, nil, .recent, .circle, false, nil)
    ]
    var written: [String] = []
    for (name, scene, selection, scope, layout, failing, zoom) in scenes {
        for (label, width, height) in [("720x460", 720.0, 460.0), ("1040x680", 1040.0, 680.0)] {
            for (theme, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                let view = SessionGroupConversationGraph(groupID: scene.group.id, engine: scene.engine, sources: fixedSources(scene),
                                                         initialSelection: selection, initialScope: scope, layout: layout, zoom: zoom)
                    .frame(width: width, height: height)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme)
                let (window, host) = hiddenHarnessWindow(view, size: CGSize(width: width, height: height))
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                try await Task.sleep(for: .milliseconds(1300))
                if failing {
                    try Data("{".utf8).write(to: groupFile)
                    try await Task.sleep(for: .milliseconds(1600))
                }
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw AppError.message("렌더 결과 없음") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("PNG 결과 없음") }
                let file = root.appendingPathComponent("graph-\(name)-\(label)-\(theme).png")
                try png.write(to: file)
                written.append(file.lastPathComponent)
                window.close()
                if failing { try original.write(to: groupFile) }
            }
        }
    }
    fixture.engine.stop(); empty.engine.stop(); wide.engine.stop(); uneven.engine.stop()
    print("PASS graph scenes: \(written.count) PNG\n" + written.joined(separator: "\n"))
}

/// Another connection writes, and the window must follow within two seconds without
/// recomputing when nothing changed, reading off the main thread and stopping while hidden.
@MainActor func verifyGraphRefresh(root: URL) async throws {
    // The window reads the real clock here, so the messages are placed relative to now and the
    // recent view shows the same counts and size steps as the rendered scenes.
    let fixture = try GraphFixture.make(root: root, name: "refresh-state", now: Date())
    defer { fixture.engine.stop() }
    let size = CGSize(width: 1040, height: 680)
    let (window, host) = hiddenHarnessWindow(SessionGroupConversationGraph(groupID: fixture.group.id, engine: fixture.engine)
        .frame(width: size.width, height: size.height), size: size)
    defer { window.close() }
    func require(_ ok: Bool, _ message: String) throws { if !ok { throw AppError.message(message) } }
    func waitForMessages(_ count: Int, within seconds: Double) async throws -> Double? {
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < seconds {
            if GraphProbe.messageCount == count { return CACurrentMediaTime() - start }
            try await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
    try await Task.sleep(for: .seconds(2))
    host.layoutSubtreeIfNeeded()
    let initial = GraphProbe.messageCount
    try require(initial > 0, "Initial graph load missing")
    let probe = GraphReadProbe.shared
    let rootsBefore = GraphProbe.roots, checksBefore = probe.value.checks
    try await Task.sleep(for: .seconds(3))
    let unchangedRoots = GraphProbe.roots - rootsBefore, unchangedChecks = probe.value.checks - checksBefore
    try require(unchangedChecks >= 2, "Visible window stopped checking storage")
    try require(unchangedRoots == 0, "Unchanged checks recomputed the window \(unchangedRoots) times")
    let placesBefore = GraphProbe.places
    let sizesBefore = GraphProbe.rects.mapValues { $0.height / $0.width }
    let writer = try SessionGroupMailbox(directory: fixture.directory)
    _ = try writer.enqueue(groupID: fixture.group.id, senderID: fixture.id["ui"]!, recipientID: fixture.id["lead"]!,
                           kind: .message, text: "결제 화면 캡처를 새로 올렸습니다")
    guard let latency = try await waitForMessages(initial + 1, within: 3) else { throw AppError.message("New message did not appear within 3 s") }
    try require(latency < 2, "New message took \(latency) s")
    try await Task.sleep(for: .milliseconds(400))
    host.layoutSubtreeIfNeeded()
    let moved = placesBefore.filter { name, point in
        guard let after = GraphProbe.places[name] else { return true }
        return hypot(after.x - point.x, after.y - point.y) > 0.5
    }
    let resized = sizesBefore.filter { name, ratio in abs((GraphProbe.rects[name].map { $0.height / $0.width } ?? 0) - ratio) > 0.01 }
    try require(resized.isEmpty, "One message changed a size step: " + resized.keys.sorted().joined(separator: ", "))
    try require(!placesBefore.isEmpty && moved.isEmpty, "Nodes moved after a new message: " + moved.keys.sorted().map { "\($0) \(placesBefore[$0]!) -> \(String(describing: GraphProbe.places[$0]))" }.joined(separator: "; "))
    // The user zooms with ⌘ and a scroll over the leader. Later updates, a new message and a new
    // member, must keep that zoom and pan; the new member changes the layout, so only the view is compared.
    func same(_ a: SessionGroupGraph.Viewport?, _ b: SessionGroupGraph.Viewport?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.scale - b.scale) < 1e-6 && hypot(a.offset.x - b.offset.x, a.offset.y - b.offset.y) < 0.01
    }
    let fitted = GraphProbe.view
    guard let leaderBefore = GraphProbe.center("결제 총괄", in: host), let fittedScale = fitted?.scale else { throw AppError.message("Leader or view probe missing") }
    NSApp.postEvent(try scroll(leaderBefore, window, dy: 200, command: true), atStart: false)
    try await Task.sleep(for: .milliseconds(400))
    host.layoutSubtreeIfNeeded()
    let zoomed = GraphProbe.view
    try require((zoomed?.scale ?? 0) > fittedScale + 0.05, "⌘ scroll did not zoom: \(fittedScale) -> \(String(describing: zoomed?.scale))")
    guard let leaderZoomed = GraphProbe.center("결제 총괄", in: host) else { throw AppError.message("Leader missing after zoom") }
    let anchorError = hypot(leaderZoomed.x - leaderBefore.x, leaderZoomed.y - leaderBefore.y)
    try require(anchorError < 1, "The point under the pointer moved \(anchorError) pt while zooming")
    let placesZoomed = GraphProbe.places
    // Neither member crosses a size step with this message.
    _ = try writer.enqueue(groupID: fixture.group.id, senderID: fixture.id["api"]!, recipientID: fixture.id["test"]!,
                           kind: .message, text: "확대한 뒤 보낸 메시지입니다")
    guard try await waitForMessages(initial + 2, within: 3) != nil else { throw AppError.message("Message after zoom did not appear within 3 s") }
    try await Task.sleep(for: .milliseconds(400))
    host.layoutSubtreeIfNeeded()
    let viewAfterMessage = GraphProbe.view
    try require(same(zoomed, viewAfterMessage), "A new message changed the zoom or pan: \(String(describing: zoomed)) -> \(String(describing: viewAfterMessage))")
    let movedWhileZoomed = placesZoomed.filter { name, point in
        guard let after = GraphProbe.places[name] else { return true }
        return hypot(after.x - point.x, after.y - point.y) > 0.5
    }
    try require(movedWhileZoomed.isEmpty, "Nodes moved after a message while zoomed: " + movedWhileZoomed.keys.sorted().joined(separator: ", "))
    var grown = fixture.group
    var added = SessionGroupMember(agent: .codex, title: "검증 추가", cwd: "/fixture/payments/extra",
                                   conversationID: UUID().uuidString.lowercased(), providerHome: "/tmp/graph-fixture-home")
    added.parentMemberID = fixture.id["ui"]
    grown.members.append(added)
    try SessionGroupStore(directory: fixture.directory).save([grown])
    let memberStart = CACurrentMediaTime()
    while GraphProbe.places["검증 추가"] == nil && CACurrentMediaTime() - memberStart < 3 {
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
    }
    try require(GraphProbe.places["검증 추가"] != nil, "New member did not appear within 3 s")
    try await Task.sleep(for: .milliseconds(300))
    host.layoutSubtreeIfNeeded()
    let viewAfterMember = GraphProbe.view
    try require(same(zoomed, viewAfterMember), "A new member changed the zoom or pan: \(String(describing: zoomed)) -> \(String(describing: viewAfterMember))")
    // 20 messages from "화면 점검" to the leader move both from a smaller size step to the largest.
    // The layout makes room for the larger circles, no two nodes overlap, and the zoom and pan stay.
    let widthsBefore = GraphProbe.rects.mapValues { $0.height / $0.width }
    let placesBeforeBurst = GraphProbe.places
    for i in 0..<20 {
        _ = try writer.enqueue(groupID: fixture.group.id, senderID: fixture.id["ui"]!, recipientID: fixture.id["lead"]!,
                               kind: .message, text: "화면 점검 결과 \(i + 1)을 정리했습니다")
    }
    guard try await waitForMessages(initial + 22, within: 3) != nil else { throw AppError.message("Message burst did not appear within 3 s") }
    try await Task.sleep(for: .milliseconds(400))
    host.layoutSubtreeIfNeeded()
    let grew = ["결제 총괄", "화면 점검"].filter { name in (GraphProbe.rects[name].map { $0.height / $0.width } ?? 0) > (widthsBefore[name] ?? 0) + 0.01 }
    try require(grew.count == 2, "The leader and 화면 점검 did not grow to a larger size step: \(grew)")
    let relaid = placesBeforeBurst.filter { name, point in GraphProbe.places[name].map { hypot($0.x - point.x, $0.y - point.y) > 0.5 } ?? true }
    try require(!relaid.isEmpty, "A size step change did not lay the graph out again")
    let overlapsAfterBurst = GraphProbe.overlaps()
    try require(overlapsAfterBurst.isEmpty, "Nodes overlap after a size step change: " + overlapsAfterBurst.joined(separator: ", "))
    let viewAfterBurst = GraphProbe.view
    try require(same(zoomed, viewAfterBurst), "A size step change changed the zoom or pan")
    try require(probe.value.onMain == 0, "Storage was read on the main thread \(probe.value.onMain) times")
    window.orderOut(nil)
    try await Task.sleep(for: .milliseconds(600))
    let hiddenChecks = probe.value.checks
    try await Task.sleep(for: .milliseconds(2500))
    let checksWhileHidden = probe.value.checks - hiddenChecks
    try require(checksWhileHidden == 0, "Hidden window kept checking storage")
    _ = try writer.enqueue(groupID: fixture.group.id, senderID: fixture.id["api"]!, recipientID: fixture.id["test"]!,
                           kind: .message, text: "숨긴 동안 보낸 메시지입니다")
    window.orderFrontRegardless()
    guard let reopen = try await waitForMessages(initial + 23, within: 3) else { throw AppError.message("Shown window did not read again") }
    let result: [String: Any] = ["newMessageLatencyMs": latency * 1000, "rootBodiesWhileUnchanged3s": unchangedRoots,
                                 "storageChecksWhileUnchanged3s": unchangedChecks, "mainThreadReads": probe.value.onMain,
                                 "totalReads": probe.value.checks, "nodesMovedAfterMessage": moved.count, "sizeStepsChangedByOneMessage": resized.count,
                                 "checksWhileHidden2_5s": checksWhileHidden, "reopenReadMs": reopen * 1000,
                                 "nodeCount": placesBefore.count, "fittedScale": fittedScale, "zoomedScale": zoomed?.scale as Any,
                                 "zoomAnchorErrorPt": anchorError, "viewKeptAfterMessage": same(zoomed, viewAfterMessage),
                                 "nodesMovedAfterMessageWhileZoomed": movedWhileZoomed.count,
                                 "viewKeptAfterNewMember": same(zoomed, viewAfterMember), "nodesGrownByBurst": grew,
                                 "nodesRelaidByStepChange": relaid.count, "overlapsAfterStepChange": overlapsAfterBurst.count,
                                 "viewKeptAfterStepChange": same(zoomed, viewAfterBurst)]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: root.appendingPathComponent("refresh-verify.json"))
    print("PASS graph refresh: new message in \(Int(latency * 1000)) ms, 0 root bodies while unchanged, reads off the main thread, no checks while hidden, nodes kept their positions, a user zoom survived a new message, a new member and a size step change, no overlaps after the step change\n" + String(decoding: data, as: UTF8.self))
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
}

@main struct SessionGroupsRender {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        if CommandLine.arguments.contains("--graph") || CommandLine.arguments.contains("--verify-graph-refresh") {
            let refresh = CommandLine.arguments.contains("--verify-graph-refresh")
            Task { @MainActor in
                do {
                    if refresh { try await verifyGraphRefresh(root: root) } else { try await renderGraphScenes(root: root) }
                    NSApp.terminate(nil)
                } catch { fputs("Graph \(refresh ? "refresh" : "render") QA: \(error)\n", stderr); exit(1) }
            }
            NSApp.run(); return
        }
        if CommandLine.arguments.contains("--verify-drag") {
            Task { @MainActor in
                do { try await verifyDrag(root: root); NSApp.terminate(nil) }
                catch { fputs("Graph drag QA: \(error)\n", stderr); exit(1) }
            }
            NSApp.run(); return
        }
        let directory = root.appendingPathComponent("fixture-state")
        let records = ProcessDiscovery.parse("""
        100541 1 group1 100541 100541 Wed Oct 28 12:00:00 2026 /fixture/codex
        100542 1 group2 100542 100542 Wed Oct 28 12:00:00 2026 /fixture/claude
        """)
        var sessions = records.map { AgentSession(id: $0.key, agent: $0.agent!, pid: $0.pid, started: $0.started,
            tty: "/dev/" + $0.tty, cwd: "/tmp/매우 긴 프로젝트 경로/프로젝트", terminal: .terminal) }
        let fixtureThread = "00000000-0000-4000-8000-000000000001"
        sessions[0].codexApprovalBinding = .init(threadID: fixtureThread, title: "Fixture")
        let transport = CodexReplyTransport(prepare: { _, _ in throw AppError.message("unused") },
            send: { _, _ in throw AppError.message("never send") },
            queueHome: { _ in .init(executable: "", home: "/tmp/group-qa-home", threadID: "") })
        let queue = CodexQueueTransport(list: { _ in [] }, delete: { _, _ in .init(removed: []) }, validate: { _, _ in })
        let reads = GroupRefreshReads()
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), questionTransport: transport,
            claudeRegistryReader: { _ in [] }, processReader: { reads.read(); return records }, codexQueue: queue)
        engine.updateDiscovery(sessions, records: records)
        var members: [SessionGroupMember] = []
        for (index, session) in sessions.enumerated() {
            var entry = SessionGroupMember(agent: session.agent, title: "긴 세션 이름 · 프로젝트 협업 \(index + 1)", cwd: session.cwd, conversationID: "")
            entry.runtimeID = session.id; members.append(entry)
        }
        for index in 0..<16 {
            members.append(SessionGroupMember(agent: index % 2 == 0 ? .codex : .claude,
                title: "연결이 끊긴 긴 이름의 협업 세션 \(index)", cwd: "/tmp/프로젝트/긴 이름/\(index)",
                conversationID: UUID().uuidString, providerHome: "/tmp/home"))
        }
        members.insert(SessionGroupMember(agent: .codex, title: "다시 연결할 대화", cwd: sessions[0].cwd,
            conversationID: UUID().uuidString.lowercased(), providerHome: "/tmp/group-qa-home"), at: 0)
        for i in members.indices.dropFirst(2) { members[i].parentMemberID = members[1].id }
        let group = SessionGroup(name: "세션 그룹 · 긴 프로젝트 협업 이름과 상태", members: members)
            .addingLeader(members[0].id).addingLeader(members[1].id)
        try SessionGroupStore(directory: directory).save([group])
        if CommandLine.arguments.contains("--verify-refresh") {
            NSApp.setActivationPolicy(.regular)
            Task { @MainActor in
                do {
                    let window = NSWindow(contentRect: NSRect(x: 80, y: 100, width: 860, height: 640),
                                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
                    window.title = "그룹 갱신 보존 검증"; window.isReleasedWhenClosed = false; window.level = .floating
                    window.contentView = NSHostingView(rootView: SessionGroupsWindow(engine: engine, initialSelection: group.id))
                    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                    func require(_ ok: Bool, _ message: String) throws { if !ok { throw AppError.message(message) } }
                    try await Task.sleep(for: .seconds(1))
                    try require(GroupRefreshProbe.names == [group.name], "Initial group load missing")
                    let initialBodies = GroupRefreshProbe.bodies, initialReads = reads.value
                    try await Task.sleep(for: .milliseconds(3500))
                    try require(reads.value > initialReads, "Visible group observation stopped")
                    try require(GroupRefreshProbe.bodies == initialBodies, "Unchanged observation rebuilt group content")
                    window.orderOut(nil)
                    try await Task.sleep(for: .milliseconds(300))
                    let hiddenReads = reads.value
                    var updated = group; updated.name = "숨김 중 변경된 최신 그룹"
                    try SessionGroupStore(directory: directory).save([updated])
                    try await Task.sleep(for: .milliseconds(3500))
                    try require(reads.value == hiddenReads, "Hidden group kept polling")
                    engine.refreshSessionGroupBadges()
                    try await Task.sleep(for: .milliseconds(800))
                    try require(reads.value > hiddenReads, "Hiding the view disabled engine group discovery")
                    window.makeKeyAndOrderFront(nil)
                    try await Task.sleep(for: .milliseconds(800))
                    try require(GroupRefreshProbe.names == [updated.name], "Reopened group did not refresh immediately")
                    window.miniaturize(nil)
                    try await Task.sleep(for: .milliseconds(300))
                    let minimizedReads = reads.value
                    try await Task.sleep(for: .milliseconds(3500))
                    try require(reads.value == minimizedReads, "Minimized group kept polling")
                    window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
                    try await Task.sleep(for: .milliseconds(800))
                    try require(reads.value > minimizedReads, "Restored group did not resume observation")
                    window.close(); engine.stop()
                    print("PASS group refresh: visible polling, unchanged body suppression, hidden/minimized suspension, independent engine discovery, immediate fresh reopen")
                    NSApp.terminate(nil)
                } catch { fputs("Group refresh QA: \(error)\n", stderr); exit(1) }
            }
            NSApp.run(); return
        }
        if CommandLine.arguments.contains("--interactive") {
            NSApp.setActivationPolicy(.regular)
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 860, height: 640),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "세션 그룹 검증"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SessionGroupsWindow(engine: engine))
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            NSApp.run(); return
        }
        Task { @MainActor in
            do {
                for (label, width, height) in [("minimum", 700, 480), ("default", 860, 640), ("wide", 1100, 800)] {
                    for (theme, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                        let rootView = SessionGroupsWindow(engine: engine, initialSelection: group.id)
                            .frame(width: CGFloat(width), height: CGFloat(height))
                            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme)
                        let host = NSHostingView(rootView: rootView)
                        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
                        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false; window.contentView = host
                        window.orderFrontRegardless()
                        try await Task.sleep(for: .milliseconds(800))
                        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw AppError.message("렌더 결과 없음") }
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("PNG 결과 없음") }
                        try png.write(to: root.appendingPathComponent("\(label)-\(theme).png")); window.close()
                    }
                }
                print("PASS group views: 700×480, 860×640, 1100×800 light/dark")
                NSApp.terminate(nil)
            } catch { fputs("Group render QA: \(error)\n", stderr); exit(1) }
        }
        NSApp.run()
    }
}
