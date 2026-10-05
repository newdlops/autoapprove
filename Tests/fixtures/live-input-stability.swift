// Real production HTTP/SSE with isolated process records and inert adapters.
// Faults affect only this fixture; no user's terminal is read or written.
import Foundation
import AutoApproveCore

private final class StabilityScreens: @unchecked Sendable {
    private let lock = NSLock()
    private var raw = "LIVE INPUT QA\nREADY> "
    private var reading = 0
    let directory: URL
    init(_ directory: URL) { self.directory = directory }
    var readActive: Bool { lock.lock(); defer { lock.unlock() }; return reading > 0 }
    func flag(_ name: String) -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) }
    func read(_ targets: [ScreenTarget]) throws -> TerminalSnapshot {
        if targets.count > 1, flag("permission-fault") { throw TerminalAdapterError.automationDenied("QA") }
        if targets.count > 1, flag("monitor-fault") { throw AppError.message("QA temporary background monitor failure") }
        if targets.count == 1 {
            lock.lock(); reading += 1; lock.unlock()
            defer { lock.lock(); reading -= 1; lock.unlock() }
            Thread.sleep(forTimeInterval: 0.18)
            if flag("read-fault") { throw AppError.message("QA temporary selected-screen read failure") }
        }
        lock.lock(); let value = raw; lock.unlock()
        return TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: value, title: "Isolated original") })
    }
    func input(_ input: RemoteTerminalInput) throws -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }
        raw += input.bytes
        let record = directory.appendingPathComponent("input.bin")
        let file = try FileHandle(forWritingTo: record)
        defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: Data(input.bytes.utf8))
        return .sent
    }
}

@main struct LiveInputStabilityFixture {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try Data().write(to: directory.appendingPathComponent("input.bin"))
        let state = StabilityScreens(directory)
        let records = ProcessDiscovery.parse("91001 1 ttys091 91001 91001 Mon Sep 21 09:00:01 2026 /fixture/codex\n91002 1 ttys092 91002 91002 Mon Sep 21 09:00:02 2026 /fixture/codex")
        let adapter = ScreenHostAdapter(screens: { try state.read($0) }, approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { _, _, _, input in try state.input(input) })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory.appendingPathComponent("profile")), processReader: { records }, screenAdapters: [.iterm:adapter])
        defer { engine.stop() }
        var sessions = ProcessDiscovery.sessions(records)
        for index in sessions.indices { sessions[index].terminal = .iterm; sessions[index].cwd = "/fixture/live-input" }
        engine.updateDiscovery(sessions, records: records); await engine.connectScreenHost(.iterm)
        try engine.setAutomatic(sessions[0].id, enabled: true)
        let web = RemoteNetworkService(engine: engine, nodeID: "CF57B0D8-EAC6-4F53-8A89-8489A4C0E390", name: "Live input QA source", bonjourEnabled: false, discoveryAddresses: { [] }) { status in
            if status.ready, let port = status.port { try? Data(String(port).utf8).write(to: directory.appendingPathComponent("source-port")) }
        }
        defer { web.stop() }; try web.start(port: 0)
        let gatewayEngine = try ApprovalEngine(paths: AppPaths(directory: directory.appendingPathComponent("gateway-profile")), processReader: { [] }, screenAdapters: [:])
        defer { gatewayEngine.stop() }
        let gateway = RemoteNetworkService(engine: gatewayEngine, nodeID: "CD0058B5-2026-4615-8FC5-9C60B399FD92", name: "Live input QA gateway", bonjourEnabled: false, discoveryAddresses: { [] }) { status in
            if status.ready, let port = status.port { try? Data(String(port).utf8).write(to: directory.appendingPathComponent("gateway-port")) }
        }
        defer { gateway.stop() }; try gateway.start(port: 0)
        func port(_ name: String) async throws -> String {
            for _ in 0..<500 {
                if let data = try? Data(contentsOf: directory.appendingPathComponent(name)), let value = String(data: data, encoding: .utf8) { return value }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw AppError.message("QA server did not start")
        }
        let sourcePort = try await port("source-port"), gatewayPort = try await port("gateway-port")
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(gatewayPort)/api/peers")!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["address": "http://127.0.0.1:\(sourcePort)"])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.message("QA gateway could not connect to source") }
        try Data(gatewayPort.utf8).write(to: directory.appendingPathComponent("port"))
        var monitorTriggered = false, permissionTriggered = false
        while !Task.isCancelled {
            if state.flag("monitor-fault"), state.readActive, !monitorTriggered {
                monitorTriggered = true
                await engine.refreshScreenHost(.iterm)
                try Data().write(to: directory.appendingPathComponent("monitor-triggered"))
            }
            if state.flag("permission-fault"), state.readActive, !permissionTriggered {
                permissionTriggered = true
                await engine.refreshScreenHost(.iterm)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
