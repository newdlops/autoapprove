import Foundation
import AppKit
import SwiftUI
import AutoApproveCore

/// Private signed updater fixture. Only injected release data and an empty process list.
@main struct AppUpdateManager {
    static func config(_ file: URL) -> JSONObject {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? JSONObject ?? [:]
    }
    @MainActor static func main() throws {
        let app = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = app.deletingLastPathComponent(), file = root.appendingPathComponent("fixture-config.json")
        let settings = config(file)
        guard let home = settings["home"] as? String else { throw AppError.message("Missing isolated profile") }
        let services = PublishedUpdateServices { request, _ in
            let settings = config(file)
            if settings["failure"] as? Bool == true { return PublishedUpdateReply(status: 503, body: Data()) }
            if request.url?.host == "api.github.com", let metadata = settings["metadata"] as? String {
                return PublishedUpdateReply(status: 200, body: try Data(contentsOf: URL(fileURLWithPath: metadata)))
            }
            guard let archive = settings["archive"] as? String, let range = request.value(forHTTPHeaderField: "Range") else { throw AppError.message("Unexpected request") }
            let parts = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: archive), options: .mappedIfSafe)
            guard parts.count == 2, parts[0] >= 0, parts[1] < bytes.count else { throw AppError.message("Invalid range") }
            return PublishedUpdateReply(status: 206, body: Data(bytes[parts[0]...parts[1]]), contentRange: "bytes \(parts[0])-\(parts[1])/\(bytes.count)")
        }
        let engine = try ApprovalEngine(paths: AppPaths(directory: URL(fileURLWithPath: home)), processReader: { [] }, publishedUpdateServices: services)
        engine.finishLANUpdate = { engine.stop(); exit(0) }
        try engine.setWebEnabled(false)
        try engine.setLANUpdateEnabled(false)
        NSApplication.shared.setActivationPolicy(.prohibited)
        if settings["render"] as? Bool != true { try engine.start(poll: false) }
        Task { @MainActor in
            if settings["render"] as? Bool == true {
                try? engine.appUpdates.setAutomatic(false)
                await engine.appUpdates.check()
                let view = NSHostingView(rootView: AppUpdatesView(model: engine.appUpdates).background(Color(nsColor: .windowBackgroundColor)))
                let size = view.fittingSize
                view.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = view; view.layoutSubtreeIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("update.png"))
                }
                engine.stop(); exit(0)
            }
            try? engine.appUpdates.setAutomatic(true)
            for _ in 0..<1200 {
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("qa-stop").path) { engine.stop(); exit(0) }
                var state: JSONObject = ["pid": Int(getpid()), "web": engine.webService != nil, "phase": engine.lanUpdate.phase, "detail": engine.lanUpdate.detail]
                if let release = RemoteWebVersion.current { state["release"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(release)) }
                try? JSONSerialization.data(withJSONObject: state).write(to: root.appendingPathComponent("fixture-state.json"), options: .atomic)
                try? await Task.sleep(for: .milliseconds(100))
            }
            engine.stop(); exit(1)
        }
        withExtendedLifetime(engine) { NSApplication.shared.run() }
    }
}
