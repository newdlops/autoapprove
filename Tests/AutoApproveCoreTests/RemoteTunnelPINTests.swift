import Foundation
import AutoApproveCore

private final class PINClock:@unchecked Sendable {
    private let lock=NSLock();private var time:TimeInterval=100
    func now()->TimeInterval {lock.lock();defer{lock.unlock()};return time}
    func advance() {lock.lock();time+=61;lock.unlock()}
}
extension ApprovalTests {
    func testPINUsesSaltedVerificationAndKeepsLeadingZeros() throws {
        for value in ["000001","123456789012"] {try expect(RemoteTunnelPIN.valid(value))}
        for value in ["12345","1234567890123","１２３４５６","abc123","123 456"," 012345"] {try expectFalse(RemoteTunnelPIN.valid(value));try expectThrows(try RemoteTunnelPIN.create(value))}
        let a=try RemoteTunnelPIN.create("001234"),b=try RemoteTunnelPIN.create("001234")
        try expect(a.matches("001234"));try expectFalse(a.matches("1234"));try expectFalse(a.matches("001235"))
        let data=try JSONEncoder().encode(a)
        try expect(data != JSONEncoder().encode(b));try expectFalse(String(decoding:data,as:UTF8.self).contains("001234"))
        try expect(try RemoteTunnelPIN.decode(data).matches("001234"))
        let vector=try JSONSerialization.data(withJSONObject:["version":1,"salt":"AAAAAAAAAAAAAAAAAAAAAA==","digest":"jQpX1aoJ4UcnCWmaxgC3AVY9Ys7n4nyJJyn6cJE7I30="])
        try expect(try RemoteTunnelPIN.decode(vector).matches("001234"),"PBKDF2-SHA256 600,000 iterations must match an independent Node crypto vector")
        let malformed=Data("{\"version\":1,\"salt\":\"\",\"digest\":\"\"}".utf8)
        try expectThrows(try RemoteTunnelPIN.decode(malformed))
        try expectFalse(try JSONDecoder().decode(RemoteTunnelPIN.self,from:malformed).matches("001234"))
        try expectThrows(try RemoteTunnelPIN.decode(Data(repeating:0,count:1025)))
    }
    func testPINKeychainPersistenceClearAndCancellation() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-pin-"+UUID().uuidString),fixture=WorkersFixture()
        defer{try? FileManager.default.removeItem(at:root)}
        let engine=try ApprovalEngine(paths:AppPaths(directory:root),processReader:{[]},cloudflareServices:fixture.http)
        defer{engine.stop()};try engine.loadTunnelPIN();try expectFalse(engine.tunnelPINConfigured)
        let cancelled=Task {try await engine.setTunnelPIN("001234")};cancelled.cancel()
        do {try await cancelled.value;throw CloudflareFixture.Failure()} catch is CancellationError {} catch{throw error}
        try expectNil(fixture.secrets["remote-tunnel-pin"])
        try await engine.setTunnelPIN("001234");try expect(engine.tunnelPINConfigured)
        let encoded=fixture.secrets["remote-tunnel-pin"]!;try expectFalse(String(decoding:encoded,as:UTF8.self).contains("001234"))
        let next=try ApprovalEngine(paths:AppPaths(directory:root),processReader:{[]},cloudflareServices:fixture.http);defer{next.stop()}
        try next.loadTunnelPIN();try expect(next.tunnelPINConfigured)
        try next.clearTunnelPIN();try engine.loadTunnelPIN();try expectFalse(engine.tunnelPINConfigured)
        fixture.secrets["remote-tunnel-pin"]=Data("invalid".utf8);try expectThrows(try engine.loadTunnelPIN())
    }
    func testPINRateLimitConcurrentAttemptsRotationAndSessionRevocation() async throws {
        let clock=PINClock(),credential=try RemoteTunnelPIN.create("001234")
        let gateway=try RemoteTunnelGateway(pin:credential,clock:{clock.now()},handler:{_ in try! .object(["ok":true])})
        defer{gateway.stop()};try await gateway.start(port:0);try gateway.setOrigin("https://pin.tunnel-qa.invalid")
        let base="http://127.0.0.1:\(gateway.port!)",origin="https://pin.tunnel-qa.invalid"
        let config=URLSessionConfiguration.ephemeral;config.httpShouldSetCookies=false;config.httpCookieStorage=nil
        let session=URLSession(configuration:config);defer{session.invalidateAndCancel()}
        func call(_ path:String,key:String?=nil,cookie:String?=nil) async throws -> (Data,HTTPURLResponse) {
            var request=URLRequest(url:URL(string:base+path)!);request.setValue("pin.tunnel-qa.invalid",forHTTPHeaderField:"Host")
            if let cookie {request.setValue(cookie,forHTTPHeaderField:"Cookie")}
            if let key {request.httpMethod="POST";request.setValue(origin,forHTTPHeaderField:"Origin");request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.httpBody=try JSONSerialization.data(withJSONObject:["key":key])}
            let (data,response)=try await session.data(for:request);return (data,response as! HTTPURLResponse)
        }
        let html=try await call("/");try expect(String(decoding:html.0,as:UTF8.self).contains("data-pin=\"true\""))
        let rejected=try await withThrowingTaskGroup(of:Int.self) {group in
            for _ in 0..<5 {group.addTask {try await call("/auth/login",key:"111111").1.statusCode}}
            var statuses:[Int]=[];for try await status in group {statuses.append(status)};return statuses
        }
        try expectEqual(rejected,Array(repeating:401,count:5));try expectEqual(try await call("/auth/login",key:"001234").1.statusCode,429)
        let oldKey=gateway.accessKey
        try expectEqual(try await call("/auth/login",key:oldKey).1.statusCode,200)
        clock.advance();let logged=try await call("/auth/login",key:"001234")
        try expectEqual(logged.1.statusCode,200);let cookie=logged.1.value(forHTTPHeaderField:"Set-Cookie")!.components(separatedBy:";")[0]
        try expectEqual(try await call("/api/state",cookie:cookie).1.statusCode,200)
        let next=try RemoteTunnelPIN.create("009876");gateway.setPIN(next,accessKey:String(repeating:"k",count:43))
        try expectEqual(try await call("/api/state",cookie:cookie).1.statusCode,401)
        try expectEqual(try await call("/auth/login",key:oldKey).1.statusCode,401)
        try expectEqual(try await call("/auth/login",key:"001234").1.statusCode,401)
        try expectEqual(try await call("/auth/login",key:"009876").1.statusCode,200)
        let late=Task {try await call("/auth/login",key:"009876")}
        try await Task.sleep(for:.milliseconds(10));gateway.setPIN(credential,accessKey:String(repeating:"q",count:43))
        do {try expectEqual(try await late.value.1.statusCode,401,"A PIN verified across a PIN change must not create a session")}
        catch let error as URLError where [.networkConnectionLost,.cancelled].contains(error.code) {} // PIN rotation closes in-flight clients.
        try expectEqual(gateway.sessionCount,0)
        gateway.setPIN(nil,accessKey:String(repeating:"m",count:43))
        try expectFalse(gateway.pinEnabled);try expectEqual(try await call("/auth/login",key:"009876").1.statusCode,401)
        try expectEqual(try await call("/auth/login",key:String(repeating:"m",count:43)).1.statusCode,200)
    }
}
