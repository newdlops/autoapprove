// Synthetic original + real, explicitly created PTYs in a private profile.
// Never reads or writes a user's CLI. The adapter models authoritative editing.
import Foundation
import Darwin
import AutoApproveCore
import TerminalInputSupport

private final class EditingOriginal: @unchecked Sendable {
    private let lock = NSLock()
    private var line: [Character] = [], column = 0
    private var history = "입력·커서 지연 검증 · 합성 원본\nREADY> "
    private var inputs: [String] = []
    private var reads = 0
    let root: URL
    init(_ root: URL) { self.root = root }
    private var text: String { history + String(line) }
    func read(_ tty: String) -> TerminalScreen {
        lock.lock(); defer { lock.unlock() }; reads += 1
        return TerminalScreen(tty:tty,contents:text,
            cursor:TerminalCursor(offset:(history + String(line.prefix(column))).utf16.count))
    }
    func input(_ expected: String, _ input: RemoteTerminalInput) throws -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }
        // Match production relay semantics: the engine revalidates exact source
        // identity; live characters need not wait for their own screen echo.
        guard input.isRelay || text == expected else { return .screenChanged }
        switch input.kind {
        case .characters, .text, .submit:
            let value = Array(input.text)
            line.insert(contentsOf:value,at:column); column += value.count
            if input.kind == .submit { history += String(line) + "\nREADY> "; line = []; column = 0 }
        case .left: column = max(0,column-1)
        case .right: column = min(line.count,column+1)
        case .home: column = 0
        case .end: column = line.count
        case .backspace: if column > 0 { column -= 1; line.remove(at:column) }
        case .delete: if column < line.count { line.remove(at:column) }
        case .enter, .interrupt: history += String(line) + "\nREADY> "; line = []; column = 0
        default: break
        }
        inputs.append(input.bytes)
        try JSONSerialization.data(withJSONObject:["inputs":inputs,"reads":reads]).write(to:root.appendingPathComponent("inputs.json"),options:.atomic)
        return .sent
    }
}

@main struct TerminalInputLatencyFixture {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1])
        let original = EditingOriginal(root)
        let records = ProcessDiscovery.parse("84000 1 ttys088 84000 84000 Thu Oct 15 09:00:00 2026 /fixture/codex")
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX")
        formatter.timeZone = .current; formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let identity = TTYInputIdentity(pid:84000,processGroup:84000,uid:getuid(),effectiveUID:geteuid(),device:42,
            startSeconds:UInt64(formatter.date(from:records[0].started)!.timeIntervalSince1970),startMicroseconds:17)
        let adapter = ScreenHostAdapter(screens:{ targets in TerminalSnapshot(screens:targets.map { original.read($0.tty) }) },
            approve:{_,_,_ in .missingTarget},reveal:{_ in nil},input:{_,expected,_,input in try original.input(expected,input)},
            presentationScreens:{ targets in TerminalSnapshot(screens:targets.map { original.read($0.tty) }) })
        let capture = TerminalWindowCapture(permissions:{ TerminalWindowPermissions(screen:false,keyboard:false,automation:true) },automationQuery:{true})
        let environment = ProcessInfo.processInfo.environment.merging(["HOME":root.path,"ZDOTDIR":root.path,
            "PATH":root.path+":/usr/bin:/bin:/usr/sbin:/sbin","PS1":"QA> "]) {_,value in value}
        let engine = try ApprovalEngine(paths:AppPaths(directory:root.appendingPathComponent("profile")),claudeRegistryReader:{_ in []},processReader:{records},
            screenAdapters:[.terminal:adapter],managedPTY:ManagedPTYManager(environment:environment),
            terminalWindowCapture:capture,terminalInputAvailable:{true},terminalInputIdentity:{_ in identity})
        defer { engine.stop() }; try engine.start(poll:false)
        var sessions = ProcessDiscovery.sessions(records)
        for i in sessions.indices { sessions[i].terminal = .terminal; sessions[i].cwd = root.path }
        engine.updateDiscovery(sessions,records:records); await engine.connectTerminal()
        var status = RemoteNetworkStatus()
        let web = RemoteNetworkService(engine:engine,nodeID:UUID().uuidString,name:"Input latency QA",bonjourEnabled:false,discoveryAddresses:{[]},onStatus:{status=$0})
        defer { web.stop() }; try web.start(port:0)
        for _ in 0..<200 where !status.ready { try await Task.sleep(for:.milliseconds(20)) }
        guard let port=status.port,status.ready else { throw AppError.message("Isolated latency listener unavailable") }
        print("{\"url\":\"http://127.0.0.1:\(port)\"}"); fflush(stdout)
        while !Task.isCancelled { try await Task.sleep(for:.seconds(1)) }
    }
}
