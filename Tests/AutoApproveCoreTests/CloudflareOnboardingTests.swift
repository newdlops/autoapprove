import Foundation
import Darwin
import AutoApproveCore

extension ApprovalTests {
    private func cloudflareManager(_ fixture:CloudflareFixture)->CloudflareOnboarding {
        CloudflareOnboarding(directory:FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-cloudflare"),owner:CloudflareFixture.owner,services:fixture.services,onStatus:{_ in})
    }
    func testCloudflareApprovalFiltersAndPaginatesRegisteredDomains() async throws {
        let fixture=CloudflareFixture()
        fixture.pages=[[CloudflareFixture.domain("z.example.com"),CloudflareFixture.domain("pending.example.com",status:"pending")],
                       [CloudflareFixture.domain("a.example.com",id:CloudflareFixture.otherZone),CloudflareFixture.domain("foreign.example.com",account:String(repeating:"d",count:32)),CloudflareFixture.domain("localhost")]]
        let manager=cloudflareManager(fixture)
        try await manager.authorize(executable:"synthetic")
        try expect(manager.status.authorized);try expectEqual(manager.status.phase,"authorized")
        try expectEqual(manager.status.domains.map(\.name),["a.example.com","z.example.com"])
        try expectEqual(manager.proposedURL(for:CloudflareFixture.zone),"https://aa.z.example.com")
        try expectNil(manager.approvalURL);try expectFalse(manager.status.detail.contains(CloudflareFixture.token))
        let saved=String(decoding:fixture.secrets["cloudflare-account"]!,as:UTF8.self)
        try expectFalse(saved.contains("PRIVATE KEY"));try expectFalse(saved.contains("ARGO TUNNEL TOKEN"))
        try await manager.restore();try expectEqual(manager.status.domains.count,2)
        try expectEqual(fixture.requests.filter {$0.httpMethod != "GET"}.count,0)
    }
    func testCloudflareApprovalSelectedZoneFallbackAndPermissions() async throws {
        let fixture=CloudflareFixture();fixture.indexStatus=403
        let manager=cloudflareManager(fixture);try await manager.authorize(executable:"synthetic")
        try expectEqual(manager.status.domains.map(\.name),["example.com"])
        fixture.indexStatus=401
        do {try await manager.restore();throw CloudflareFixture.Failure()} catch is CloudflareFixture.Failure {throw CloudflareFixture.Failure()} catch {}
        try expectEqual(manager.status.phase,"failed");try expect(manager.status.domains.isEmpty)
        try expectFalse(manager.status.detail.contains(CloudflareFixture.token))
    }
    func testCloudflareApprovalRejectsMalformedAndOversizedAccountData() async throws {
        for data in [Data("bad certificate".utf8),CloudflareFixture.certificate()+CloudflareFixture.certificate(),Data(repeating:65,count:65537)] {
            let fixture=CloudflareFixture();fixture.certificateOverride=data
            let manager=cloudflareManager(fixture)
            do {try await manager.authorize(executable:"synthetic");throw CloudflareFixture.Failure()} catch is CloudflareFixture.Failure {throw CloudflareFixture.Failure()} catch {}
            try expectFalse(manager.status.authorized);try expect(fixture.secrets.isEmpty);try expect(fixture.requests.isEmpty)
        }
        let fixture=CloudflareFixture();fixture.oversized=true
        let manager=cloudflareManager(fixture)
        do {try await manager.authorize(executable:"synthetic");throw CloudflareFixture.Failure()} catch is CloudflareFixture.Failure {throw CloudflareFixture.Failure()} catch {}
        try expectEqual(manager.status.phase,"failed");try expect(manager.status.domains.isEmpty)
        try expectEqual(fixture.requests.filter {$0.httpMethod == "POST"}.count,0)
    }
    func testCloudflareProvisionPreservesDNSAndReusesOwnedResources() async throws {
        let fixture=CloudflareFixture(),manager=cloudflareManager(fixture)
        let host="aa.example.com",existing:JSONObject=["name":"aa.example.com","type":"A","content":"192.0.2.1"]
        fixture.records[host]=[existing]
        try await manager.authorize(executable:"synthetic")
        do {_ = try await manager.provision(domainID:CloudflareFixture.zone);throw CloudflareFixture.Failure()} catch is CloudflareFixture.Failure {throw CloudflareFixture.Failure()} catch {}
        try expectEqual(fixture.tunnels.count,0);try expectEqual(fixture.requests.filter {$0.httpMethod == "POST"}.count,0)
        let connection=try await manager.provision(domainID:CloudflareFixture.zone,subdomain:" a ")
        try expectEqual(connection.publicURL,"https://a.example.com")
        try expectEqual(connection.tunnelID,CloudflareFixture.tunnel)
        let again=try await manager.provision(domainID:CloudflareFixture.zone,subdomain:"A")
        try expectEqual(again.publicURL,connection.publicURL)
        try expectEqual(fixture.tunnels.count,1);try expectEqual(fixture.requests.filter {$0.httpMethod == "POST"}.count,2)
        try expectEqual(fixture.records[host]?.first?["content"] as? String,"192.0.2.1")
        let credential=try JSONSerialization.jsonObject(with:fixture.secrets["cloudflare-tunnel:"+connection.tunnelID]!) as! JSONObject
        try expectEqual(credential["AccountTag"] as? String,CloudflareFixture.account)
        try expectEqual(Data(base64Encoded:credential["TunnelSecret"] as! String)?.count,32)
        try expectNil(credential["apiToken"]);try expect(fixture.requests.allSatisfy {["GET","POST"].contains($0.httpMethod ?? "")})
    }
    func testCloudflareProvisionReconcilesLostCreateReplies() async throws {
        for tunnel in [true,false] {
            let fixture=CloudflareFixture();fixture.loseTunnelReply=tunnel;fixture.loseDNSReply = !tunnel
            var manager=cloudflareManager(fixture);try await manager.authorize(executable:"synthetic")
            do {_ = try await manager.provision(domainID:CloudflareFixture.zone);throw CloudflareFixture.Failure()} catch is CloudflareFixture.Failure {throw CloudflareFixture.Failure()} catch {}
            // A fresh manager simulates app restart after an ambiguous POST.
            manager=cloudflareManager(fixture);try await manager.restore()
            let result=try await manager.provision(domainID:CloudflareFixture.zone)
            try expectEqual(result.publicURL,"https://aa.example.com")
            try expectEqual(fixture.tunnels.count,1);try expectEqual(fixture.records.count,1)
            try expectEqual(fixture.requests.filter {$0.httpMethod == "POST"}.count,2)
        }
    }
    func testCloudflareCancellationRejectsLateApprovalAndUnknownDomain() async throws {
        let fixture=CloudflareFixture();fixture.loginDelay=200_000_000
        let manager=cloudflareManager(fixture)
        let task=Task {try await manager.authorize(executable:"synthetic")}
        try await Task.sleep(for:.milliseconds(30));manager.cancel()
        do {try await task.value;throw CloudflareFixture.Failure()} catch is CancellationError {} catch {throw error}
        try expectFalse(manager.status.authorized);try expectEqual(manager.status.phase,"idle")
        try expect(fixture.secrets.isEmpty);try expect(fixture.requests.isEmpty);try expectNil(manager.approvalURL)
        fixture.loginDelay=0;try await manager.authorize(executable:"synthetic")
        do {_ = try await manager.provision(domainID:"unregistered");throw CloudflareFixture.Failure()} catch is CloudflareFixture.Failure {throw CloudflareFixture.Failure()} catch {}
        try expectEqual(fixture.requests.filter {$0.httpMethod == "POST"}.count,0)
    }
    func testCloudflareSubdomainValidationAndLegacyAddressRecovery() throws {
        for value in ["a","AA"," term ","mac-2",String(repeating:"a",count:63)] {
            try expectEqual(try RemoteTunnelSetup.subdomain(value),value.trimmingCharacters(in:.whitespacesAndNewlines).lowercased())
        }
        for value in [""," ","-a","a-","a.b","a/b","a_b","a@b","https://a.example.com","한글","a\0b",String(repeating:"a",count:64)] {try expectThrows(try RemoteTunnelSetup.subdomain(value))}
        try expectEqual(RemoteTunnelSetup.subdomain(from:"https://autoapprove-12345678.example.com",domain:"example.com"),"autoapprove-12345678")
        try expectEqual(RemoteTunnelSetup.subdomain(from:"https://a.sub.example.com",domain:"sub.example.com"),"a")
        try expectNil(RemoteTunnelSetup.subdomain(from:"https://a.sub.example.com",domain:"example.com"))
        try expectNil(RemoteTunnelSetup.subdomain(from:"https://notexample.com",domain:"example.com"))
    }
    func testCloudflareInvalidSubdomainCannotCreateRemoteResources() async throws {
        let fixture=CloudflareFixture(),manager=cloudflareManager(fixture)
        try await manager.authorize(executable:"synthetic")
        let reads=fixture.requests.count
        for value in ["","wrong.example.com","-bad",String(repeating:"x",count:64)] {
            do {_ = try await manager.provision(domainID:CloudflareFixture.zone,subdomain:value);throw CloudflareFixture.Failure()} catch is CloudflareFixture.Failure {throw CloudflareFixture.Failure()} catch {}
            try expectNil(manager.proposedURL(for:CloudflareFixture.zone,subdomain:value))
        }
        try expectEqual(fixture.requests.count,reads);try expectEqual(fixture.tunnels.count,0)
    }
    func testCloudflareAddressChangeKeepsPriorDNSAndTunnelIdentity() async throws {
        let fixture=CloudflareFixture(),manager=cloudflareManager(fixture)
        try await manager.authorize(executable:"synthetic")
        let before=try await manager.provision(domainID:CloudflareFixture.zone,subdomain:"autoapprove-12345678")
        let after=try await manager.provision(domainID:CloudflareFixture.zone,subdomain:"term")
        try expectEqual(after.publicURL,"https://term.example.com");try expectEqual(before.tunnelID,after.tunnelID)
        try expectEqual(fixture.tunnels.count,1);try expectEqual(fixture.records.count,2)
        try expectEqual(fixture.requests.filter {$0.httpMethod == "POST"}.count,3)
        try expectEqual(fixture.records["autoapprove-12345678.example.com"]?.first?["content"] as? String,CloudflareFixture.tunnel+".cfargotunnel.com")
        try expectEqual(manager.proposedURL(for:CloudflareFixture.zone,subdomain:"TERM"),after.publicURL)
    }
    func testCloudflareLiveLoginUsesPrivateHomeAndCleansOwnedChild() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-cf-login-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer {try? FileManager.default.removeItem(at:root)}
        let tool=root.appendingPathComponent("fake-cloudflared"),observed=root.appendingPathComponent("observed")
        let payload=String(decoding:CloudflareFixture.certificate(),as:UTF8.self)
        let script="#!/bin/sh\nprintf '%s' \"$HOME\" > '"+observed.path+"'\n/bin/mkdir -p \"$HOME/.cloudflared\"\ncat > \"$HOME/.cloudflared/cert.pem\" <<'CERT'\n"+payload+"CERT\n"
        try Data(script.utf8).write(to:tool);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:tool.path)
        let data=try await CloudflareServices.live.login(tool.path,root,{_ in})
        try expectEqual(data,CloudflareFixture.certificate())
        let home=try String(contentsOf:observed,encoding:.utf8)
        try expect(home.hasPrefix(root.appendingPathComponent("cloudflare-login").path+"/"))
        try expectFalse(FileManager.default.fileExists(atPath:home))
        let pidFile=root.appendingPathComponent("pid")
        let waitScript="#!/bin/sh\nprintf '%s' \"$HOME\" > '"+observed.path+"'\nprintf '%s' \"$$\" > '"+pidFile.path+"'\nexec /bin/sleep 60\n"
        try Data(waitScript.utf8).write(to:tool)
        let task=Task {try await CloudflareServices.live.login(tool.path,root,{_ in})}
        for _ in 0..<100 where !FileManager.default.fileExists(atPath:pidFile.path) {try await Task.sleep(for:.milliseconds(10))}
        let pid=try Int32(String(contentsOf:pidFile,encoding:.utf8))!
        task.cancel()
        do {_ = try await task.value;throw CloudflareFixture.Failure()} catch is CancellationError {} catch {throw error}
        try expectEqual(kill(pid,0),-1)
        let cancelledHome=try String(contentsOf:observed,encoding:.utf8)
        try expectFalse(FileManager.default.fileExists(atPath:cancelledHome))
    }
}
