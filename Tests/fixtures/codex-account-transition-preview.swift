import SwiftUI
import AppKit
import AutoApproveCore

private struct AccountTransitionPreview: View {
    @State private var enabled = true
    @State private var phase = CodexAccountTransitionState.Phase.review
    @State private var calls = 0
    @State private var dark = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("연결 설정 · Codex").font(.title2.weight(.semibold)); Spacer(); Toggle("어두운 화면",isOn:$dark) }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if enabled,Self.state(phase).held {
                        CodexAutomationHoldNotice(reason:"계정 전환·세션 연결을 확인하는 동안 자동 승인을 보류합니다. 계정·로그인에서 진행 상태를 확인하거나 남은 전환을 중지해주세요.",openAccounts:{calls += 1})
                        Divider()
                    }
                    Picker("검사 상태", selection: $phase) {
                        ForEach([CodexAccountTransitionState.Phase.ready, .stopping, .waiting, .restarting, .reconnecting, .resuming, .complete, .review, .unsupported], id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    CodexAccountTransitionSettings(enabled: enabled, busy: phase == .restarting,
                        states: enabled ? ["/fixture/긴 프로젝트 이름/개발용 Codex 환경/" + String(repeating: "nested-folder/", count: 12): Self.state(phase)] : [:],
                        notice: nil, error: nil, setEnabled: { enabled = $0 },
                        check: { calls += 1; phase = .waiting }, cancel: { _ in phase = .cancelled })
                    Text("검사 버튼 동작 \(calls)회").font(.caption).accessibilityIdentifier("check-count")
                }.font(.callout).foregroundStyle(.secondary).padding(24)
            }
        }.frame(width: 600, height: 660).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(dark ? .dark:.light)
    }
    static func state(_ phase: CodexAccountTransitionState.Phase) -> CodexAccountTransitionState {
        var state = CodexAccountTransitionState(); state.phase = phase
        state.threads = (0..<24).map { .init(id: "thread-\($0)", turnID: "turn-\($0)", active: true) }
        state.witnesses = (0..<24).map { .init(pid: Int32($0 + 100), started: "synthetic", tty: "/dev/fixture\($0)", threadID: "thread-\($0)") }
        state.reservations = Dictionary(uniqueKeysWithValues: (0..<12).map { ("thread-\($0)", "turn-\($0)") })
        state.restartReserved = [.restarting, .reconnecting, .resuming, .complete].contains(phase); state.verified = [.resuming,.complete].contains(phase) ? 24 : 12
        switch phase {
        case .waiting: state.detail = "모든 작업 중단 확인 · 대기 입력이 남아 서버 전환을 기다립니다. 원래 Codex의 메시지 대기열을 확인해주세요."
        case .reconnecting: state.detail = "새 계정과 기존 대화 재연결 확인 중 · 12/24개"
        case .resuming: state.detail = "전환으로 중단한 작업 이어가기 · 12/24개"
        case .complete: state.detail = "새 로그인으로 기존 창 24개 연결 · 중단 작업 12개 이어가기 완료. 원래 대기 중이던 대화는 유지합니다."
        case .review: state.detail = "서버 전환 뒤 기존 창 12/24개의 연결만 확인했습니다. 같은 요청을 반복하지 말고 Mac에서 나머지 대화를 확인해주세요."
        case .unsupported: state.detail = "공식 관리형 Codex 0.166.0 이상과 같은 버전의 CLI가 필요합니다. 현재 실행 방식은 자동 전환을 지원하지 않습니다."
        default: state.detail = "작업을 순차 중단하고 실제 대기 상태를 확인합니다. 작성 중인 입력과 원래 창은 유지합니다."
        }
        return state
    }
}
@main struct AccountTransitionPreviewApp {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let directory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory() + "aa-account-preview")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for phase in [CodexAccountTransitionState.Phase.ready, .waiting, .reconnecting, .resuming, .complete, .review, .unsupported] {
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                let view = ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Codex 계정 전환", systemImage: "command").font(.headline).foregroundStyle(.primary)
                        CodexAccountTransitionSettings(enabled: phase != .ready, busy: false,
                            states: phase == .ready ? [:] : ["/fixture/긴 프로젝트 이름/" + String(repeating: "nested-folder/", count: 12): AccountTransitionPreview.state(phase)],
                            notice: nil, error: nil, setEnabled: { _ in }, check: {}, cancel: { _ in })
                    }.font(.callout).foregroundStyle(.secondary).padding(24)
                }.frame(width: 600, height: 660).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: view); host.frame = NSRect(x: 0, y: 0, width: 600, height: 660)
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host; host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw AppError.message("Preview unavailable") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(phase.rawValue)-\(name).png"))
            }
        }
        if CommandLine.arguments.contains("--interactive") || CommandLine.arguments.count == 1 {
            let menu=NSMenu(),item=NSMenuItem();menu.addItem(item)
            let submenu=NSMenu();submenu.addItem(withTitle:"Quit",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");item.submenu=submenu;NSApp.mainMenu=menu
            let window = NSWindow(contentRect: NSRect(x: 120, y: 100, width: 600, height: 660), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "AutoApprove 계정 전환 합성 검사"
            window.contentView = NSHostingView(rootView: AccountTransitionPreview())
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); NSApp.run()
        }
        print("Rendered 14 native states at 600×660; synthetic controls only")
    }
}
