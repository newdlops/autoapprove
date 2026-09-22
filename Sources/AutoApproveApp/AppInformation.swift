import AppKit

enum AppInformation {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "개발 빌드"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    static var versionLabel: String {
        build.map { "버전 \(version) · 빌드 \($0)" } ?? version
    }
    static var versionDetails: String {
        "AutoApprove\n\(versionLabel)\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
    static let releases = URL(string: "https://github.com/newdlops/autoapprove/releases/latest")!
    static let documentation = URL(string: "https://github.com/newdlops/autoapprove#readme")!
    static let issues = URL(string: "https://github.com/newdlops/autoapprove/issues")!
    @MainActor static var icon: NSImage {
        Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) } ?? NSApp.applicationIconImage
    }

    @MainActor static func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "AutoApprove",
            .applicationIcon: icon,
            .applicationVersion: versionLabel,
            .version: "",
            .credits: NSAttributedString(string: "Terminal · VS Code\nClaude Code · Codex")
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}
