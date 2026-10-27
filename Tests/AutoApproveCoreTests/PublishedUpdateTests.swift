import Foundation
import AutoApproveCore

private actor PublishedRequestProbe {
    var ranges:[String]=[]
    var calls=0
    var failed=false
    func call()->Int {calls+=1;return calls}
    func range(_ value:String)->Bool {ranges.append(value);if value.hasPrefix("bytes=262144-"),!failed {failed=true;return true};return false}
    func snapshot()->(Int,[String]) {(calls,ranges)}
}

extension ApprovalTests {
    func testPortManagerLoopbackCoordinatesStayInsideDeclaredNamespace() throws {
        let global=["PORT_MANAGER_ACTUAL_LOOPBACK_HOST":"127.1.0.1","PORT_MANAGER_NETWORK_IS_GLOBAL":"1","PORT_MANAGER_HOOK":"1"]
        try expectEqual(RemoteLoopback.host(requestedPort:8789,environment:global),"127.1.0.1")
        try expectEqual(RemoteLoopback.host(requestedPort:0,environment:global),"127.0.0.1")
        var scoped=global;scoped["PORT_MANAGER_NETWORK_IS_GLOBAL"]="0";scoped["PORT_MANAGER_ACTUAL_LOOPBACK_HOST"]="127.92.3.1"
        try expectEqual(RemoteLoopback.host(requestedPort:0,environment:scoped),"127.92.3.1")
        scoped["PORT_MANAGER_PRESERVE_LISTEN_PORTS"]="5037, 5038";try expectEqual(RemoteLoopback.host(requestedPort:5037,environment:scoped),"127.0.0.1")
        scoped["PORT_MANAGER_HOOK_DISABLED"]="1";try expectEqual(RemoteLoopback.host(requestedPort:8789,environment:scoped),"127.0.0.1")
        for invalid in ["0.0.0.0","192.168.1.1","127.1.0.1:8789","127.01.0.1","localhost","127.1.0.1\n"] {
            try expectNil(RemoteLoopback.portManagerHost(environment:["PORT_MANAGER_ACTUAL_LOOPBACK_HOST":invalid]))
        }
    }
    func testExplicitLoopbackPortsSurviveListenerReuse() async throws {
        let first=try RemoteTunnelGateway(handler:{_ in RemoteHTTPResponse(body:Data(),contentType:"text/plain")})
        try await first.start(port:0);let port=first.port!;first.stop();try await Task.sleep(for:.milliseconds(100))
        let gateway=try RemoteTunnelGateway(handler:{_ in RemoteHTTPResponse(body:Data(),contentType:"text/plain")})
        defer {gateway.stop()};try gateway.setOrigin("https://loopback.tunnel-qa.invalid");try await gateway.start(port:port)
        try expectEqual(URL(string:gateway.localURL!)?.host,RemoteLoopback.host(requestedPort:port))
        var request=URLRequest(url:URL(string:gateway.localURL!+"/auth/probe")!);request.timeoutInterval=3
        let (_,response)=try await URLSession.shared.data(for:request)
        try expectEqual((response as? HTTPURLResponse)?.statusCode,200)
        request.setValue("foreign.invalid",forHTTPHeaderField:"Host")
        let (_,foreign)=try await URLSession.shared.data(for:request)
        try expectEqual((foreign as? HTTPURLResponse)?.statusCode,403)
        request.setValue(nil,forHTTPHeaderField:"Host")
        gateway.stop();try await Task.sleep(for:.milliseconds(100))
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-explicit-port-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let engine=try ApprovalEngine(paths:AppPaths(directory:root),processReader:{[]},webLoopbackOnly:true)
        defer {engine.stop()};try engine.setWebEnabled(true,port:port,bonjourEnabled:false)
        for _ in 0..<100 where !engine.webStatus.ready {try await Task.sleep(for:.milliseconds(20))}
        try expect(engine.webStatus.ready);try expectEqual(engine.webStatus.port,port)
        request.url=URL(string:engine.webStatus.loopbackURL!+"/api/discovery")!
        let (_,web)=try await URLSession.shared.data(for:request)
        try expectEqual((web as? HTTPURLResponse)?.statusCode,200)
    }
    private func publishedRecord(_ data:Data=Data(repeating:7,count:600000))->JSONObject {
        let name="AutoApprove-0.2.999-build1000-macOS-\(LANUpdateManifest.architecture).zip"
        return ["tag_name":"v0.2.999","draft":false,"prerelease":false,"assets":[[
            "name":name,"size":data.count,"digest":"sha256:"+LANUpdateInstallation.digest(data),
            "browser_download_url":"https://github.com/newdlops/autoapprove/releases/download/v0.2.999/"+name]]]
    }
    func testPublishedUpdateOnlyAcceptsExactStablePublisherAsset() throws {
        let original=publishedRecord(),data=try JSONSerialization.data(withJSONObject:original)
        let offer=try PublishedReleaseRecord.decode(data).offer
        try expectEqual(offer?.manifest.release,RemoteWebVersion(version:"0.2.999",build:1000))
        try expectEqual(offer?.manifest.nodeID,PublishedReleaseOffer.sourceID)
        var invalid:[JSONObject]=[]
        for key in ["draft","prerelease"] {var value=original;value[key]=true;invalid.append(value)}
        var value=original;value["tag_name"]="v00.2.999";invalid.append(value)
        for (key,bad) in [("size",0 as Any),("size",LANUpdateManifest.maximumSize+1 as Any),("digest","sha256:wrong" as Any),("browser_download_url","https://attacker.invalid/update.zip" as Any),("name","AutoApprove-0.2.999-build01000-macOS-\(LANUpdateManifest.architecture).zip" as Any)] {
            var asset=(original["assets"] as! [JSONObject])[0];asset[key]=bad;value=original;value["assets"]=[asset];invalid.append(value)
        }
        value=original;value["assets"]=(original["assets"] as! [JSONObject])+(original["assets"] as! [JSONObject]);invalid.append(value)
        for item in invalid {
            do {_ = try PublishedReleaseRecord.decode(JSONSerialization.data(withJSONObject:item));throw AppError.message("Untrusted update accepted")}
            catch {try expect(error.localizedDescription != "Untrusted update accepted")}
        }
        value=original;value["assets"]=[];try expectNil(PublishedReleaseRecord.decode(JSONSerialization.data(withJSONObject:value)).offer)
        var asset=(original["assets"] as! [JSONObject])[0];asset["name"]="AutoApprove-0.2.999-build1000-macOS-other.zip";value=original;value["assets"]=[asset]
        try expectNil(PublishedReleaseRecord.decode(JSONSerialization.data(withJSONObject:value)).offer)
    }
    func testPublishedUpdateChecksCoalesceCacheAndCancel() async throws {
        let body=try JSONSerialization.data(withJSONObject:publishedRecord()),probe=PublishedRequestProbe()
        let lookup=PublishedUpdates(services:PublishedUpdateServices {request,limit in
            try expectEqual(request.url?.absoluteString,"https://api.github.com/repos/newdlops/autoapprove/releases/latest")
            try expectEqual(limit,2000000);_ = await probe.call();try await Task.sleep(for:.milliseconds(50))
            return PublishedUpdateReply(status:200,body:body)
        })
        await withTaskGroup(of:Void.self) {group in for _ in 0..<12 {group.addTask {await lookup.check()}}}
        try expectEqual(lookup.status.phase,"ready");try expectEqual(lookup.status.latest?.build,1000)
        await lookup.check();let count=await probe.snapshot();try expectEqual(count.0,1)
        let pending=PublishedUpdates(services:PublishedUpdateServices {_,_ in try await Task.sleep(for:.seconds(5));return PublishedUpdateReply(status:200,body:body)})
        let task=Task {await pending.check()};try await Task.sleep(for:.milliseconds(10));pending.stop();await task.value
        try expectEqual(pending.status.phase,"idle");try expectNil(pending.record)
        let failed=PublishedUpdates(services:PublishedUpdateServices {_,_ in throw AppError.message("private upstream details")})
        await failed.check();try expectEqual(failed.status.phase,"failed");try expectFalse(failed.status.detail.contains("private"))
    }
    func testPublishedUpdateRangesResumeAndRejectWrongBoundaries() async throws {
        let bytes=Data(repeating:7,count:600000),probe=PublishedRequestProbe()
        let offer=try PublishedReleaseRecord.decode(JSONSerialization.data(withJSONObject:publishedRecord(bytes))).offer!
        let lookup=PublishedUpdates(services:PublishedUpdateServices {request,limit in
            let range=request.value(forHTTPHeaderField:"Range")!;let fail=await probe.range(range)
            if fail {throw RemoteHTTPError(503,"Synthetic dropped range")}
            let parts=range.dropFirst(6).split(separator:"-").map {Int($0)!},a=parts[0],b=parts[1]
            try expectEqual(limit,b-a+1);try expectEqual(request.value(forHTTPHeaderField:"Accept-Encoding"),"identity")
            return PublishedUpdateReply(status:206,body:Data(bytes[a...b]),contentRange:"bytes \(a)-\(b)/\(bytes.count)")
        })
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-published-resume-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        do {_ = try await LANUpdateDownload.download(manifest:offer.manifest,directory:root,read:{try await lookup.read($0,offer:offer)});throw AppError.message("Drop ignored")}
        catch {try expect(error.localizedDescription != "Drop ignored")}
        let result=try await LANUpdateDownload.download(manifest:offer.manifest,directory:root,read:{try await lookup.read($0,offer:offer)})
        try expectEqual(Data(contentsOf:result),bytes)
        let history=await probe.snapshot();try expectEqual(history.1.filter {$0.hasPrefix("bytes=0-")}.count,1)
        try expectEqual(history.1.filter {$0.hasPrefix("bytes=262144-")}.count,2)
        let wrong=PublishedUpdates(services:PublishedUpdateServices {_,limit in PublishedUpdateReply(status:206,body:Data(repeating:7,count:limit),contentRange:"bytes 1-262144/600000")})
        do {_ = try await wrong.read("/api/update/chunk?sha256=\(offer.manifest.sha256)&offset=0",offer:offer);throw AppError.message("Wrong range accepted")}
        catch {try expect(error.localizedDescription != "Wrong range accepted")}
    }
    func testPublishedVersionControlChecksMetadataWithoutInstalling() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-version-control-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let body=try JSONSerialization.data(withJSONObject:publishedRecord())
        let engine=try ApprovalEngine(paths:AppPaths(directory:root),processReader:{[]},webLoopbackOnly:true,publishedUpdateServices:PublishedUpdateServices {_,_ in PublishedUpdateReply(status:200,body:body)})
        try engine.setWebEnabled(true,port:0,bonjourEnabled:false);defer {engine.stop()}
        let service=engine.webService!
        func request(_ method:String,_ path:String,origin:String="http://127.0.0.1") throws -> RemoteHTTPRequest {
            let body=method=="POST" ? "{}":""
            return try RemoteHTTPRequest.parse(Data("\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: \(origin)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8))!
        }
        let checked=await service.handle(try request("POST","/api/version/check"))
        try expectEqual(checked.status,200)
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let state=try decoder.decode(PublishedUpdateStatus.self,from:checked.body)
        try expectEqual(state.latest?.version,"0.2.999");try expectFalse(state.canSync)
        try expectEqual(engine.lanUpdate.phase,"idle")
        let foreign=await service.handle(try request("POST","/api/version/check",origin:"https://foreign.invalid"))
        try expectEqual(foreign.status,403)
        let wrongNode=await service.handle(try request("GET","/api/version?node="+UUID().uuidString))
        try expectEqual(wrongNode.status,400)
        try engine.setLANUpdateEnabled(false)
        let sync=await service.handle(try request("POST","/api/version/sync"))
        try expectEqual(sync.status,409);try expectEqual(engine.lanUpdate.phase,"off")
    }
}
