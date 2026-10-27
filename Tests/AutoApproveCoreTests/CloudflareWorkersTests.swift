import Foundation
import Darwin
import AutoApproveCore

extension ApprovalTests {
    func testWorkersSlowManagementCannotHoldExistingRelayConnection() async throws {
        let root = URL(fileURLWithPath:"/private/tmp/aa-wmb-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let fixture = WorkersFixture(),manager = fixture.manager();try await manager.authorize()
        let origin = try await manager.provision(domainID:CloudflareFixture.zone,subdomain:"cp")
        fixture.secrets.removeValue(forKey:fixture.secrets.keys.first(where:{$0.hasPrefix("cloudflare-worker-source:")})!)
        let originalHTTP = fixture.http
        let slowHTTP = CloudflareServices(exchange:{request in
            try await Task.sleep(for:.seconds(10));return try await originalHTTP.exchange(request)
        },login:originalHTTP.login,readSecret:originalHTTP.readSecret,saveSecret:originalHTTP.saveSecret)
        let uploads = fixture.uploads,domains = fixture.domains,credential = fixture.secrets["cloudflare-worker"]
        let paths = AppPaths(directory:root);try paths.prepare();let store = try AuditStore(path:paths.database);try store.set("cloudflareOwner",CloudflareFixture.owner)
        let relay = CloudflareRelayServices(connect:{_ in
            fixture.locked {fixture.conflict = true};let session = URLSession(configuration:.ephemeral)
            return CloudflareRelaySocket(session:session,task:session.webSocketTask(with:URL(string:"ws://127.0.0.1:9")!))
        },probe:{_ in CloudflareHTTPReply(data:Data(),status:503)})
        let engine = try ApprovalEngine(paths:paths,processReader:{[]},webLoopbackOnly:true,cloudflareServices:slowHTTP,workersServices:fixture.tools,relayServices:relay)
        defer {engine.stop()};try engine.start(poll:false);try engine.setWebEnabled(true)
        for _ in 0..<200 where !engine.webStatus.ready {try await Task.sleep(for:.milliseconds(10))}
        var config = RemoteTunnelConfiguration();config.provider = .https;config.publicURL = origin
        let start = ProcessInfo.processInfo.systemUptime;try await engine.connectTunnel(config)
        for _ in 0..<100 where !fixture.locked({fixture.conflict}) {try await Task.sleep(for:.milliseconds(5))}
        try expect(fixture.locked {fixture.conflict},"The existing data connection starts even while the management API stalls")
        try expect(ProcessInfo.processInfo.systemUptime-start < 4.5,"Management refresh has a three-second startup budget")
        try expect(engine.tunnelStatus.active);try expectNotNil(engine.tunnelAccessKey)
        try engine.stopTunnel();try await Task.sleep(for:.milliseconds(20))
        try expectFalse(engine.tunnelStatus.active);try expectFalse(engine.tunnelConfiguration.enabled)
        try expectEqual(fixture.uploads,uploads);try expectEqual(fixture.domains,domains);try expectEqual(fixture.secrets["cloudflare-worker"],credential)
    }
    func testWorkersRefreshCancellationCannotRestartStoppedTunnel() async throws {
        let root = URL(fileURLWithPath:"/private/tmp/aa-wrc-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let fixture = WorkersFixture(),manager = fixture.manager();try await manager.authorize()
        let origin = try await manager.provision(domainID:CloudflareFixture.zone,subdomain:"cp")
        let marker = fixture.secrets.keys.first(where:{$0.hasPrefix("cloudflare-worker-source:")})!
        fixture.secrets.removeValue(forKey:marker);fixture.delay = 200_000_000
        let paths = AppPaths(directory:root);try paths.prepare();let store = try AuditStore(path:paths.database);try store.set("cloudflareOwner",CloudflareFixture.owner)
        let connects = fixture.locked {fixture.authCalls}
        let relay = CloudflareRelayServices(connect:{_ in
            fixture.locked {fixture.conflict = true}
            let session = URLSession(configuration:.ephemeral)
            return CloudflareRelaySocket(session:session,task:session.webSocketTask(with:URL(string:"ws://127.0.0.1:9")!))
        },probe:{_ in CloudflareHTTPReply(data:Data(),status:503)})
        let engine = try ApprovalEngine(paths:paths,processReader:{[]},webLoopbackOnly:true,cloudflareServices:fixture.http,workersServices:fixture.tools,relayServices:relay)
        defer {engine.stop()};try engine.start(poll:false);try engine.setWebEnabled(true)
        for _ in 0..<200 where !engine.webStatus.ready {try await Task.sleep(for:.milliseconds(10))}
        try expect(engine.webStatus.ready)
        var config = RemoteTunnelConfiguration();config.provider = .https;config.publicURL = origin
        let task = Task {try await engine.connectTunnel(config)}
        for _ in 0..<100 where fixture.locked({fixture.authCalls}) == connects {try await Task.sleep(for:.milliseconds(5))}
        try expect(fixture.locked {fixture.authCalls} > connects);try engine.stopTunnel()
        do {try await task.value;throw CloudflareFixture.Failure()} catch is CancellationError {} catch {throw error}
        try expectFalse(engine.tunnelStatus.active);try expectFalse(engine.tunnelConfiguration.enabled);try expectFalse(fixture.conflict)
    }
    func testWorkersSourceRefreshPreservesDNSAndRejectsForeignBindings() async throws {
        let fixture = WorkersFixture(),manager = fixture.manager();try await manager.authorize()
        let origin = try await manager.provision(domainID:CloudflareFixture.zone,subdomain:"cp")
        let before = fixture.requests.count
        try expectFalse(try await manager.refreshRelayIfNeeded(origin:origin));try expectEqual(fixture.requests.count,before)
        let marker = fixture.secrets.keys.first(where:{$0.hasPrefix("cloudflare-worker-source:")})!
        fixture.secrets.removeValue(forKey:marker)
        let domains = fixture.domains,uploads = fixture.uploads,credentials = fixture.secrets["cloudflare-worker"]
        try expect(try await manager.refreshRelayIfNeeded(origin:origin))
        try expectEqual(fixture.domains,domains);try expectEqual(fixture.uploads,uploads+1)
        try expectNil(fixture.metadata.last?["migrations"]);try expectEqual(fixture.secrets["cloudflare-worker"],credentials)
        let writes = fixture.requests.dropFirst(before).filter {$0.httpMethod != "GET"}
        try expectEqual(writes.count,1);try expectEqual(writes.first?.httpMethod,"PUT")
        fixture.secrets.removeValue(forKey:marker);fixture.bindings?.append(["type":"plain_text","name":"FOREIGN_SETTING","text":"preserve"])
        do {_ = try await manager.refreshRelayIfNeeded(origin:origin);throw CloudflareFixture.Failure()} catch is CloudflareFixture.Failure {throw CloudflareFixture.Failure()} catch {}
        try expectEqual(fixture.uploads,uploads+1);try expectEqual(fixture.domains,domains)
    }
    func testWorkersApprovalProvisionAndUncertainUpload() async throws {
        let fixture=WorkersFixture();var manager=fixture.manager()
        try await manager.restore();try expectFalse(manager.status.authorized);try expectEqual(fixture.authCalls,0)
        try await manager.authorize();try expectEqual(manager.status.domains.map(\.name),["example.com"])
        try expectEqual(manager.proposedURL(for:CloudflareFixture.zone,subdomain:" CP "),"https://cp.example.com")
        fixture.loseUpload=true
        do {_ = try await manager.provision(domainID:CloudflareFixture.zone,subdomain:"cp");throw CloudflareFixture.Failure()} catch is CloudflareFixture.Failure {throw CloudflareFixture.Failure()} catch {}
        try expectEqual(fixture.uploads,1);try expectEqual(fixture.domains,0)
        manager=fixture.manager();try await manager.restore()
        let address=try await manager.provision(domainID:CloudflareFixture.zone,subdomain:"cp")
        try expectEqual(address,"https://cp.example.com");try expectEqual(fixture.uploads,2);try expectEqual(fixture.domains,1)
        try expect(fixture.metadata[0]["migrations"] != nil);try expectNil(fixture.metadata[1]["migrations"])
        let credential=try JSONDecoder().decode(CloudflareRelayCredential.self,from:fixture.secrets["cloudflare-worker"]!)
        _ = try credential.validated(for:address);try expectThrows(try credential.validated(for:"https://other.example.com"))
        try expectFalse(manager.status.detail.contains(CloudflareFixture.token))
        _ = try await manager.provision(domainID:CloudflareFixture.zone,subdomain:"a")
        try expectEqual(fixture.records.compactMap {$0["hostname"] as? String}.sorted(),["a.example.com","cp.example.com"])
    }
    func testWorkersForeignResourcesAndInvalidNamesArePreserved() async throws {
        let fixture=WorkersFixture(),manager=fixture.manager();try await manager.authorize()
        let before=fixture.requests.count
        for name in ["","wrong.example.com","-bad"] {
            do {_ = try await manager.provision(domainID:CloudflareFixture.zone,subdomain:name);throw CloudflareFixture.Failure()} catch is CloudflareFixture.Failure {throw CloudflareFixture.Failure()} catch {}
        }
        try expectEqual(fixture.requests.count,before)
        _ = try await manager.provision(domainID:CloudflareFixture.zone,subdomain:"cp")
        for foreign in [false,true] {
            fixture.conflict = !foreign;fixture.foreign=foreign
            do {_ = try await manager.provision(domainID:CloudflareFixture.zone,subdomain:"taken");throw CloudflareFixture.Failure()} catch is CloudflareFixture.Failure {throw CloudflareFixture.Failure()} catch {}
            try expectEqual(fixture.uploads,1);try expectEqual(fixture.domains,1)
        }
        fixture.bindings=[["name":"AUTOAPPROVE_OWNER","text":"foreign"]]
        do {_ = try await manager.provision(domainID:CloudflareFixture.zone,subdomain:"cp");throw CloudflareFixture.Failure()} catch is CloudflareFixture.Failure {throw CloudflareFixture.Failure()} catch {}
        try expectEqual(fixture.uploads,1)
    }
    func testWorkersCancelledAuthorizationAndSanitizedPermissionError() async throws {
        let fixture=WorkersFixture(),manager=fixture.manager();fixture.delay=200_000_000
        let task=Task {try await manager.authorize()};try await Task.sleep(for:.milliseconds(20));manager.cancel()
        do {try await task.value;throw CloudflareFixture.Failure()} catch is CancellationError {} catch {throw error}
        try expect(fixture.secrets.isEmpty);try expect(fixture.requests.isEmpty)
        fixture.delay=0;fixture.indexStatus=403
        do {try await manager.authorize();throw CloudflareFixture.Failure()} catch is CloudflareFixture.Failure {throw CloudflareFixture.Failure()} catch {}
        try expectEqual(manager.status.phase,"failed");try expectFalse(manager.status.detail.contains(CloudflareFixture.token))
    }
    func testRelayBinaryFramingBoundsAndLoopbackIsolation() throws {
        let data=try CloudflareRelayPacket(kind:.credit,id:0x01020304,payload:Data([0,4,0,0])).encoded()
        try expectEqual(data,Data([65,65,1,6,1,2,3,4,0,4,0,0]));try expectEqual(try CloudflareRelayPacket.decode(data).credit(),262144)
        for bad in [Data(),Data([65,65,2,0,0,0,0,0]),Data([65,65,1,1,0,0,0,0]),Data([65,65,1,0,0,0,0,1]),Data(repeating:0,count:CloudflareRelayPacket.maximumSize+1)] {try expectThrows(try CloudflareRelayPacket.decode(bad))}
        for path in ["//evil.invalid/","http://evil.invalid/","/\\evil","/bad\r\nheader","/fragment#bad"] {
            let payload=try CloudflareRelayPacket.requestPayload(method:"POST",path:path,headers:[:])
            try expectThrows(try CloudflareRelayPacket(kind:.request,id:1,payload:payload).request())
        }
        let body=Data("한글😀\u{1B}[D".utf8),payload=try CloudflareRelayPacket.requestPayload(method:"POST",path:"/api/input",headers:["Origin":"https://a.example.com"],body:body)
        try expectEqual(try CloudflareRelayPacket(kind:.request,id:1,payload:payload).request().body,body)
        for bytes in [Data([0,0,0,0]),Data([0,4,0,1])] {try expectThrows(try CloudflareRelayPacket(kind:.credit,id:1,payload:bytes).credit())}
    }
    func testOwnedWorkerToolCancellationPreservesUnrelatedProcess() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-owned-worker-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let unrelated=Process();unrelated.executableURL=URL(fileURLWithPath:"/bin/sleep");unrelated.arguments=["60"];try unrelated.run();defer{unrelated.terminate();unrelated.waitUntilExit()}
        let result=try await OwnedToolProcess.run("/bin/sh",arguments:["-c","printf 'output'; printf 'error' >&2"],environment:["PATH":"/usr/bin:/bin"],directory:root)
        try expectEqual(String(decoding:result.output,as:UTF8.self),"output");try expectEqual(String(decoding:result.error,as:UTF8.self),"error")
        let task=Task {try await OwnedToolProcess.run("/bin/sh",arguments:["-c","echo $$ > leader; /bin/sleep 60 & echo $! > child; wait"],environment:["PATH":"/usr/bin:/bin"],directory:root)}
        for _ in 0..<100 where !FileManager.default.fileExists(atPath:root.appendingPathComponent("child").path) {try await Task.sleep(for:.milliseconds(10))}
        let leader=Int32(try String(contentsOf:root.appendingPathComponent("leader"),encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines))!
        let child=Int32(try String(contentsOf:root.appendingPathComponent("child"),encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines))!
        task.cancel();do {_ = try await task.value;throw CloudflareFixture.Failure()} catch is CancellationError {} catch {throw error}
        try expectEqual(kill(leader,0),-1)
        for _ in 0..<100 where kill(child,0)==0 {try await Task.sleep(for:.milliseconds(10))}
        try expectEqual(kill(child,0),-1);try expect(unrelated.isRunning)
    }
}
