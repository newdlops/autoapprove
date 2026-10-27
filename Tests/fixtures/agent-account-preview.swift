import Foundation
import AutoApproveCore

@main struct AgentAccountPreview {
    @MainActor static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),fm=FileManager.default
        let secrets=AccountFixtureSecrets()
        var cloudflare=CloudflareServices.live
        cloudflare.readSecret={_,key in secrets.values[key]};cloudflare.saveSecret={_,key,data in secrets.values[key]=data}
        let localEnv=["HOME":root.appendingPathComponent("local/home").path,"ZDOTDIR":root.appendingPathComponent("local/home").path,"PATH":root.appendingPathComponent("local/home/bin").path+":/usr/bin:/bin:/usr/sbin:/sbin"]
        let engine=try ApprovalEngine(paths:AppPaths(directory:root.appendingPathComponent("profile")),processReader:{[]},managedPTY:ManagedPTYManager(environment:localEnv),webLoopbackOnly:false,cloudflareServices:cloudflare,nativeKeyboardActivity:.inactive)
        engine.agentAccounts=AgentAccounts(services:try AgentAccountFixture.services(root.appendingPathComponent("local")))
        try engine.start(poll:false);try await engine.setTunnelPIN("001234")
        try engine.setWebEnabled(true,port:0,bonjourEnabled:false,discoveryAddresses:{[]})
        while !engine.webStatus.ready {try await Task.sleep(for:.milliseconds(10))}
        fputs("account fixture: local ready\n",stderr)
        let peerEnv=["HOME":root.appendingPathComponent("remote/home").path,"ZDOTDIR":root.appendingPathComponent("remote/home").path,"PATH":root.appendingPathComponent("remote/home/bin").path+":/usr/bin:/bin:/usr/sbin:/sbin"]
        let peerEngine=try ApprovalEngine(paths:AppPaths(directory:root.appendingPathComponent("peer-profile")),processReader:{[]},managedPTY:ManagedPTYManager(environment:peerEnv),webLoopbackOnly:true,cloudflareServices:cloudflare,nativeKeyboardActivity:.inactive)
        peerEngine.agentAccounts=AgentAccounts(services:try AgentAccountFixture.services(root.appendingPathComponent("remote")))
        try peerEngine.start(poll:false);try await peerEngine.setTunnelPIN("001234")
        let peerName="QA Remote Mac · "+String(repeating:"다른 Mac ",count:6)
        var peerStatus=RemoteNetworkStatus()
        let peer=RemoteNetworkService(engine:peerEngine,nodeID:UUID().uuidString,name:peerName,bonjourEnabled:false,loopbackOnly:true,discoveryAddresses:{[]},onStatus:{peerStatus=$0})
        try peer.start(port:0);while !peerStatus.ready {try await Task.sleep(for:.milliseconds(10))}
        let peerBase=peerStatus.loopbackURL!
        fputs("account fixture: peer ready\n",stderr)
        let body=try JSONSerialization.data(withJSONObject:["address":peerBase])
        var packet=Data("POST /api/peers HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: http://127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8);packet.append(body)
        let added=await engine.webService!.handle(try RemoteHTTPRequest.parse(packet)!)
        guard added.status==200 else {throw AppError.message("Synthetic peer registration failed: \(added.status) \(String(decoding:added.body,as:UTF8.self))")}
        fputs("account fixture: registered\n",stderr)
        let gateway=try RemoteTunnelGateway(pin:RemoteTunnelPIN.create("001234"),handler:{[weak engine] request in
            guard let service=engine?.webService else {return .error(RemoteHTTPError(503,"Stopped"))};return await service.handle(request)
        });try gateway.setOrigin("https://account.tunnel-qa.invalid");try await gateway.start(port:0)
        let ready:JSONObject=["base":engine.webStatus.loopbackURL!,"gateway":gateway.localURL!,"node":peer.nodeID,"name":peerName,"peerBase":peerBase]
        try JSONSerialization.data(withJSONObject:ready).write(to:root.appendingPathComponent("ready.json"),options:.atomic)
        while !fm.fileExists(atPath:root.appendingPathComponent("stop").path) {try await Task.sleep(for:.milliseconds(100))}
        gateway.stop();peer.stop();peerEngine.stop();engine.stop()
    }
}
private final class AccountFixtureSecrets:@unchecked Sendable {var values:[String:Data]=[:]}
