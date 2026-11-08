import AppKit
import SwiftUI
import AutoApproveCore

struct Preview: View {
    @ObservedObject var engine: ApprovalEngine
    let id: String
    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                Text("합성 세션").font(.headline)
                Text("Codex · Fixture Lab").font(.callout)
                Text("실제 대화에 연결하지 않는 UI 검사").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(20).frame(minWidth: 240, maxWidth: 300)
            ScrollView {
                if let session = engine.snapshot.sessions.first(where: { $0.id == id }) {
                    VStack(alignment: .leading, spacing: 24) {
                        CodexApprovalConnectionView(session: session, engine: engine)
                        Divider()
                        Text("Fixture Lab").font(.title)
                        Toggle("자동 승인", isOn: Binding(get: { session.automatic }, set: { try? engine.setAutomatic(id, enabled: $0) }))
                        Toggle("전체 일시정지", isOn: Binding(get: { engine.snapshot.paused }, set: { try? engine.setPaused($0) }))
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(minWidth: 350)
        }
    }
}
@main struct PreviewApp {
    @MainActor static func main() throws {
        let home = CommandLine.arguments[1], root = CommandLine.arguments[2]
        let target = CodexReplyTarget(executable: "", home: home, threadID: root)
        let record = ProcessDiscovery.parse("92001 1 ttys891 92001 92001 Mon Sep 21 09:00:00 2026 /usr/local/bin/codex")[0]
        let transport = CodexReplyTransport(prepare: { _, _ in target }, send: { _, _ in "unused" }, prepareMessage: { _ in target }, queueHome: { _ in target }, prepareQueue: { _, _ in target })
        let engine = try ApprovalEngine(paths: AppPaths(directory: URL(fileURLWithPath: home).appendingPathComponent("preview")), questionTransport: transport, processReader: { [record] })
        var session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/fixture", terminal: .iterm)
        session.channel = .itermScreen; engine.updateDiscovery([session], records: [record])
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 50, y: 100, width: 1040, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "AutoApprove · 서브에이전트 연결 검사"
        window.contentView = NSHostingView(rootView: Preview(engine: engine, id: session.id))
        window.minSize = NSSize(width: 784, height: 612)
        window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        app.run(); engine.stop()
    }
}
