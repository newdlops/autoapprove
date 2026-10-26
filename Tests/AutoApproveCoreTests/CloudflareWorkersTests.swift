import Foundation
import Darwin
import AutoApproveCore

extension ApprovalTests {
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
