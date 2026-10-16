import Foundation
import Darwin
import AutoApproveCore

/// Controlled comparisons only: fake process identity, serialized synthetic
/// screen reads and a non-prompting synthetic permission delay. No real terminal,
/// network listener, input or permission changes.
private final class SerialSyntheticScreen: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func read(_ tty: String) -> TerminalScreen {
        lock.lock(); defer { lock.unlock() }
        count += 1; Thread.sleep(forTimeInterval:0.08)
        return TerminalScreen(tty:tty,contents:"Synthetic shared source\nREADY> ")
    }
    var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@main struct TerminalConnectionBench {
    static var now: Double { ProcessInfo.processInfo.systemUptime }
    static var cpu: Double {
        var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
        return Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1_000_000
    }
    @MainActor static func main() async {
        do { try await measure() }
        catch { fputs("Connection benchmark failed: \(error)\n",stderr); exit(1) }
    }
    @MainActor static func measure() async throws {
        let root = URL(fileURLWithPath:"/private/tmp/aa-connection-bench-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let records = ProcessDiscovery.parse("88 1 ttys080 88 88 Tue Sep 22 15:00:00 2026 /usr/local/bin/codex")
        var session = ProcessDiscovery.sessions(records)[0]; session.terminal = .terminal
        let source = SerialSyntheticScreen()
        let adapter = ScreenHostAdapter(screens:{TerminalSnapshot(screens:$0.map{source.read($0.tty)})},
            approve:{_,_,_ in .missingTarget},reveal:{_ in nil},
            presentationScreens:{TerminalSnapshot(screens:$0.map{TerminalScreen(tty:$0.tty,contents:"Synthetic live cursor",cursor:TerminalCursor(offset:0))})})
        let engine = try ApprovalEngine(paths:AppPaths(directory:root.appendingPathComponent("read")),processReader:{records},
            screenAdapters:[.terminal:adapter],terminalInputAvailable:{false})
        defer { engine.stop() }
        engine.updateDiscovery([session],records:records); await engine.connectTerminal()
        var groups:[[String:Any]] = []
        for readers in [2,8] {
            for iteration in 0..<3 {
                try await Task.sleep(for:.milliseconds(2100))
                let before = source.reads, cpuStart = cpu
                let tasks = (0..<readers).map { index in Task { @MainActor in
                    let start = now
                    let frame = try await engine.remoteTerminal(sessionID:session.id,realtime:index%2 == 1,initial:true)
                    guard frame.screen == "Synthetic shared source\nREADY> " else { throw AppError.message("Synthetic first screen differs") }
                    return (now-start)*1000
                } }
                var samples:[Double] = []
                for task in tasks { samples.append(try await task.value) }
                let count = source.reads-before
                #if CONNECTION_OPTIMIZED
                guard count == 1 else { throw AppError.message("Concurrent initial reads did not share one source operation") }
                #else
                guard count == readers else { throw AppError.message("Unexpected baseline source count") }
                #endif
                let live = try await engine.remoteTerminal(sessionID:session.id,realtime:true)
                guard live.cursor != nil else { throw AppError.message("First text delayed the live cursor") }
                groups.append(["readers":readers,"iteration":iteration,"sourceReads":count,"firstFrameMS":samples,"cpuMS":(cpu-cpuStart)*1000,"liveCursor":true])
            }
        }
        let query: @Sendable () -> Bool = { Thread.sleep(forTimeInterval:0.12); return true }
        #if CONNECTION_OPTIMIZED
        let capture = TerminalWindowCapture(permissions:{TerminalWindowPermissions(screen:false,keyboard:false,automation:true)},automationQuery:query)
        #else
        let capture = TerminalWindowCapture(permissions:{TerminalWindowPermissions(screen:false,keyboard:false,automation:true)},automationPermission:{query()})
        #endif
        let permissionEngine = try ApprovalEngine(paths:AppPaths(directory:root.appendingPathComponent("permissions")),processReader:{records},
            screenAdapters:[.terminal:adapter],terminalWindowCapture:capture,terminalInputAvailable:{false})
        defer { permissionEngine.stop() }
        permissionEngine.updateDiscovery([session],records:records); await permissionEngine.connectTerminal()
        var permissions:[[String:Double]] = []
        for _ in 0..<5 {
            let start = now
            let heartbeat = Task.detached {
                try await Task.sleep(for:.milliseconds(20))
                return await MainActor.run { (now-start)*1000 }
            }
            _ = try await permissionEngine.remoteTerminal(sessionID:session.id,initial:true)
            let frameMS = (now-start)*1000, heartbeatMS = try await heartbeat.value
            permissions.append(["frameMS":frameMS,"mainActorHeartbeatMS":heartbeatMS])
        }
        var report:[String:Any] = ["groups":groups,"permissions":permissions,"inputPosts":0,
            "scope":"Actual Core with fake enrolled identity and one serialized 80ms synthetic source; 120ms synthetic permission query, 20ms actor heartbeat. No real terminal, HTTP, phone, VPN or security product measurement."]
        #if CONNECTION_OPTIMIZED
        let metrics = RemoteTerminalPerformance(), start = now, cpuStart = cpu
        for _ in 0..<100_000 { metrics.observe(.identity,elapsed:0.001) }
        report["timingObserver"] = ["records":100_000,"totalMS":(now-start)*1000,"cpuMS":(cpu-cpuStart)*1000,"retained":metrics.snapshot().stages["identity"]!.sampleCount]
        report["timings"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(RemoteTerminalPerformance.shared.snapshot()))
        #endif
        print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
    }
}
