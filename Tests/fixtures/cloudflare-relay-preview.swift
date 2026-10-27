// Synthetic native gateway/relay. Never enumerates or inputs user terminals.
import Foundation
import AutoApproveCore

private final class RelayOriginal:@unchecked Sendable {
    let root:URL;private let lock=NSLock();private var value="HTTPS 443 합성 원본\nREADY> "
    init(_ root:URL) {self.root=root}
    func screen(_ tty:String)->TerminalScreen {lock.lock();defer{lock.unlock()};return TerminalScreen(tty:tty,contents:value,cursor:TerminalCursor(offset:value.utf16.count))}
    func input(_ input:RemoteTerminalInput) throws -> TerminalDelivery {
        lock.lock();defer{lock.unlock()};value+=input.bytes
        let path=root.appendingPathComponent("original-input.bin")
        if !FileManager.default.fileExists(atPath:path.path) {FileManager.default.createFile(atPath:path.path,contents:Data())}
        let file=try FileHandle(forWritingTo:path);defer{try? file.close()};let offset = try file.seekToEnd();let bytes = Data(input.bytes.utf8);try file.write(contentsOf:bytes)
        let timing = root.appendingPathComponent("original-times.jsonl")
        if !FileManager.default.fileExists(atPath:timing.path) {FileManager.default.createFile(atPath:timing.path,contents:Data())}
        let times = try FileHandle(forWritingTo:timing);defer {try? times.close()};_ = try times.seekToEnd()
        var entry = try JSONSerialization.data(withJSONObject:["offset":Int(offset),"count":bytes.count,"at":Date().timeIntervalSince1970*1000]);entry.append(10);try times.write(contentsOf:entry)
        return .sent
    }
}
@main struct RelayPreview {
    @MainActor static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),proxy=URL(string:CommandLine.arguments[2])!,key=CommandLine.arguments[3]
        let origin="https://relay.tunnel-qa.invalid"
        let pin=CommandLine.arguments.contains("--pin") ? try RemoteTunnelPIN.create("001234"):nil
        let original=RelayOriginal(root)
        let records=ProcessDiscovery.parse("2000000000 1 ?? 2000000000 0 Tue Oct 27 09:00:00 2026 /Applications/iTerm.app/Contents/MacOS/iTerm2/iTermServer\n2000000001 2000000000 ttys093 2000000001 2000000001 Tue Oct 27 09:00:01 2026 /fixture/codex")
        let adapter=ScreenHostAdapter(screens:{targets in TerminalSnapshot(screens:targets.map {original.screen($0.tty)})},approve:{_,_,_ in .missingTarget},reveal:{_ in nil},input:{_,_,_,input in try original.input(input)})
        let environment=["HOME":root.path,"ZDOTDIR":root.path,"PATH":"/usr/bin:/bin:/usr/sbin:/sbin","PS1":"QA> "]
        let screenProbe=ScreenControlPreviewProbe(root)
        let screenControl=RemoteScreenControl(services:screenProbe.services())
        let screenSources=[TestScreenSource(id:1,scope:"display",title:"합성 Worker 화면",width:1920,height:1080)]
        let screens=TestScreenSharing(permission:{_ in true},sources:{screenSources},capture:{try await screenProbe.image($0)},remoteControl:screenControl)
        guard let release=RemoteWebVersion.current else {throw AppError.message("Missing fixture release")}
        let published=PublishedUpdateServices {request,_ in
            guard request.url?.absoluteString=="https://api.github.com/repos/newdlops/autoapprove/releases/latest" else {throw AppError.message("Unexpected release request")}
            return PublishedUpdateReply(status:200,body:try JSONSerialization.data(withJSONObject:["tag_name":"v"+release.version,"draft":false,"prerelease":false,"assets":[]]))
        }
        let secrets=RelayAccountSecrets();var accountSecrets=CloudflareServices.live
        accountSecrets.readSecret={_,key in secrets.values[key]};accountSecrets.saveSecret={_,key,value in secrets.values[key]=value}
        let engine=try ApprovalEngine(paths:AppPaths(directory:root.appendingPathComponent("profile")),claudeRegistryReader:{_ in []},processReader:{records},screenAdapters:[.iterm:adapter],managedPTY:ManagedPTYManager(environment:environment),testScreenSharing:screens,cloudflareServices:accountSecrets,publishedUpdateServices:published)
        if CommandLine.arguments.contains("--accounts") {engine.agentAccounts=AgentAccounts(services:try AgentAccountFixture.services(root.appendingPathComponent("account-login")));try await engine.setTunnelPIN("001234")}
        defer{engine.stop()};try engine.start(poll:false)
        _=try await screens.start(["scope":"display","sourceID":1,"durationSeconds":900],owner:"synthetic-worker-preview")
        var originals=ProcessDiscovery.sessions(records);for i in originals.indices {originals[i].terminal = .iterm;originals[i].cwd=root.path}
        engine.updateDiscovery(originals,records:records);await engine.connectScreenHost(.iterm)
        var webStatus=RemoteNetworkStatus()
        let web=RemoteNetworkService(engine:engine,nodeID:UUID().uuidString,name:"HTTPS 443 QA",bonjourEnabled:false,loopbackOnly:true,discoveryAddresses:{[]},onStatus:{webStatus=$0})
        defer{web.stop()};try web.start(port:0)
        for _ in 0..<200 where !webStatus.ready {try await Task.sleep(for:.milliseconds(20))}
        guard let webPort=webStatus.port,webStatus.ready else {throw AppError.message("QA web unavailable")}
        let session=URLSession(configuration:.ephemeral)
        let services=CloudflareRelayServices(connect:{request in
            var mapped=request;mapped.url=URL(string:proxy.absoluteString.replacingOccurrences(of:"http:",with:"ws:")+"/_autoapprove/connector")!
            let owned=URLSession(configuration:.ephemeral)
            return CloudflareRelaySocket(session:owned,task:owned.webSocketTask(with:mapped))
        },probe:{request in
            var mapped=request;mapped.url=URL(string:proxy.absoluteString+request.url!.path)!;mapped.setValue("relay.tunnel-qa.invalid",forHTTPHeaderField:"Host")
            let (data,response)=try await session.data(for:mapped)
            return CloudflareHTTPReply(data:data,status:(response as? HTTPURLResponse)?.statusCode ?? 0)
        },diagnostic:{value in
            let path=root.appendingPathComponent("diagnostics");if !FileManager.default.fileExists(atPath:path.path) {FileManager.default.createFile(atPath:path.path,contents:Data())}
            if let file=try? FileHandle(forWritingTo:path) {defer{try? file.close()};try? file.seekToEnd();try? file.write(contentsOf:Data((value+"\n").utf8))}
        })
        var writes=0
        let controller=CloudflareRelayController(handler:{request in
            if request.path=="/api/large" {return RemoteHTTPResponse(body:Data(repeating:97,count:1_048_576),contentType:"application/octet-stream")}
            if request.path=="/api/echo" {
                writes+=1;try? Data(String(writes).utf8).write(to:root.appendingPathComponent("writes"))
                return (try? .json(["echo":String(decoding:request.body,as:UTF8.self),"writes":String(writes)])) ?? .error(RemoteHTTPError(500,"fixture"))
            }
            if request.path=="/api/pty/input",let value=try? JSONSerialization.jsonObject(with:request.body) as? JSONObject,let id=value["requestID"] as? String {
                let path=root.appendingPathComponent("native-inputs");if !FileManager.default.fileExists(atPath:path.path) {FileManager.default.createFile(atPath:path.path,contents:Data())}
                if let file=try? FileHandle(forWritingTo:path) {defer{try? file.close()};_ = try? file.seekToEnd();try? file.write(contentsOf:Data((id+"\n").utf8))}
            }
            return await web.handle(request)
        },services:services,onStatus:{status in
            let value:[String:String]=["phase":status.phase,"detail":status.detail,"local":status.localURL ?? ""]
            try? JSONSerialization.data(withJSONObject:value).write(to:root.appendingPathComponent("status.json"),options:.atomic)
        })
        defer {controller.stop();session.invalidateAndCancel()}
        var configuration=RemoteTunnelConfiguration();configuration.provider = .https;configuration.publicURL=origin
        let credential=CloudflareRelayCredential(script:"autoapprove-relay-"+String(repeating:"a",count:32),origin:origin,key:key)
        try await controller.start(configuration,credential:JSONEncoder().encode(credential),pin:pin)
        print(String(decoding:try JSONSerialization.data(withJSONObject:["key":controller.accessKey!,"owner":"http://127.0.0.1:\(webPort)"]),as:UTF8.self));fflush(stdout)
        while true {
            if (try? String(contentsOf:root.appendingPathComponent("pin-control"),encoding:.utf8))=="rotate" {
                let next=try await Task.detached {try RemoteTunnelPIN.create("009876")}.value
                controller.setPIN(next,accessKey:String(repeating:"m",count:43));try FileManager.default.removeItem(at:root.appendingPathComponent("pin-control"))
            }
            if let share=controller.shareURL {try Data(String(share.fragment != nil).utf8).write(to:root.appendingPathComponent("share-has-fragment"))}
            if (try? String(contentsOf:root.appendingPathComponent("stop"),encoding:.utf8)) == "stop" {controller.stop();return}
            try await Task.sleep(for:.milliseconds(20))
        }
    }
}
private final class RelayAccountSecrets:@unchecked Sendable {var values:[String:Data]=[:]}
