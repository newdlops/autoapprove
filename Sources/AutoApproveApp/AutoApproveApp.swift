import SwiftUI
import AppKit
import AutoApproveCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@MainActor final class AppContainer: ObservableObject {
    let engine: ApprovalEngine?
    let notifications: QuestionNotifications?
    let error: String?
    init() {
        do {
            let engine = try ApprovalEngine()
            try engine.start()
            self.engine = engine; self.error = nil
            self.notifications = QuestionNotifications(engine: engine)
        } catch { self.engine = nil; self.notifications = nil; self.error = error.localizedDescription }
    }
}

@main struct AutoApproveApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var container = AppContainer()
    var body: some Scene {
        Window("AutoApprove", id: "main") {
            if let engine = container.engine, let notifications = container.notifications {
                SessionWindow(engine: engine, notifications: notifications)
            } else {
                ContentUnavailableView {
                    Label("앱을 시작하지 못했습니다", systemImage: "exclamationmark.triangle")
                        .help(container.error ?? "앱을 다시 실행해주세요.")
                } description: { Text(container.error ?? "앱을 다시 실행해주세요.") }
                .frame(minWidth: 560, minHeight: 320)
            }
        }
        .defaultSize(width: 1040, height: 700)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }

        Window("승인 내역", id: "history") {
            if let engine = container.engine { AuditHistoryWindow(engine: engine) }
        }.defaultSize(width: 1040, height: 700).windowResizability(.contentMinSize)

        MenuBarExtra {
            if let engine = container.engine { StatusMenu(engine: engine) }
            else { Text(container.error ?? "연결 오류"); Button("종료") { NSApp.terminate(nil) }.help(AppHelp.quit) }
        } label: {
            if let engine = container.engine { StatusMenuLabel(engine: engine) }
            else { Image(systemName: "exclamationmark.bubble").help(container.error ?? "AutoApprove를 시작하지 못했습니다. 메뉴에서 오류를 확인하세요.") }
        }
    }
}

private struct StatusMenuLabel: View {
    @ObservedObject var engine: ApprovalEngine
    var body: some View {
        let count = engine.snapshot.attentionCount
        Label(count > 0 ? "\(count)" : "", systemImage: engine.snapshot.paused ? "pause.circle" : "checkmark.bubble")
            .help("AutoApprove\(engine.snapshot.paused ? " · 자동 승인 일시정지" : "") · 대기 중 \(engine.snapshot.idleCount)개 · 응답 필요 \(count)개\n눌러서 관리 창·승인 내역을 열거나 자동 승인을 일시정지합니다.")
    }
}

private struct StatusMenu: View {
    @ObservedObject var engine: ApprovalEngine
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let active = engine.snapshot.sessions.filter { $0.phase != .ended }
        Text("세션 \(active.count)개 · 자동 승인 \(active.filter { $0.automatic && $0.canApprove }.count)개")
        Text("대기 중 \(engine.snapshot.idleCount)개 · 작업 중 \(active.filter { $0.phase == .working }.count)개")
        if engine.snapshot.monitoringCount > 0 {
            Text("대기 중인 세션 중 모니터링 \(engine.snapshot.monitoringCount)개")
                .help("다음 지시를 받을 수 있지만 백그라운드 작업이 남아 있는 세션입니다.")
        }
        Text("응답 필요 \(engine.snapshot.attentionCount)건")
        if engine.snapshot.paused { Text("자동 승인 일시정지됨") }
        Divider()
        Button("관리 창 열기") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            .keyboardShortcut("o")
            .help("실행 중인 세션의 상태와 자동 승인 설정을 확인합니다. ⌘O")
        Button("승인 내역 보기") { openWindow(id: "history"); NSApp.activate(ignoringOtherApps: true) }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .help(AppHelp.history)
        Button(engine.snapshot.paused ? "자동 승인 재개" : "자동 승인 일시정지") { try? engine.setPaused(!engine.snapshot.paused) }
            .help(AppHelp.pause(engine.snapshot.paused))
        Divider()
        ForEach(engine.snapshot.events.prefix(3)) { event in
            Text("\(event.outcome) · \(event.summary.replacingOccurrences(of: "\n", with: " ").prefix(48))")
        }
        Divider()
        Button("AutoApprove 종료") { engine.stop(); NSApp.terminate(nil) }.keyboardShortcut("q")
            .help(AppHelp.quit)
    }
}
