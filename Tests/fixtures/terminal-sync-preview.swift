// A pre-existing inert CLI is read/written through an emulator adapter. It is
// deliberately NOT owned by the engine's ManagedPTYManager.
import Foundation
import Darwin
import AutoApproveCore

private final class OriginalTerminal: @unchecked Sendable {
    let terminal: ManagedPTY
    private let lock = NSLock()
    private let client = UUID().uuidString
    private var sequence = 0
    init(_ terminal: ManagedPTY) { self.terminal = terminal }
    func input(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }; sequence += 1
        try terminal.input(data, streamID: terminal.descriptor.streamID, client: client, sequence: sequence)
    }
    var adapter: ScreenHostAdapter {
        ScreenHostAdapter(screens: { [self] targets in
            let descriptor = terminal.descriptor
            guard descriptor.exitCode == nil else { return TerminalSnapshot() }
            return TerminalSnapshot(screens: targets.filter { $0.tty == descriptor.tty }.map { target in
                let screen = terminal.screen()
                return TerminalScreen(tty: target.tty, contents: screen, title: "Mac 원본 터미널", cursor: TerminalCursor(offset: screen.utf16.count, style: .bar))
            })
        }, approve: { _, _, _ in .screenChanged }, reveal: { _ in nil }, input: { [self] target, _, _, value in
            guard target.tty == terminal.descriptor.tty, target.jobPIDs.contains(terminal.descriptor.pid) else { return .missingTarget }
            try input(Data(value.bytes.utf8)); return .sent
        })
    }
}

@main struct TerminalSyncPreview {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let environment = ProcessInfo.processInfo.environment.merging(["HOME": directory.path, "ZDOTDIR": directory.path, "TERM_PROGRAM": "iTerm.app", "PATH": directory.path + ":/usr/bin:/bin:/usr/sbin:/sbin"]) { _, value in value }
        let original = OriginalTerminal(try ManagedPTY(cwd: directory.path, program: "codex", command: [directory.appendingPathComponent("codex").path], environment: environment))
        defer { original.terminal.close() }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), claudeRegistryReader: { _ in [] }, processReader: {
            try ProcessDiscovery.read().filter { $0.pid == original.terminal.descriptor.pid }
        }, screenAdapters: [.iterm: original.adapter], managedPTY: ManagedPTYManager(environment: environment))
        try engine.start(poll: false)
        defer { engine.stop() }
        var records: [ProcessRecord] = [], observed: AgentSession?
        for _ in 0..<50 {
            records = try ProcessDiscovery.read().filter { $0.pid == original.terminal.descriptor.pid }
            observed = ProcessDiscovery.sessions(records, environment: { _ in ["TERM_PROGRAM": "iTerm.app"] }).first
            if observed != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard var session = observed else { throw AppError.message("Original terminal was not discovered: " + String(describing: records)) }
        session.cwd = directory.path
        engine.updateDiscovery([session], records: records)
        await engine.connectScreenHost(.iterm)
        try engine.setAutomatic(session.id, enabled: true)
        var status = RemoteNetworkStatus()
        let nodeID = UUID().uuidString
        let web = RemoteNetworkService(engine: engine, nodeID: nodeID, name: "Mac 원본 공유 검증", bonjourEnabled: false, discoveryAddresses: { [] }, onStatus: { status = $0 })
        try web.start(port: 0)
        defer { web.stop() }
        for _ in 0..<100 where !status.ready { try await Task.sleep(nanoseconds: 50_000_000) }
        guard let port = status.port, status.ready else { throw AppError.message("Sync listener failed") }
        let command = directory.appendingPathComponent("mac-input.json")
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["url": "http://127.0.0.1:\(port)", "nodeID": nodeID, "sessionID": session.id, "pid": session.pid, "tty": session.tty, "macInputPath": command.path]), as: UTF8.self)); fflush(stdout)
        var previous = ""
        while !Task.isCancelled {
            if let data = try? Data(contentsOf: command), let value = try? JSONSerialization.jsonObject(with: data) as? [String: String], let id = value["id"], id != previous {
                previous = id
                if value["command"] == "web-off" { web.stop() }
                else if value["command"] == "close" { original.terminal.close(); engine.updateDiscovery([], records: []) }
                else if let bytes = value["data"].flatMap({ Data(base64Encoded: $0) }) { try original.input(bytes) }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
