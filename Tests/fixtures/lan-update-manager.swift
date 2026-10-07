import Foundation
import AutoApproveCore
import Darwin
import AppKit

/// A signed, isolated application exercises the production LAN updater.
/// Its config and preferences are outside the application offered to peers.
@main struct LANUpdateManagerFixture {
    nonisolated static func config(_ file: URL) -> JSONObject {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? JSONObject ?? [:]
    }
    @MainActor static func main() throws {
        let app = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = app.deletingLastPathComponent().appendingPathComponent("fixture-config.json")
        let settings = config(file)
        guard let home = settings["home"] as? String, let port = settings["port"] as? Int, let address = settings["peer"] as? String else { throw AppError.message("Missing isolated configuration") }
        var power = PowerControl.live
        power.read = { PowerReading(lidClosed: config(file)["lidClosed"] as? Bool ?? false) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: URL(fileURLWithPath: home)), processReader: { [] }, powerControl: power)
        engine.finishLANUpdate = { engine.stop(); exit(0) }
        if let enabled = settings["enabled"] as? Bool { try engine.setLANUpdateEnabled(enabled) }
        try engine.setWebEnabled(false)
        try engine.start(poll: false)
        try engine.setWebEnabled(true, port: UInt16(port), bonjourEnabled: false, discoveryAddresses: { address.isEmpty ? [] : [address] })
        engine.webService?.directDiscoveryInterval = 1
        try Data(String(getpid()).utf8).write(to: app.deletingLastPathComponent().appendingPathComponent("fixture-pid"), options: .atomic)
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            for _ in 0..<100 {
                try? JSONEncoder().encode(engine.webStatus).write(to: app.deletingLastPathComponent().appendingPathComponent("fixture-web.json"), options: .atomic)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        withExtendedLifetime(engine) { NSApplication.shared.run() }
    }
}
