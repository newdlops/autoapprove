import Foundation
import AutoApproveCore
import AppKit
import Darwin

/// Signed private fixture only. No Bonjour, subnet scan, real account or user process.
@main struct PublishedUpdateManagerFixture {
    nonisolated static func config(_ file:URL)->JSONObject {(try? JSONSerialization.jsonObject(with:Data(contentsOf:file))) as? JSONObject ?? [:]}
    @MainActor static func main() throws {
        let app=URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root=app.deletingLastPathComponent(),file=root.appendingPathComponent("fixture-config.json"),settings=config(file)
        if FileManager.default.fileExists(atPath:root.appendingPathComponent("qa-stop").path) {exit(0)}
        guard let home=settings["home"] as? String else {throw AppError.message("Missing isolated profile")}
        let directory=URL(fileURLWithPath:home)
        var power=PowerControl.live;power.read={PowerReading(lidClosed:config(file)["lidClosed"] as? Bool ?? false)}
        var secrets=CloudflareServices.live
        secrets.readSecret={dir,name in try? Data(contentsOf:dir.appendingPathComponent("qa-secret-"+name))}
        secrets.saveSecret={dir,name,data in try data.write(to:dir.appendingPathComponent("qa-secret-"+name),options:.atomic)}
        let published=PublishedUpdateServices {request,_ in
            let current=config(file)
            if request.url?.host=="api.github.com",let metadata=current["metadata"] as? String {return PublishedUpdateReply(status:200,body:try Data(contentsOf:URL(fileURLWithPath:metadata)))}
            guard let archive=current["archive"] as? String,let range=request.value(forHTTPHeaderField:"Range") else {throw AppError.message("Unexpected isolated request")}
            let pieces=range.dropFirst(6).split(separator:"-").compactMap {Int($0)};guard pieces.count==2 else {throw AppError.message("Invalid range")}
            let offset=pieces[0],end=pieces[1]
            let attempts=root.appendingPathComponent("qa-ranges.log")
            if !FileManager.default.fileExists(atPath:attempts.path){FileManager.default.createFile(atPath:attempts.path,contents:Data())}
            let log=try FileHandle(forWritingTo:attempts);try log.seekToEnd();try log.write(contentsOf:Data((range+"\n").utf8));try log.close()
            if current["dropChunk"] as? Bool==true,offset==LANUpdateManifest.chunkSize,!FileManager.default.fileExists(atPath:root.appendingPathComponent("qa-dropped").path) {
                try Data().write(to:root.appendingPathComponent("qa-dropped"));throw RemoteHTTPError(503,"Synthetic transfer interruption")
            }
            let bytes=try Data(contentsOf:URL(fileURLWithPath:archive),options:.mappedIfSafe)
            guard offset>=0,end<bytes.count else {throw AppError.message("Invalid range bounds")}
            return PublishedUpdateReply(status:206,body:Data(bytes[offset...end]),contentRange:"bytes \(offset)-\(end)/\(bytes.count)")
        }
        let engine=try ApprovalEngine(paths:AppPaths(directory:directory),processReader:{[]},powerControl:power,webLoopbackOnly:true,cloudflareServices:secrets,publishedUpdateServices:published)
        engine.finishLANUpdate={engine.stop();exit(0)}
        if let enabled=settings["enabled"] as? Bool {try engine.setLANUpdateEnabled(enabled)}
        try engine.loadTunnelPIN();try engine.start(poll:false)
        if engine.webService==nil {try engine.setWebEnabled(true,port:0,bonjourEnabled:false,discoveryAddresses:{[]})}
        try Data(String(getpid()).utf8).write(to:root.appendingPathComponent("fixture-pid"),options:.atomic)
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            if !engine.tunnelPINConfigured {try? await engine.setTunnelPIN("001234")}
            if !engine.hasTunnelConfiguration,let port=settings["tunnelPort"] as? Int {
                var tunnel=RemoteTunnelConfiguration();tunnel.provider = .external;tunnel.publicURL="https://version-sync.tunnel-qa.invalid";tunnel.port=UInt16(port)
                try? await engine.startTunnel(tunnel)
            }
            for _ in 0..<1800 {
                if FileManager.default.fileExists(atPath:root.appendingPathComponent("qa-stop").path) {engine.stop();exit(0)}
                var value:JSONObject=["port":Int(engine.webStatus.port ?? 0),"update":engine.lanUpdate.phase,"tunnelPhase":engine.tunnelStatus.phase,"pin":engine.tunnelPINConfigured]
                if let local=engine.webStatus.loopbackURL {value["loopbackURL"]=local}
                if let local=engine.tunnelStatus.localURL {value["gateway"]=local}
                if let release=RemoteWebVersion.current {value["release"]=try? JSONSerialization.jsonObject(with:JSONEncoder().encode(release))}
                try? JSONSerialization.data(withJSONObject:value).write(to:root.appendingPathComponent("fixture-state.json"),options:.atomic)
                try? await Task.sleep(for:.milliseconds(100))
            }
        }
        withExtendedLifetime(engine) {NSApplication.shared.run()}
    }
}
