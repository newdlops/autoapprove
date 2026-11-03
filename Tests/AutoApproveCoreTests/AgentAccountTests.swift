import Foundation
import CryptoKit
import AutoApproveCore

private struct AccountTestClient {
    let node=UUID().uuidString,hello:JSONObject
    let secret=Curve25519.KeyAgreement.PrivateKey()
    @MainActor init(_ accounts:AgentAccounts,pin:RemoteTunnelPIN?) {hello=accounts.hello(node:node,pin:pin)}
    func packet(_ value:JSONObject,age:TimeInterval=0) throws -> (JSONObject,SymmetricKey,Data) {
        let id=UUID().uuidString,aad=Data("AutoApprove accounts v1:\(node):\(hello["keyID"]!):\(id)".utf8)
        let shared=try secret.sharedSecretFromKeyAgreement(with:Curve25519.KeyAgreement.PublicKey(rawRepresentation:Data(base64Encoded:hello["publicKey"] as! String)!))
        let key=shared.hkdfDerivedSymmetricKey(using:SHA256.self,salt:Data(),sharedInfo:aad,outputByteCount:32)
        var object=value;object["time"]=(Date().timeIntervalSince1970-age)*1000
        let payload=try ChaChaPoly.seal(JSONSerialization.data(withJSONObject:object),using:key,authenticating:aad)
        return (["version":1,"keyID":hello["keyID"]!,"request":id,"publicKey":secret.publicKey.rawRepresentation.base64EncodedString(),"payload":payload.combined.base64EncodedString()],key,aad)
    }
    func read(_ response:JSONObject,key:SymmetricKey,aad:Data) throws -> JSONObject {
        let data=try ChaChaPoly.open(ChaChaPoly.SealedBox(combined:Data(base64Encoded:response["payload"] as! String)!),using:key,authenticating:aad+Data(".reply".utf8))
        return try JSONSerialization.jsonObject(with:data) as! JSONObject
    }
    @MainActor func call(_ accounts:AgentAccounts,pin:RemoteTunnelPIN?,_ value:JSONObject,age:TimeInterval=0) async throws -> JSONObject {
        let (envelope,key,aad)=try packet(value,age:age)
        return try read(await accounts.encrypted(envelope,node:node,pin:pin),key:key,aad:aad)
    }
}

private let nativeCodexBrowserURL="https://auth.openai.com/oauth/authorize?response_type=code&client_id=app_EMoamEEZ73f0CkXaXp7hrann&redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback&code_challenge="+String(repeating:"A",count:43)+"&code_challenge_method=S256&state=synthetic-private-state-12345"

extension ApprovalTests {
    func testCodexConnectedServerAccountIdentityIsLiteralAndModeSpecific() throws {
        let chat=try CodexServerAccountIdentity.decode(["account":["type":"chatgpt","email":"session@example.test","planType":"pro"]])
        try expectEqual(chat.email,"session@example.test");try expectEqual(chat.plan,"pro");try expect(chat.authenticated)
        let missing=try CodexServerAccountIdentity.decode(["account":["type":"chatgpt","email":NSNull(),"planType":NSNull()]])
        try expectEqual(missing.email,nil);try expect(missing.authenticated)
        let api=try CodexServerAccountIdentity.decode(["account":["type":"apiKey","email":"must-not-display@example.test"]])
        try expectEqual(api.email,nil);try expectEqual(api.provider,"API 키")
        let absent=try CodexServerAccountIdentity.decode(["account":NSNull()])
        try expectFalse(absent.authenticated);try expectEqual(absent.email,nil)
        var rejected=false
        do {_=try CodexServerAccountIdentity.decode(["account":["type":"chatgpt","email":"one\ntwo@example.test"]])} catch {rejected=true}
        try expect(rejected,"Malformed account labels must not become session identity")
    }
    func testNativeCodexBrowserURLScopeAndRemoteDeviceIsolation() throws {
        let parsed=AgentAccountOutput.challenge(nativeCodexBrowserURL,agent:"codex-browser")
        try expectEqual(parsed.url,nativeCodexBrowserURL);try expectNil(parsed.code)
        try expectNil(AgentAccountOutput.challenge(nativeCodexBrowserURL,agent:"codex").url)
        try expectNil(AgentAccountOutput.challenge("https://auth.openai.com/codex/device\nABCD-1234",agent:"codex-browser").url)
        for invalid in [nativeCodexBrowserURL+"&state=duplicate",nativeCodexBrowserURL.replacingOccurrences(of:"app_EMoamEEZ73f0CkXaXp7hrann",with:"foreign-client"),nativeCodexBrowserURL.replacingOccurrences(of:"127.0.0.1",with:"evil.invalid"),nativeCodexBrowserURL.replacingOccurrences(of:"auth.openai.com/",with:"auth.openai.com.evil.invalid/"),nativeCodexBrowserURL.replacingOccurrences(of:"S256",with:"plain"),nativeCodexBrowserURL+"#fragment"] {
            try expectFalse(AgentAccountOutput.validURL(invalid,agent:"codex-browser"))
        }
    }
    func testNativeCodexLoginLiteralExecutableAndHome() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-scope-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let cli=root.appendingPathComponent("codex ; literal"),home=root.appendingPathComponent("home $(literal) ; space").path
        let script="#!/bin/zsh -f\nif [[ $1 == login && $2 == status ]]; then print 'Logged in using ChatGPT'; exit 0; fi\n[[ $1 == login && -z $2 && -z $SSH_CONNECTION && -z $SSH_CLIENT && -z $SSH_TTY && -z $BROWSER ]] || exit 44\nprint -r -- \"$CODEX_HOME\" > \"$0.home\"\nprint '\(nativeCodexBrowserURL)'\nexit 0\n"
        try Data(script.utf8).write(to:cli);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:cli.path)
        let accounts=AgentAccounts();defer{accounts.stop()}
        try accounts.beginNativeCodexLogin(.init(home:home,executable:cli.path))
        let deadline=ContinuousClock.now.advanced(by:.seconds(10))
        while accounts.nativeCodexLogin?.phase != "succeeded",ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(30))}
        try expectEqual(accounts.nativeCodexLogin?.phase,"succeeded")
        try expectEqual(try String(contentsOfFile:cli.path+".home",encoding:.utf8),home+"\n")
        try expectNil(accounts.nativeCodexLogin?.code);try expectNil(accounts.nativeCodexLogin?.url)
    }
    func testNativeCodexLoginSharedOwnershipAndScopedHome() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-native-login-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let target=CodexAccountTransitionTarget(home:root.appendingPathComponent("home with spaces;literal").path,executable:"/fixture/codex")
        let services=AgentAccountServices(home:root.path,check:{agent in .init(agent:agent,phase:"authenticated")},launch:{_ in
            try ManagedPTY(cwd:root.path,command:["/bin/zsh","-f","-c","print '\(nativeCodexBrowserURL)'; sleep 30"],environment:["HOME":root.path,"PATH":"/usr/bin:/bin"])
        })
        let accounts=AgentAccounts(services:services,codexServices:{ received in
            guard received == target else {throw AppError.message("Wrong selected Codex home")};return services
        });defer{accounts.stop()}
        try accounts.beginNativeCodexLogin(target)
        try expect(accounts.busy);try expectEqual(accounts.privateTTYs.count,1)
        let deadline=ContinuousClock.now.advanced(by:.seconds(10))
        while accounts.nativeCodexLogin?.phase != "waiting",ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(30))}
        try expectEqual(accounts.nativeCodexLogin?.url,nativeCodexBrowserURL);try expectNil(accounts.nativeCodexLogin?.code)
        try expectEqual(accounts.nativeCodexLogin?.home,target.home)
        let pin=try RemoteTunnelPIN.create("001234"),client=AccountTestClient(accounts,pin:pin)
        let unlock=try await client.call(accounts,pin:pin,["action":"unlock","pin":"001234"]),token=unlock["token"] as! String
        let status=try await client.call(accounts,pin:pin,["action":"status","token":token])
        try expectEqual((status["jobs"] as? [JSONObject])?.count,0)
        try expectFalse(String(decoding:try JSONSerialization.data(withJSONObject:status),as:UTF8.self).contains("synthetic-private-state"))
        let blocked=try await client.call(accounts,pin:pin,["action":"begin","agent":"codex","id":UUID().uuidString,"token":token])
        try expectEqual(blocked["status"] as? Int,409)
        accounts.cancelNativeCodexLogin();try expectFalse(accounts.busy)
        try expectEqual(accounts.nativeCodexLogin?.phase,"cancelled")
        let remote=try await client.call(accounts,pin:pin,["action":"begin","agent":"codex","id":UUID().uuidString,"token":token])
        try expectEqual(remote["phase"] as? String,"starting")
        do{try accounts.beginNativeCodexLogin(target);throw AppError.message("Duplicate login launched")}
        catch let e as RemoteHTTPError {try expectEqual(e.status,409)}
    }
    func testAccountCryptoPINReplayAndScope() async throws {
        let accounts=AgentAccounts(),pin=try RemoteTunnelPIN.create("001234"),client=AccountTestClient(accounts,pin:pin)
        defer{accounts.stop()}
        let hello=String(decoding:try JSONSerialization.data(withJSONObject:client.hello),as:UTF8.self)
        try expectFalse(hello.contains("001234"));try expectFalse(hello.contains("token"))
        let wrong=try await client.call(accounts,pin:pin,["action":"unlock","pin":"001235"]);try expectEqual(wrong["status"] as? Int,401)
        let (envelope,key,aad)=try client.packet(["action":"unlock","pin":"001234"])
        try expectFalse(String(decoding:try JSONSerialization.data(withJSONObject:envelope),as:UTF8.self).contains("001234"))
        let result=try client.read(await accounts.encrypted(envelope,node:client.node,pin:pin),key:key,aad:aad)
        let token=result["token"] as? String;try expectNotNil(token)
        let replay=try client.read(await accounts.encrypted(envelope,node:client.node,pin:pin),key:key,aad:aad);try expectEqual(replay["status"] as? Int,409)
        let stale=try await client.call(accounts,pin:pin,["action":"status","token":token!],age:91);try expectEqual(stale["status"] as? Int,409)
        do{_ = try await accounts.encrypted(envelope,node:UUID().uuidString,pin:pin);throw AppError.message("Expected node binding failure")}catch let error as RemoteHTTPError {try expectEqual(error.status,400)}
        var tampered=envelope;var data=Data(base64Encoded:envelope["payload"] as! String)!;data[data.count-1]^=1;tampered["payload"]=data.base64EncodedString()
        do{_ = try await accounts.encrypted(tampered,node:client.node,pin:pin);throw AppError.message("Expected tag failure")}catch let error as RemoteHTTPError {try expectEqual(error.status,400)}
        let noPIN=try await client.call(accounts,pin:nil,["action":"unlock","pin":"001234"]);try expectEqual(noPIN["status"] as? Int,403)
        let rotated=try RemoteTunnelPIN.create("001235")
        let revoked=try await client.call(accounts,pin:rotated,["action":"status","token":token!]);try expectEqual(revoked["status"] as? Int,401)
    }
    func testAccountPINAttemptsAreBounded() async throws {
        let accounts=AgentAccounts(),pin=try RemoteTunnelPIN.create("001234"),client=AccountTestClient(accounts,pin:pin);defer{accounts.stop()}
        for _ in 0..<5 {let result=try await client.call(accounts,pin:pin,["action":"unlock","pin":"111111"]);try expectEqual(result["status"] as? Int,401)}
        let result=try await client.call(accounts,pin:pin,["action":"unlock","pin":"001234"]);try expectEqual(result["status"] as? Int,429)
    }
    func testAccountChallengeOnlyAcceptsOfficialProviderURLs() throws {
        let codex=AgentAccountOutput.challenge("\u{1b}[32mhttps://auth.openai.com/codex/device\u{1b}[0m\nABCD-12345\n",agent:"codex")
        try expectEqual(codex.url,"https://auth.openai.com/codex/device");try expectEqual(codex.code,"ABCD-12345")
        let claude=AgentAccountOutput.challenge("Open https://claude.ai/oauth/authorize?state=test&code_challenge=bounded\n",agent:"claude")
        try expectNotNil(claude.url)
        let current="https://claude.com/cai/oauth/authorize?code=true&state=test&code_challenge=bounded"
        let hyperlinked=AgentAccountOutput.challenge("\u{1b}]8;;"+current+"\u{7}"+current+"\u{1b}]8;;\u{7}",agent:"claude")
        try expectEqual(hyperlinked.url,current,"Current Claude CLI OSC-8 links must not concatenate two URLs")
        for value in ["https://claude.ai.evil.invalid/oauth/authorize","https://claude.ai@evil.invalid/oauth/authorize","http://claude.ai/oauth/authorize","https://claude.ai:444/oauth/authorize","https://claude.ai/not-auth","https://auth.openai.com/oauth/authorize"] {try expectFalse(AgentAccountOutput.validURL(value,agent:"claude"))}
    }
    func testAccountPrivateLoginOwnershipCancelAndInventory() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-account-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let services=AgentAccountServices(home:root.path,check:{agent in AgentAccountState(agent:agent,phase:"signedOut")},launch:{_ in
            try ManagedPTY(cwd:root.path,program:"shell",command:["/bin/zsh","-f","-c","print 'https://claude.ai/oauth/authorize?state=test'; read -r input; print -r -- \"$input\" >> codes; sleep 0.4; exit 1"],columns:240,rows:40,environment:["HOME":root.path,"ZDOTDIR":root.path,"PATH":"/usr/bin:/bin"])
        })
        let accounts=AgentAccounts(services:services),pin=try RemoteTunnelPIN.create("001234"),client=AccountTestClient(accounts,pin:pin)
        defer{accounts.stop()}
        let unlock=try await client.call(accounts,pin:pin,["action":"unlock","pin":"001234"]),token=unlock["token"] as! String,id=UUID().uuidString
        let begin=try await client.call(accounts,pin:pin,["action":"begin","agent":"claude","id":id,"token":token]);try expectEqual(begin["id"] as? String,id)
        try expect(accounts.busy);try expectEqual(accounts.privateTTYs.count,1)
        let same=try await client.call(accounts,pin:pin,["action":"begin","agent":"claude","id":id,"token":token]);try expectEqual(same["id"] as? String,id);try expectEqual(accounts.privateTTYs.count,1)
        let other=try await client.call(accounts,pin:pin,["action":"unlock","pin":"001234"]),otherToken=other["token"] as! String
        let otherStatus=try await client.call(accounts,pin:pin,["action":"status","token":otherToken]);try expectEqual((otherStatus["jobs"] as? [JSONObject])?.count,0)
        let forbidden=try await client.call(accounts,pin:pin,["action":"submit","id":id,"code":"SENSITIVE","token":otherToken]);try expectEqual(forbidden["status"] as? Int,409)
        var phase="";for _ in 0..<40 {let status=try await client.call(accounts,pin:pin,["action":"status","token":token]);phase=((status["jobs"] as? [JSONObject])?.first?["phase"] as? String) ?? "";if phase=="waiting"{break};try await Task.sleep(for:.milliseconds(30))};try expectEqual(phase,"waiting")
        let engine=try ApprovalEngine(paths:AppPaths(directory:root.appendingPathComponent("profile")),processReader:{[]});defer{engine.stop()};engine.agentAccounts=accounts
        let tty=accounts.privateTTYs.first!,session=AgentSession(id:"private-auth",agent:.claude,pid:999999,started:"synthetic",tty:tty,cwd:root.path,terminal:.terminal)
        engine.updateDiscovery([session],records:[]);try expectEqual(engine.snapshot.sessions.count,0);try expectEqual(engine.managedPTY.inventory.count,0)
        let submit=try await client.call(accounts,pin:pin,["action":"submit","id":id,"code":"SENSITIVE","token":token]);try expectEqual(submit["phase"] as? String,"verifying")
        let again=try await client.call(accounts,pin:pin,["action":"submit","id":id,"code":"SENSITIVE","token":token]);try expectEqual(again["status"] as? Int,409)
        // The shell opens its append file before writing. File existence can
        // race the actual bytes; wait for a complete line, then assert its exact
        // value so a wrong/duplicate code still fails instead of being retried.
        var recorded:String?
        for _ in 0..<30 {
            recorded=try? String(contentsOf:root.appendingPathComponent("codes"),encoding:.utf8)
            if recorded?.hasSuffix("\n") == true {break}
            try await Task.sleep(for:.milliseconds(20))
        }
        try expectEqual(recorded,"SENSITIVE\n")
        _ = try await client.call(accounts,pin:pin,["action":"cancel","agent":"claude","token":otherToken]);try expectFalse(accounts.busy)
        accounts.stop();try expect(accounts.privateTTYs.contains(tty),"An in-flight discovery cannot expose a just-cancelled auth PTY")
    }
}
