import SwiftUI
import AppKit
import AutoApproveCore

@main struct MouseActivityPreview {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let states: [(MouseActivityStatus.Phase, String)] = [
            (.off, "마우스 신호가 꺼져 있습니다."),
            (.ready, "켜져 있습니다. 1분마다 현재 커서 위치에 마우스 신호를 보냅니다."),
            (.active, "1분마다 마우스 신호를 보내고 있습니다."),
            (.locked, "화면이 잠겨 있어 신호를 보내지 않습니다. 직접 잠금을 해제하면 다시 보냅니다."),
            (.permission, "마우스 신호를 보내려면 손쉬운 사용 권한을 허용해주세요."),
            (.unavailable, "로그인한 Mac 화면을 확인할 수 없어 신호를 보내지 않습니다."),
            (.failed, "마우스 신호를 보내지 못했습니다. 다음 주기에 다시 확인합니다. 이벤트를 준비하는 동안 WindowServer 연결이 변경되었습니다. 잠시 후 다시 확인해주세요.")
        ]
        for (phase, detail) in states {
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                let status = MouseActivityStatus(enabled: phase != .off, phase: phase, detail: detail,
                    lastSentAt: phase == .active ? Date(timeIntervalSince1970: 1_800_000_000) : nil)
                let view = VStack(alignment: .leading, spacing: 10) {
                    Label("마우스 활동 유지", systemImage: "computermouse").font(.headline)
                    MouseActivitySettings(status: status, error: phase == .failed ? "설정을 저장하지 못했습니다. 기존 설정을 유지합니다." : nil,
                        setEnabled: { _ in }, requestPermission: {}).font(.callout).foregroundStyle(.secondary)
                }.padding(24).frame(width: 600, height: 340, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: 600, height: 340)
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host; host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw AppError.message("Preview bitmap unavailable") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("Preview PNG unavailable") }
                try png.write(to: directory.appendingPathComponent("\(phase.rawValue)-\(name).png"))
            }
        }
        print("Rendered 14 inert mouse settings states at 600×340; no events or permission request sent")
    }
}
