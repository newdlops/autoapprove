// Production status analysis and HTTP with synthetic terminals only.
import Foundation
import AutoApproveCore

private final class StatusFrames: @unchecked Sendable {
    private let lock=NSLock()
    private var screens:[String:String]=[:]
    private var inputs=0
    func replace(_ values:[String:String]) {lock.lock();screens=values;lock.unlock()}
    func read(_ targets:[ScreenTarget])->TerminalSnapshot {
        lock.lock();defer {lock.unlock()}
        return TerminalSnapshot(screens:targets.compactMap {target in screens[target.tty].map {TerminalScreen(tty:target.tty,contents:$0)} })
    }
    func unexpectedInput()->TerminalDelivery {lock.lock();inputs+=1;lock.unlock();return .missingTarget}
    var inputCount:Int {lock.lock();defer {lock.unlock()};return inputs}
}

@main struct ActivityStatusPreview {
    @MainActor static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),frames=StatusFrames()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let claude="Completed synthetic task\n────────\n❯\n────────\nfixture-project | feature/status | Opus 5.5 | ctx 42% | 7d 94%\n⏵⏵ auto mode on (shift+tab to cycle)"
        let codex="Completed synthetic task\n›\nGPT-6.1-Sol max · ~/fixture · Ready · Context 35% left\n⚠ 2 warnings · f2 to view"
        let waiting="Giving this request a little extra thought\n› 1. Dismiss and keep waiting\n2. Learn more\nNo action is required. Codex will keep waiting, and this menu will close when the response is ready."
        let names=["Claude ready","Claude draft","Codex warnings","Codex server wait"]
        let sessions=(0..<4).map {index in
            var session=AgentSession(id:"process:\(2_000_000_000+index):status",agent:index<2 ? .claude : .codex,pid:Int32(2_000_000_000+index),started:"synthetic-status",tty:"/dev/status-fixture-\(index)",cwd:"/fixture/status-\(index)",terminal:.terminal)
            session.terminalTitle=names[index];return session
        }
        let original=Dictionary(uniqueKeysWithValues:zip(sessions.map(\.tty),[claude,claude.replacingOccurrences(of:"❯",with:"❯ Synthetic draft 한글😀"),codex,waiting]))
        frames.replace(original)
        let adapter=ScreenHostAdapter(screens:{frames.read($0)},approve:{_,_,_ in frames.unexpectedInput()},reveal:{_ in nil})
        let engine=try ApprovalEngine(paths:AppPaths(directory:root),claudeRegistryReader:{_ in []},processReader:{[]},screenAdapters:[.terminal:adapter])
        try engine.start(poll:false);engine.updateDiscovery(sessions,records:[]);await engine.connectTerminal()
        var status=RemoteNetworkStatus()
        let web=RemoteNetworkService(engine:engine,nodeID:UUID().uuidString,name:"Status fixture",bonjourEnabled:false,loopbackOnly:true,discoveryAddresses:{[]},onStatus:{status=$0})
        try web.start(port:0)
        for _ in 0..<100 where !status.ready {try await Task.sleep(for:.milliseconds(20))}
        guard let port=status.port,status.ready else {throw AppError.message("Synthetic status listener unavailable")}
        let control=root.appendingPathComponent("control.json"),stats=root.appendingPathComponent("observations.json")
        let info:JSONObject=["url":"http://127.0.0.1:\(port)","id":web.nodeID,"control":control.path,"stats":stats.path,"sessions":sessions.map(\.id)]
        print(String(decoding:try JSONSerialization.data(withJSONObject:info),as:UTF8.self));fflush(stdout)
        var generation=0,enabled=true,stop=false
        while !Task.isCancelled && !stop {
            if let data=try? Data(contentsOf:control),let value=try? JSONSerialization.jsonObject(with:data) as? JSONObject,let next=value["generation"] as? Int,next != generation {
                switch value["action"] as? String {
                case "missing":frames.replace([:])
                case "restore":frames.replace(original);enabled=true;await engine.connectTerminal()
                case "draft":var changed=original;changed[sessions[0].tty]=claude.replacingOccurrences(of:"❯",with:"❯ Synthetic draft 한글😀");frames.replace(changed)
                case "ambiguous":var changed=original;changed[sessions[0].tty]=claude+"\nUnrecognized footer";frames.replace(changed)
                case "disconnect":engine.disconnectTerminal();enabled=false
                case "stop":stop=true
                default:break
                }
                generation=next
            }
            if enabled && !stop {await engine.refreshTerminal()}
            let observed:JSONObject=["generation":generation,"inputs":frames.inputCount,"phases":engine.snapshot.sessions.map {$0.phase.rawValue}]
            try JSONSerialization.data(withJSONObject:observed).write(to:stats,options:.atomic)
            try await Task.sleep(for:.milliseconds(100))
        }
        web.stop();engine.stop()
    }
}
