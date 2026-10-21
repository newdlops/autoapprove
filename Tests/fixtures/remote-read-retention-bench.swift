import Foundation
import Darwin
import AutoApproveCore

/// Own synthetic adapters only: no terminal process, capture, input or listener.
final class ReadSource: @unchecked Sendable {
    let kind: String
    private let lock = NSLock()
    private var large = false
    private var reads = 0
    init(_ kind: String) { self.kind = kind }
    func useLarge(_ value: Bool) { lock.lock(); large = value; lock.unlock() }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return reads }
    func expected(_ tty: String, large: Bool) -> String {
        guard large else { return "ready \(tty)\n› " }
        let unit = kind == "iterm-unicode" ? "합성 e\u{301} 👩🏽‍💻 \(tty)\n" : "synthetic \(tty) ordinary output\n"
        return String(String(repeating: unit, count: 160_000 / unit.count + 2).suffix(160_000))
    }
    func snapshot(_ targets: [ScreenTarget]) -> TerminalSnapshot {
        lock.lock(); let large = large; reads += targets.count; lock.unlock()
        return TerminalSnapshot(screens: targets.map { target in
            let unit = kind == "iterm-unicode" ? "합성 e\u{301} 👩🏽‍💻 \(target.tty)\n" : "synthetic \(target.tty) ordinary output\n"
            let text = large ? String(repeating: unit, count: 1_048_576 / unit.utf8.count + 1) : "ready \(target.tty)\n› "
            let raw = kind == "terminal-cocoa" ? NSAppleEventDescriptor(string: text).stringValue! : text
            return TerminalScreen(tty: target.tty, contents: raw, title: "Synthetic retention fixture")
        })
    }
}

@main struct RemoteReadRetentionBench {
    struct State {
        let engine: ApprovalEngine
        let source: ReadSource
        let sessions: [AgentSession]
        let records: [ProcessRecord]
        let directory: URL
    }
    static func metrics() throws -> [String: Double] {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw AppError.message("Own memory counters unavailable: \(result)") }
        var allocator = malloc_statistics_t(); malloc_zone_statistics(nil, &allocator)
        return ["footprint": Double(info.phys_footprint), "peakResident": Double(usage.ru_maxrss),
            "liveAllocated": Double(allocator.size_in_use), "reservedAllocator": Double(allocator.size_allocated),
            "cpu": Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000,
            "wall": ProcessInfo.processInfo.systemUptime]
    }
    // Private-cache counts are diagnostic evidence, never a product API. The
    // mirror and its temporary task copies leave scope before measuring memory.
    @MainActor static func counts(_ engine: ApprovalEngine) -> [String: Int] {
        var result: [String: Int] = [:]
        for child in Mirror(reflecting: engine).children {
            if let label = child.label, ["remoteScreenReads", "remoteFrames"].contains(label) {
                result[label] = Mirror(reflecting: child.value).children.count
            }
        }
        return result
    }
    @MainActor static func make(_ kind: String, count: Int) async throws -> State {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-read-retention-" + UUID().uuidString)
        let records = ProcessDiscovery.parse((0..<count).map { index in
            let pid = 86000 + index
            return "\(pid) 1 ttys\(100 + index) \(pid) \(pid) Wed Oct 21 09:00:01 2026 /usr/local/bin/codex"
        }.joined(separator: "\n"))
        let host: ScreenHost = kind == "iterm-unicode" ? .iterm : .terminal
        let sessions = ProcessDiscovery.sessions(records).map { original in
            var session = original; session.terminal = host.kind; return session
        }
        let source = ReadSource(kind)
        let adapter = ScreenHostAdapter(screens: { source.snapshot($0) }, approve: { _,_,_ in
            fatalError("A read-only fixture cannot approve input")
        }, reveal: { _ in fatalError("A read-only fixture cannot reveal windows") })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), claudeRegistryReader: { _ in [] },
            processReader: { records }, screenAdapters: [host: adapter], terminalInputAvailable: { false }, terminalInputIdentity: { _ in nil })
        engine.updateDiscovery(sessions, records: records); await engine.connectScreenHost(host)
        return State(engine: engine, source: source, sessions: sessions, records: records, directory: directory)
    }
    @MainActor static func visit(_ state: State, large: Bool, range: Range<Int>? = nil) async throws -> Int {
        state.source.useLarge(large)
        var characters = 0
        let sessions = range.map { Array(state.sessions[$0]) } ?? state.sessions
        for session in sessions {
            let frame = try await state.engine.remoteTerminal(sessionID: session.id)
            guard frame.screen.utf8.elementsEqual(state.source.expected(session.tty, large: large).utf8), frame.inputReason == nil else {
                throw AppError.message("Output budget or input support changed")
            }
            characters += frame.screen.count
        }
        return characters
    }
    @MainActor static func originalsMatch(_ state: State) -> Bool {
        let current = state.engine.snapshot.sessions
        return current.count == state.sessions.count && state.sessions.allSatisfy { original in
            current.contains { $0.id == original.id && $0.pid == original.pid && $0.started == original.started &&
                $0.tty == original.tty && $0.terminal == original.terminal && !$0.automatic && $0.phase != .ended }
        }
    }
    @MainActor static func main() async throws {
        let mode = CommandLine.arguments.dropFirst().first ?? "retention"
        let states = try await ["terminal-native", "terminal-cocoa", "iterm-unicode"].asyncMap { try await make($0, count: mode == "retention" ? 36 : 4) }
        defer { for state in states { state.engine.stop(); try? FileManager.default.removeItem(at: state.directory) } }
        let before = try metrics()
        if mode == "retention" {
            var characters = 0, phases: [JSONObject] = []
            for batch in 0..<3 {
                let start = try metrics()
                for state in states { characters += try await visit(state, large: true, range: (batch * 12)..<((batch + 1) * 12)); state.source.useLarge(false) }
                let filledCounts = states.map { counts($0.engine) }, filled = try metrics()
                guard filledCounts.allSatisfy({ $0["remoteFrames"] == 12 }) else { throw AppError.message("Expected this batch's12 original frames") }
                try await Task.sleep(for: .milliseconds(10_200))
                let cleanupStart = try metrics()
                for state in states { state.engine.updateDiscovery(state.sessions, records: state.records) }
                let expiredCounts = states.map { counts($0.engine) }, expired = try metrics()
                guard expiredCounts.allSatisfy({ $0["remoteFrames"] == 0 }), states.allSatisfy({ $0.source.count() == 36 + (batch + 1) * 12 && originalsMatch($0) }) else {
                    throw AppError.message("Expiration must preserve every live original without an adapter read")
                }
                phases.append(["batch": batch, "before": start, "filled": filled, "cleanupStart": cleanupStart, "expired": expired,
                    "filledCounts": filledCounts, "expiredCounts": expiredCounts])
            }
            for state in states { characters += try await visit(state, large: false) }
            guard states.allSatisfy({ $0.source.count() == 108 && originalsMatch($0) }) else {
                throw AppError.message("Reopening must read the same live sessions exactly once")
            }
            print(String(decoding: try JSONSerialization.data(withJSONObject: ["mode": mode, "before": before, "phases": phases,
                "characters": characters, "sessions": 108, "verifiedFrames": 216, "inputPosts": 0, "captures": 0], options: [.sortedKeys]), as: UTF8.self))
        } else {
            guard mode == "controls" else { throw AppError.message("Unknown benchmark mode") }
            for state in states { _ = try await visit(state, large: false) }
            let start = try metrics(); var characters = 0
            for _ in 0..<8192 {
                for state in states {
                    characters += try await visit(state, large: false)
                    state.engine.updateDiscovery(state.sessions, records: state.records)
                }
            }
            let end = try metrics()
            guard states.allSatisfy({ originalsMatch($0) }) else {
                throw AppError.message("Controls must preserve source sessions and policy")
            }
            print(String(decoding: try JSONSerialization.data(withJSONObject: ["mode": mode, "cpu": end["cpu"]! - start["cpu"]!,
                "wall": end["wall"]! - start["wall"]!, "footprint": end["footprint"]!, "peakResident": end["peakResident"]!,
                "characters": characters, "frames": 98304, "inputPosts": 0, "captures": 0], options: [.sortedKeys]), as: UTF8.self))
        }
    }
}

private extension Array {
    @MainActor func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []; for element in self { result.append(try await transform(element)) }; return result
    }
}
