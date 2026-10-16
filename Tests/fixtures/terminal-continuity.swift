// Controllable synthetic originals on real Core HTTP/SSE. All screen bytes and
// input targets are synthetic; no user terminal is captured or controlled.
import Foundation
import Darwin
import AutoApproveCore
import TerminalInputSupport

private final class ContinuityOriginal: @unchecked Sendable {
    private let lock = NSLock()
    private var screen: String
    private var allowed = true, delay: TimeInterval = 0
    private var reads = 0, queries = 0
    private var inputs: [String] = []
    init() {
        screen = (0..<500).map { index in
            var x = UInt64(index+1) &* 6364136223846793005
            var value = ""
            for _ in 0..<3 { x = x &* 2862933555777941757 &+ 3037000493; value += String(x,radix:16) }
            return "[\(index)] 합성 원본 한글🙂 e\u{301} /fixture/source/\(value)\n"
        }.joined() + "READY> "
    }
    func read(_ tty: String) -> TerminalScreen {
        lock.lock(); reads += 1; let text = screen, pause = delay; lock.unlock()
        if pause > 0 { Thread.sleep(forTimeInterval:pause) }
        return TerminalScreen(tty:tty,contents:text,
            appearance:TerminalAppearance(runs:[.init(offset:0,length:3,fg:"#87d7ff",bold:true)]),
            cursor:TerminalCursor(offset:(text as NSString).length))
    }
    func permission() -> Bool {
        lock.lock(); defer { lock.unlock() }; queries += 1; return allowed
    }
    func change(_ value: JSONObject) {
        lock.lock(); defer { lock.unlock() }
        if let value = value["allowed"] as? Bool { allowed = value }
        if let value = value["delayMS"] as? Double { delay = min(2000,max(0,value))/1000 }
        if let value = value["append"] as? String { screen += value }
        if let value = value["screen"] as? String { screen = value }
    }
    func input(_ expected: String, _ input: RemoteTerminalInput) -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }
        guard screen == expected else { return .screenChanged }
        inputs.append(input.bytes); screen += "\n[명시적 입력] " + input.bytes
        return .sent
    }
    func stats() -> JSONObject {
        lock.lock(); defer { lock.unlock() }
        return ["reads":reads,"queries":queries,"inputs":inputs,"allowed":allowed]
    }
}

@main struct TerminalContinuityPreview {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1])
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let original = ContinuityOriginal()
        func records(_ epoch: Int) -> [ProcessRecord] {
            ProcessDiscovery.parse("84000 1 ttys088 84000 84000 Thu Oct 15 09:00:\(String(format:"%02d",epoch)) 2026 /usr/local/bin/codex")
        }
        let initialRecords = records(0)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX")
        formatter.timeZone = .current; formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let identity = TTYInputIdentity(pid:84000,processGroup:84000,uid:getuid(),effectiveUID:geteuid(),device:42,
            startSeconds:UInt64(formatter.date(from:initialRecords[0].started)!.timeIntervalSince1970),startMicroseconds:17)
        let adapter = ScreenHostAdapter(screens:{ targets in TerminalSnapshot(screens:targets.map { original.read($0.tty) }) },
            approve:{_,_,_ in .missingTarget},reveal:{_ in nil},input:{_,expected,_,input in original.input(expected,input)},
            presentationScreens:{ targets in TerminalSnapshot(screens:targets.map { original.read($0.tty) }) })
        let capture = TerminalWindowCapture(permissions:{ TerminalWindowPermissions(screen:false,keyboard:false,automation:true) },automationQuery:{ original.permission() })
        let engine = try ApprovalEngine(paths:AppPaths(directory:root),claudeRegistryReader:{_ in []},processReader:{initialRecords},
            screenAdapters:[.terminal:adapter],terminalWindowCapture:capture,terminalInputAvailable:{true},terminalInputIdentity:{_ in identity})
        try engine.start(poll:false)
        func discover(_ values: [ProcessRecord]) {
            var sessions = ProcessDiscovery.sessions(values)
            for index in sessions.indices { sessions[index].terminal = .terminal; sessions[index].cwd = "/fixture/continuity" }
            engine.updateDiscovery(sessions,records:values)
        }
        discover(initialRecords); await engine.connectTerminal()
        var status = RemoteNetworkStatus()
        let web = RemoteNetworkService(engine:engine,nodeID:UUID().uuidString,name:"Continuity QA",bonjourEnabled:false,discoveryAddresses:{[]},onStatus:{status = $0})
        try web.start(port:0)
        for _ in 0..<100 where !status.ready { try await Task.sleep(for:.milliseconds(20)) }
        guard let port = status.port, status.ready else { throw AppError.message("Synthetic listener unavailable") }
        let control = root.appendingPathComponent("control.json"), stats = root.appendingPathComponent("observations.json")
        let info: JSONObject = ["id":web.nodeID,"url":"http://127.0.0.1:\(port)","control":control.path,"observations":stats.path]
        print(String(decoding:try JSONSerialization.data(withJSONObject:info),as:UTF8.self)); fflush(stdout)
        var generation = -1, previous = Data(), noise = 0, storm = false
        while !Task.isCancelled {
            if let data = try? Data(contentsOf:control), let value = try? JSONSerialization.jsonObject(with:data) as? JSONObject,
               let next = value["generation"] as? Int, next != generation {
                original.change(value)
                if let enabled = value["storm"] as? Bool { storm = enabled }
                if let epoch = value["epoch"] as? Int { discover(records(epoch)) }
                if value["disconnect"] as? Bool == true { engine.stop() }
                if value["stopWeb"] as? Bool == true { web.stop() }
                if value["restartWeb"] as? Bool == true { try web.start(port:port) }
                generation = next
            }
            if storm, let id = ProcessDiscovery.sessions(initialRecords).first?.id {
                noise += 1
                engine.receiveScreen(sessionID:id,raw:"Synthetic unrelated change notification",generation:"fixture-noise-\(noise)")
            }
            var observed = original.stats(); observed["generation"] = generation
            let data = try JSONSerialization.data(withJSONObject:observed,options:[.sortedKeys])
            if data != previous { try data.write(to:stats,options:.atomic); previous = data }
            try await Task.sleep(for:.milliseconds(20))
        }
        web.stop(); engine.stop()
    }
}
