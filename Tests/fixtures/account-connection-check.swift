// A slow synthetic keychain must not block unrelated network/source work.
import Foundation
import AutoApproveCore

private final class Secrets:@unchecked Sendable {
    private let lock=NSLock()
    private var delay:TimeInterval=0.4,count=0,active=0,maximum=0
    func setDelay(_ value:TimeInterval) {lock.lock();delay=value;lock.unlock()}
    func read() -> Data? {
        lock.lock();count+=1;active+=1;maximum=max(maximum,active);let pause=delay;lock.unlock()
        Thread.sleep(forTimeInterval:pause)
        lock.lock();active-=1;lock.unlock();return nil
    }
    func stats() -> (Int,Int,Int) {lock.lock();defer{lock.unlock()};return (count,active,maximum)}
}
@main struct AccountConnectionCheck {
    @MainActor static func main() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-account-connect-"+UUID().uuidString),secrets=Secrets()
        defer {try? FileManager.default.removeItem(at:root)}
        let services=CloudflareServices(exchange:{_ in throw AppError.message("No real provider")},login:{_,_,_ in Data()},readSecret:{_,_ in secrets.read()},saveSecret:{_,_,_ in})
        let engine=try ApprovalEngine(paths:AppPaths(directory:root),processReader:{[]},cloudflareServices:services);defer{engine.stop()}
        let web=RemoteNetworkService(engine:engine,nodeID:UUID().uuidString,loopbackOnly:true,onStatus:{_ in});defer{web.stop()}
        func request(_ path:String) throws -> RemoteHTTPRequest {try RemoteHTTPRequest.parse(Data("GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))!}
        let key=try request("/api/agent-account/key"),discovery=try request("/api/discovery")
        func require(_ value:Bool,_ reason:String) throws {if !value {throw AppError.message(reason)}}
        let baseline=CommandLine.arguments.contains("--baseline")
        let before=secrets.stats().0,start=ProcessInfo.processInfo.systemUptime
        let reads=(0..<12).map {_ in Task {await web.handle(key)}}
        try await Task.sleep(for:.milliseconds(30))
        let response=await web.handle(discovery),latency=ProcessInfo.processInfo.systemUptime-start
        try require(response.status==200,"Unrelated discovery failed")
        let statuses=await reads.asyncStatuses()
        if baseline {
            try require(latency>1,"Old synchronous PIN reads did not reproduce actor starvation")
            print("{\"baseline\":true,\"reproduced\":true,\"discoveryDelayMS\":\(Int(latency*1000)),\"secretReads\":\(secrets.stats().0-before)}");return
        }
        try require(latency<0.25,"PIN reads blocked discovery for \(latency)s")
        try require(statuses.allSatisfy{$0==200},"Concurrent reads failed")
        try require(secrets.stats().0-before==1,"Concurrent reads did not share one keychain IPC")
        let firstDelay=Int(latency*1000)
        secrets.setDelay(2.6);let stalledBefore=secrets.stats().0,began=ProcessInfo.processInfo.systemUptime
        let stalled=(0..<8).map {_ in Task {await web.handle(key)}}
        try await Task.sleep(for:.milliseconds(30))
        let cancel=Task {await web.handle(key)};try await Task.sleep(for:.milliseconds(10));cancel.cancel();_ = await cancel.value
        try require((await web.handle(discovery)).status==200,"A cancelled PIN caller blocked discovery")
        let timed=await stalled.asyncStatuses(),elapsed=ProcessInfo.processInfo.systemUptime-began
        try require(timed.allSatisfy{$0==503}&&elapsed<2.4,"Stalled keychain callers did not fail within their deadline")
        let retries=(0..<8).map {_ in Task {await web.handle(key)}}
        try await Task.sleep(for:.milliseconds(20))
        try require(secrets.stats().0-stalledBefore==1&&secrets.stats().2==1,"Timed-out callers started unbounded Security workers")
        try engine.clearTunnelPIN()
        try require((await retries.asyncStatuses()).allSatisfy{$0==409},"PIN rotation accepted an old in-flight result")
        try await Task.sleep(for:.milliseconds(650));secrets.setDelay(0)
        try require((await web.handle(key)).status==200,"A fresh request could not recover after old IPC completed")
        try require(secrets.stats().0-stalledBefore==2,"Completed credentials were cached between requests")
        print("{\"passed\":true,\"groups\":4,\"concurrentReads\":12,\"discoveryDelayMS\":\(firstDelay),\"stalledDeadlineMS\":\(Int(elapsed*1000)),\"maximumSecurityWorkers\":\(secrets.stats().2),\"scope\":\"Actual Core handlers with slow synthetic keychain; concurrent, cancellation, deadline, rotation and fresh recovery\"}")
    }
}
private extension Array where Element==Task<RemoteHTTPResponse,Never> {
    func asyncStatuses() async -> [Int] {var values:[Int]=[];for task in self {values.append(await task.value.status)};return values}
}
