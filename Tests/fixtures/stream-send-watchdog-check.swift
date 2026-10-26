import Foundation
import Network
import Darwin
import AutoApproveCore

// An observer of the compiled Core, not a replacement HTTP connection. The
// production accept callback is installed on an owned loopback-only listener.
// The service's discovery acceptor/monitors are cancelled before first await.
@main struct SendWatchdogWorker {
    enum Failure: Error { case invalid(String) }
    static let owner = "11111111-1111-4111-8111-111111111111"
    static func require(_ value: Bool, _ reason: String) throws { if !value { throw Failure.invalid(reason) } }
    static func owned<T>(_ object: Any, _ label: String, _ type: T.Type) -> T? {
        guard let raw = Mirror(reflecting: object).children.first(where: { $0.label == label })?.value else { return nil }
        return (raw as? T) ?? Mirror(reflecting: raw).children.first?.value as? T
    }
    static func emit(_ object: [String: Any]) throws {
        print(String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)); fflush(stdout)
    }
    static func metrics() throws -> [String: Any] {
        var usage = rusage(), heap = malloc_statistics_t()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw Failure.invalid("self rusage failed") }
        malloc_zone_statistics(nil, &heap)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        var info = rusage_info_v4()
        let code = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard code == 0 else { throw Failure.invalid("self proc rusage failed") }
        return ["cpu": cpu, "blocks": heap.blocks_in_use, "heapBytes": heap.size_in_use,
                "footprint": info.ri_phys_footprint, "rss": info.ri_resident_size,
                "instructions": info.ri_instructions, "cycles": info.ri_cycles,
                "uptime": ProcessInfo.processInfo.systemUptime]
    }
    @MainActor static func main() async throws {
        let upstream = CommandLine.arguments[1], home = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [["id": owner, "name": "Owned synthetic upstream", "address": upstream]])
            .write(to: home.appendingPathComponent("web-peers.json"))
        let power = PowerControl(read: { PowerReading() }, ruleInstalled: { false }, ruleFile: { false },
            installRule: { throw Failure.invalid("Power mutation forbidden") }, removeRule: { throw Failure.invalid("Power mutation forbidden") },
            setSleepDisabled: { _ in throw Failure.invalid("Power mutation forbidden") }, startGuard: { _, _ in throw Failure.invalid("Power guard forbidden") })
        let engine = try ApprovalEngine(paths: AppPaths(directory: home), processReader: { [] }, screenAdapters: [:], powerControl: power)
        let service = RemoteNetworkService(engine: engine, nodeID: "22222222-2222-4222-8222-222222222222", name: "Owned synthetic gateway",
            bonjourEnabled: false, discoveryAddresses: { [] }, discoveryHints: { [] }, onStatus: { _ in })
        try service.start(port: 0)
        guard let original = owned(service, "listener", NWListener.self), let accept = original.newConnectionHandler else {
            throw Failure.invalid("Production Core accept callback missing")
        }
        original.stateUpdateHandler = nil; original.cancel()
        owned(service, "discoveryTask", Task<Void, Never>.self)?.cancel()
        owned(service, "pathMonitor", NWPathMonitor.self)?.cancel()
        for monitor in owned(service, "interfaceMonitors", [NWPathMonitor].self) ?? [] { monitor.cancel() }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = accept
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.resume()
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "owned.synthetic.accept"))
        }
        listener.stateUpdateHandler = nil
        defer { listener.cancel(); service.stop(); withExtendedLifetime(original) {}; withExtendedLifetime(engine) {} }
        try emit(["ready": true, "url": "http://127.0.0.1:\(listener.port!.rawValue)", "actualCoreAcceptAndSend": true,
                  "originalAcceptorCancelled": true, "loopbackOnly": true, "metrics": try metrics()])
        while let line = await Task.detached(priority: .utility, operation: { readLine() }).value {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let command = object["command"] as! String
            if command == "stop" { break }
            try require(command == "snapshot", "Only owned observer commands accepted")
            let values = Mirror(reflecting: service).children.first { $0.label == "connections" }!.value
            var states = [[String: Any]]()
            for entry in Mirror(reflecting: values).children {
                let client = Array(Mirror(reflecting: entry.value).children)[1].value
                guard let queue = owned(client, "queue", DispatchQueue.self) else { throw Failure.invalid("Owned connection queue missing") }
                states.append(queue.sync {
                    ["closed": owned(client, "closed", Bool.self) ?? false,
                     "sending": owned(client, "sending", Bool.self) ?? false,
                     "scheduled": owned(client, "sendDeadline", DispatchWorkItem.self) != nil || owned(client, "deadlineScheduled", Bool.self) == true,
                     "expiration": owned(client, "sendExpiresAt", UInt64.self).map { String($0) } ?? "none",
                     "nextPending": owned(client, "nextPending", Bool.self) ?? false]
                })
            }
            try emit(["id": object["id"]!, "metrics": try metrics(), "connections": states])
        }
    }
}
