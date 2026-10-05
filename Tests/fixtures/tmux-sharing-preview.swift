import SwiftUI
import AppKit
import AutoApproveCore

@main struct TmuxSettingsPreview {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let states = ["missing", "empty", "connecting", "connected", "disconnected", "error"]
        for state in states {
            var health = ScreenHostHealth()
            health.requested = state != "disconnected"; health.connected = state == "connected"; health.connecting = state == "connecting"
            switch state {
            case "missing": health.status = "이 Mac에 tmux를 설치해주세요. 휴대폰에는 설치하지 않습니다."
            case "empty": health.status = "연결됨 · tmux에서 실행 중인 CLI 세션 없음"
            case "connecting": health.status = "연결 확인 중…"
            case "connected": health.status = "연결됨 · 3개 세션"
            case "disconnected": health.status = "연결 해제됨"
            default: health.status = "원래 tmux 서버가 종료되거나 소켓 소유자가 바뀌었습니다. Mac에서 원래 세션을 확인해주세요."
            }
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                let view = VStack(alignment: .leading, spacing: 10) {
                    Label("tmux로 같은 터미널 공유", systemImage: "terminal").font(.headline)
                    Text(health.status).font(.callout.weight(.medium)).textSelection(.enabled)
                    TmuxSharingSettings(installed: state != "missing", health: health,
                        command: "'/Users/terminal-user-with-a-very-long-account-name-for-testing-command-wrapping-in-the-existing-settings-window/.local/bin/tmux' new-session -A -s autoapprove",
                        connect: {}, disconnect: {}).font(.callout).foregroundStyle(.secondary)
                }.padding(24).frame(width: 600, height: 400, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host; host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw AppError.message("Preview bitmap unavailable") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("Preview PNG unavailable") }
                try png.write(to: directory.appendingPathComponent("\(state)-\(name).png"))
            }
        }
        print("Rendered 12 inert tmux setting states at 600×400; no clipboard, permission or connection action invoked")
    }
}
