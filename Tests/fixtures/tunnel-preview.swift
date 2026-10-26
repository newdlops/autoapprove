// Only synthetic originals and explicitly created private PTYs. No LAN scan.
import Foundation
import AutoApproveCore

private final class TunnelOriginal: @unchecked Sendable {
    let root:URL
    private let lock=NSLock()
    private var value="외부 접속 검증 · 합성 원본\nREADY> "
    init(_ root:URL) { self.root=root }
    func read(_ tty:String) -> TerminalScreen {
        lock.lock(); defer {lock.unlock()}
        return TerminalScreen(tty:tty,contents:value,cursor:TerminalCursor(offset:value.utf16.count))
    }
    func input(_ input:RemoteTerminalInput) throws -> TerminalDelivery {
        lock.lock(); defer {lock.unlock()}; value += input.bytes
        let path=root.appendingPathComponent("original-input.bin")
        if !FileManager.default.fileExists(atPath:path.path) { FileManager.default.createFile(atPath:path.path,contents:Data()) }
        let file=try FileHandle(forWritingTo:path); defer {try? file.close()}
        try file.seekToEnd(); try file.write(contentsOf:Data(input.bytes.utf8)); return .sent
    }
}

@main struct TunnelPreview {
    @MainActor static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]), original=TunnelOriginal(URL(fileURLWithPath:CommandLine.arguments[1]))
        let records=ProcessDiscovery.parse("2000000000 1 ?? 2000000000 0 Mon Oct 26 09:00:00 2026 /Applications/iTerm.app/Contents/MacOS/iTerm2/iTermServer\n2000000001 2000000000 ttys093 2000000001 2000000001 Mon Oct 26 09:00:01 2026 /fixture/codex")
        let adapter=ScreenHostAdapter(screens:{ targets in TerminalSnapshot(screens:targets.map { original.read($0.tty) }) },approve:{_,_,_ in .missingTarget},reveal:{_ in nil},input:{_,_,_,input in try original.input(input)})
        let environment=["HOME":root.path,"ZDOTDIR":root.path,"PATH":root.path+":/usr/bin:/bin:/usr/sbin:/sbin","PS1":"QA> "]
        let engine=try ApprovalEngine(paths:AppPaths(directory:root.appendingPathComponent("profile")),claudeRegistryReader:{_ in []},processReader:{records},screenAdapters:[.iterm:adapter],managedPTY:ManagedPTYManager(environment:environment))
        defer {engine.stop()}; try engine.start(poll:false)
        var sessions=ProcessDiscovery.sessions(records); for i in sessions.indices {sessions[i].terminal = .iterm;sessions[i].cwd=root.path}
        engine.updateDiscovery(sessions,records:records); await engine.connectScreenHost(.iterm)
        var status=RemoteNetworkStatus()
        let web=RemoteNetworkService(engine:engine,nodeID:UUID().uuidString,name:"Tunnel QA",bonjourEnabled:false,loopbackOnly:true,discoveryAddresses:{[]},onStatus:{status=$0})
        defer {web.stop()}; try web.start(port:0)
        for _ in 0..<200 where !status.ready {try await Task.sleep(for:.milliseconds(20))}
        guard let port=status.port,status.ready else {throw AppError.message("QA listener unavailable")}
        let stream=try RemoteTunnelGateway(handler:{ await web.handle($0) })
        let polling=try RemoteTunnelGateway(polling:true,handler:{ await web.handle($0) })
        let expiry=try RemoteTunnelGateway(polling:true,sessionDuration:2,handler:{ await web.handle($0) })
        defer {stream.stop();polling.stop();expiry.stop()}
        try await stream.start(port:0);try stream.setOrigin("https://stream.tunnel-qa.invalid")
        try await polling.start(port:0);try polling.setOrigin("https://poll.tunnel-qa.invalid")
        try await expiry.start(port:0);try expiry.setOrigin("https://expiry.tunnel-qa.invalid")
        let info:JSONObject=["owner":"http://127.0.0.1:\(port)","stream":["port":stream.port!,"key":stream.accessKey],"poll":["port":polling.port!,"key":polling.accessKey],"expiry":["port":expiry.port!,"key":expiry.accessKey]]
        print(String(decoding:try JSONSerialization.data(withJSONObject:info),as:UTF8.self));fflush(stdout)
        let controller=RemoteTunnelController(directory:root,handler:{await web.handle($0)},onStatus:{value in
            let safe:JSONObject=["phase":value.phase,"detail":value.detail,"publicURL":value.publicURL ?? "","localURL":value.localURL ?? ""]
            try? JSONSerialization.data(withJSONObject:safe).write(to:root.appendingPathComponent("controller-status.json"),options:.atomic)
        })
        defer {controller.stop(waitForExit:true)}
        var generation = -1
        while !Task.isCancelled {
            if let data=try? Data(contentsOf:root.appendingPathComponent("control.json")),let command=try? JSONSerialization.jsonObject(with:data) as? JSONObject,let next=command["generation"] as? Int,next != generation {
                generation=next
                do {
                    switch command["action"] as? String {
                    case "reset-original":engine.updateDiscovery(sessions,records:records);await engine.connectScreenHost(.iterm)
                    case "rotate":
                        try stream.setOrigin("https://rotated.tunnel-qa.invalid")
                    case "stop": stream.stop();polling.stop();expiry.stop();controller.stop(waitForExit:true)
                    case "install": _ = try await RemoteTunnelTool.install(directory:root)
                    case "quick", "named":
                        var configuration=RemoteTunnelConfiguration();configuration.port=UInt16(command["port"] as? Int ?? 28966)
                        configuration.provider=command["action"] as? String == "quick" ? .quick : .named
                        configuration.publicURL="https://named.tunnel-qa.invalid";configuration.executable=command["executable"] as? String ?? ""
                        try await controller.start(configuration,token:command["token"] as? String ?? "")
                    case "stop-controller":controller.stop()
                    default:break
                    }
                    try JSONSerialization.data(withJSONObject:["generation":next,"ok":true,"shareURL":controller.shareURL?.absoluteString ?? "","accessKey":controller.accessKey ?? ""]).write(to:root.appendingPathComponent("control-result.json"),options:.atomic)
                }catch{try JSONSerialization.data(withJSONObject:["generation":next,"ok":false,"error":error.localizedDescription]).write(to:root.appendingPathComponent("control-result.json"),options:.atomic)}
            }
            if controller.status.ready {try? Data((controller.shareURL?.absoluteString ?? "").utf8).write(to:root.appendingPathComponent("public-share-url"),options:.atomic)}
            try await Task.sleep(for:.milliseconds(20))
        }
    }
}
