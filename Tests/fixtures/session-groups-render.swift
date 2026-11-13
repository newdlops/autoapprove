import SwiftUI
import AppKit
import AutoApproveCore

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
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), questionTransport: transport,
            claudeRegistryReader: { _ in [] }, processReader: { records }, codexQueue: queue)
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
            conversationID: "", providerHome: nil), at: 0)
        let group = SessionGroup(name: "세션 그룹 · 긴 프로젝트 협업 이름과 상태", members: members)
        try SessionGroupStore(directory: directory).save([group])
        if CommandLine.arguments.contains("--interactive") {
            NSApp.setActivationPolicy(.regular)
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 860, height: 640),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "세션 그룹 검증"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SessionGroupsWindow(engine: engine))
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            NSApp.run(); return
        }
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
                try await Task.sleep(for: .milliseconds(800))
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw AppError.message("렌더 결과 없음") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("PNG 결과 없음") }
                try png.write(to: root.appendingPathComponent("\(label)-\(theme).png")); window.close()
            }
        }
        print("PASS group views: 700×480, 860×640, 1100×800 light/dark")
    }
}
