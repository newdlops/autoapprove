import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { self.trimEmptyMenus() }
    }

    func applicationDidUpdate(_ notification: Notification) { trimEmptyMenus() }

    private func trimEmptyMenus() {
        // AppKit adds its full-screen item outside SwiftUI command groups.
        // Keep native validation for close/minimize/zoom and text editing.
        guard let menu = NSApp.mainMenu else { return }
        for item in menu.items {
            if let submenu = item.submenu {
                if submenu === NSApp.windowsMenu {
                    let windowActions: Set<Selector> = [#selector(NSWindow.performClose(_:)),
                        #selector(NSWindow.performMiniaturize(_:)), #selector(NSWindow.performZoom(_:))]
                    for entry in submenu.items where !entry.isSeparatorItem {
                        if entry.action.map(windowActions.contains) != true,
                           ![AppCommands.mainWindowTitle, AppCommands.historyTitle].contains(entry.title) {
                            submenu.removeItem(entry)
                        }
                    }
                } else if submenu.items.contains(where: { $0.action == #selector(NSText.copy(_:)) }) {
                    // Plain search/reply fields don't use AutoFill or text-format submenus.
                    for entry in submenu.items where entry.submenu != nil { submenu.removeItem(entry) }
                }
                var previousWasSeparator = true
                for entry in submenu.items {
                    if entry.isSeparatorItem && previousWasSeparator { submenu.removeItem(entry) }
                    else { previousWasSeparator = entry.isSeparatorItem }
                }
                if submenu.items.last?.isSeparatorItem == true { submenu.removeItem(at: submenu.items.count - 1) }
            }
            guard let entries = item.submenu?.items.filter({ !$0.isSeparatorItem }),
                  entries.isEmpty || (entries.count == 1 && entries[0].action == #selector(NSWindow.toggleFullScreen(_:))) else { continue }
            menu.removeItem(item)
        }
    }
}

struct AppCommands: Commands {
    static let mainWindowTitle = "관리 창 열기"
    static let historyTitle = "승인 내역 보기"
    var connectionsAvailable: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("AutoApprove 정보") { AppInformation.showAbout() }
        }
        CommandGroup(replacing: .appSettings) {
            Button("연결 설정…") { show("settings") }
                .keyboardShortcut(",")
                .disabled(!connectionsAvailable)
        }
        UnusedCommands()
        CommandGroup(replacing: .windowArrangement) {}
        CommandGroup(replacing: .singleWindowList) {
            Button(Self.mainWindowTitle) { show("main") }.keyboardShortcut("o")
            Button(Self.historyTitle) { show("history") }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!connectionsAvailable)
        }
        CommandGroup(replacing: .help) {
            Button("AutoApprove 도움말") { show("help") }
                .keyboardShortcut("/")
            Divider()
            Link("사용법 문서 (웹)", destination: AppInformation.documentation)
            Link("최신 릴리스 (웹)", destination: AppInformation.releases)
            Link("문제 보고 (웹)", destination: AppInformation.issues)
        }
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct UnusedCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .systemServices) {}
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .saveItem) {}
        CommandGroup(replacing: .importExport) {}
        CommandGroup(replacing: .printItem) {}
        CommandGroup(replacing: .textEditing) {}
        CommandGroup(replacing: .textFormatting) {}
        CommandGroup(replacing: .toolbar) {}
        CommandGroup(replacing: .sidebar) {}
    }
}
