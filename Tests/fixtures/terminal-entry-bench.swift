import Foundation
import Darwin
import AutoApproveCore

/// Explicit read-only timing: a real enrolled process identity, synthetic screen,
/// no listener, no PTY and no original input. Never serialize the target or text.
@main struct TerminalEntryBench {
    static func childCPU() -> Double {
        var usage = rusage(); getrusage(RUSAGE_CHILDREN,&usage)
        return Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1_000_000
    }
    @MainActor static func main() async {
        do { try await measure() }
        catch { fputs("Entry benchmark failed: \(error)\n",stderr); exit(1) }
    }
    @MainActor static func measure() async throws {
        let cold = CommandLine.arguments.contains("--cold-text")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var session = try decoder.decode(AgentSession.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        guard session.terminal == .terminal || session.terminal == .iterm else { throw AppError.message("Pass an enrolled Terminal or iTerm original") }
        let records = try ProcessDiscovery.read(pid:session.pid)
        guard records.contains(where:{$0.pid == session.pid && $0.started == session.started && $0.agent == session.agent && "/dev/"+$0.tty == session.tty}) else { throw AppError.message("Original identity changed") }
        let root = URL(fileURLWithPath:"/private/tmp/aa-terminal-entry-bench-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        session.automatic = false; session.phase = .idle; session.interruption = nil
        let screen = "Synthetic initial-screen benchmark\n"+String(repeating:"0123456789 한글 🙂 e\u{301}\n",count:90)
        var adapter = ScreenHostAdapter(screens:{targets in TerminalSnapshot(screens:targets.map{TerminalScreen(tty:$0.tty,contents:screen)})},
            approve:{_,_,_ in .missingTarget},reveal:{_ in nil})
        if cold {
            adapter.presentationScreens = { targets in
                Thread.sleep(forTimeInterval:0.25)
                return TerminalSnapshot(screens:targets.map{TerminalScreen(tty:$0.tty,contents:screen,cursor:TerminalCursor(offset:0))})
            }
        }
        let host: ScreenHost = session.terminal == .terminal ? .terminal : .iterm
        let engine = try ApprovalEngine(paths:AppPaths(directory:root),screenAdapters:[host:adapter],terminalInputAvailable:{false})
        defer { engine.stop() }
        engine.updateDiscovery([session],records:records)
        await engine.connectScreenHost(host)
        var samples:[[String:Any]] = []
        for index in 0..<(cold ? 3 : 10) {
            if cold {
                engine.disconnectScreenHost(host); await engine.connectScreenHost(host)
                try await Task.sleep(for:.milliseconds(2100))
            } else { await engine.refreshScreenHost(host) }
            let cpu = childCPU(), start = ProcessInfo.processInfo.systemUptime
            let frame = try await engine.remoteTerminal(sessionID:session.id,realtime:index%2 == 1,initial:true)
            guard frame.screen == screen else { throw AppError.message("Synthetic screen changed") }
            samples.append(["realtime":index%2 == 1,"seconds":ProcessInfo.processInfo.systemUptime-start,"childCPUSeconds":childCPU()-cpu])
            if cold {
                let live = try await engine.remoteTerminal(sessionID:session.id,realtime:true)
                guard live.cursor != nil else { throw AppError.message("Initial text suppressed the live presentation read") }
            }
        }
        let report:[String:Any] = ["samples":samples,"coldText":cold,"screenMatches":true,"inputPosts":0,
            "scope":cold ? "Actual Core with expired monitor and synthetic 250ms presentation, real enrolled identity and fresh synthetic text; immediate live cursor verified; no HTTP, listener, user screen reads or input" : "Actual initial-frame Core path with fresh monitor, real enrolled process identity and synthetic text; no HTTP, listener, user screen reads or input"]
        print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
    }
}
