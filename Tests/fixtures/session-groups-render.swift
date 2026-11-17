import SwiftUI
import AppKit
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

@main struct SessionGroupsRender {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
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
