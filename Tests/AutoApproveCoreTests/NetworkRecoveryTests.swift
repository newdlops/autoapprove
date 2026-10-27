import Foundation
import AutoApproveCore

private final class RecoveryAttempts:@unchecked Sendable {
    private let lock = NSLock()
    private var connections = 0,delays:[Double] = []
    func connected() {lock.lock();connections += 1;lock.unlock()}
    func slept(_ delay:Double) {lock.lock();delays.append(delay);lock.unlock()}
    func snapshot() -> (Int,[Double]) {lock.lock();defer {lock.unlock()};return (connections,delays)}
}

extension ApprovalTests {
    func testRecoveryBackoffRemainsBoundedAcrossLongOutages() throws {
        var backoff = RemoteReconnectBackoff()
        for _ in 0..<100_000 {
            let delay = backoff.nextDelay()
            try expect(delay.isFinite && delay >= 0.8 && delay <= 30,"Long outages remain retryable at a bounded rate")
        }
        try expect(backoff.nextDelay(healthyFor:59,jitter:0.5) >= 25)
        try expectEqual(backoff.nextDelay(healthyFor:60,jitter:0.5),1)
        try expect(backoff.nextDelay(jitter:.nan).isFinite)
        var early = RemoteReconnectBackoff(),late = RemoteReconnectBackoff()
        try expect(early.nextDelay(jitter:0) < late.nextDelay(jitter:1),"Connectors do not all retry at the same instant")
    }
    func testRecoveryTracksSameAddressReturnAndIndependentInterfaces() throws {
        var changes = RemoteNetworkPathChanges()
        try expectFalse(changes.update(source:"default",available:true,fingerprint:"wifi-address-A"))
        try expectFalse(changes.update(source:"ethernet",available:false,fingerprint:"none"))
        try expectFalse(changes.update(source:"default",available:true,fingerprint:"wifi-address-A"))
        try expectFalse(changes.update(source:"default",available:false,fingerprint:"wifi-address-A"))
        try expect(changes.update(source:"default",available:true,fingerprint:"wifi-address-A"),"The same IP after an outage still needs stale route recovery")
        try expectFalse(changes.update(source:"ethernet",available:false,fingerprint:"none"))
        try expect(changes.update(source:"default",available:true,fingerprint:"ethernet-address-A"))
        try expectFalse(changes.update(source:"default",available:true,fingerprint:"ethernet-address-A"))
    }
    func testRecoveryWakeCancellationAndStopDoNotLeakWaiters() async throws {
        let recovery = RemoteNetworkRecovery(observesSystem:false)
        var callbacks = 0;recovery.start {callbacks += 1};defer {recovery.stop()}
        let waiting = Task {try await recovery.wait(seconds:30)}
        try await Task.sleep(for:.milliseconds(10));let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<20 {recovery.notifyAvailable()}
        try await waiting.value
        try expect(ProcessInfo.processInfo.systemUptime-start < 0.2,"Link return bypasses a thirty-second backoff")
        try expectEqual(callbacks,1,"Repeated link notifications coalesce")
        let cancelled = Task {try await recovery.wait(seconds:30)}
        try await Task.sleep(for:.milliseconds(5));cancelled.cancel()
        do {try await cancelled.value;throw AppError.message("Cancelled retry resumed")} catch is CancellationError {}
        let stopped = Task {try await recovery.wait(seconds:30)}
        try await Task.sleep(for:.milliseconds(5));recovery.stop()
        do {try await stopped.value;throw AppError.message("Stopped retry resumed")} catch is CancellationError {}
        recovery.notifyAvailable();try expectEqual(callbacks,1)
        recovery.start {callbacks += 1}
        let fresh = Task {try await recovery.wait(seconds:30)}
        try await Task.sleep(for:.milliseconds(5));recovery.notifyAvailable();try await fresh.value
        try expectEqual(callbacks,2,"A new generation is independent of cancelled timers")
    }
    func testRecoveryRelayContinuesPastSixFailuresAndKeepsGateway() async throws {
        let attempts = RecoveryAttempts()
        let recovery = RemoteNetworkRecovery(observesSystem:false,deadline:{delay in attempts.slept(delay);return .now()+0.005})
        let services = CloudflareRelayServices(connect:{_ in
            attempts.connected();let session = URLSession(configuration:.ephemeral)
            return CloudflareRelaySocket(session:session,task:session.webSocketTask(with:URL(string:"ws://127.0.0.1:9")!))
        },probe:{_ in throw URLError(.notConnectedToInternet)})
        let controller = CloudflareRelayController(handler:{_ in RemoteHTTPResponse(body:Data(),contentType:"text/plain")},services:services,recovery:recovery,onStatus:{_ in})
        defer {controller.stop()}
        var config = RemoteTunnelConfiguration();config.provider = .https;config.publicURL = "https://recovery.example.com"
        let credential = try JSONEncoder().encode(CloudflareRelayCredential(script:"autoapprove-relay-"+String(repeating:"a",count:32),origin:config.publicURL,key:String(repeating:"A",count:43)))
        try await controller.start(config,credential:credential)
        let key = controller.accessKey,local = controller.status.localURL
        for _ in 0..<600 where attempts.snapshot().0 < 9 {try await Task.sleep(for:.milliseconds(5))}
        try expect(attempts.snapshot().0 >= 9,"A long network outage must not permanently abandon the connector after six failures")
        try expect(controller.status.active);try expectEqual(controller.accessKey,key);try expectEqual(controller.status.localURL,local)
        try expect(attempts.snapshot().1.allSatisfy {$0 >= 0.8 && $0 <= 30})
        controller.stop();let count = attempts.snapshot().0
        try await Task.sleep(for:.milliseconds(30));try expectEqual(attempts.snapshot().0,count);try expectEqual(controller.status.phase,"off")
    }
    func testRecoveryRetainsEarlyWakeAndRespectsServerBackoff() async throws {
        let recovery = RemoteNetworkRecovery(observesSystem:false);recovery.start();defer {recovery.stop()}
        recovery.notifyAvailable();let began = ProcessInfo.processInfo.systemUptime
        try await recovery.wait(seconds:30)
        try expect(ProcessInfo.processInfo.systemUptime-began < 0.2,"A link event just before a failed handshake reaches backoff must not be lost")
        let waiting = Task {try await recovery.wait(seconds:30,interruptible:false)}
        try await Task.sleep(for:.milliseconds(270));recovery.notifyAvailable()
        var returned = false
        let observer = Task {try await waiting.value;returned = true}
        try await Task.sleep(for:.milliseconds(10));try expectFalse(returned,"A connectivity event cannot bypass Retry-After")
        waiting.cancel()
        do {try await observer.value;throw AppError.message("Server backoff cancellation was ignored")} catch is CancellationError {}
    }
    func testRecoveryCloudflaredRestartsKeepGatewayAndStopPermanently() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-network-recovery-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let attempts = RecoveryAttempts()
        let recovery = RemoteNetworkRecovery(observesSystem:false,deadline:{delay in attempts.slept(delay);return .now()+0.005})
        let controller = RemoteTunnelController(directory:root,handler:{_ in RemoteHTTPResponse(body:Data(),contentType:"text/plain")},recovery:recovery,onStatus:{_ in})
        defer {controller.stop(waitForExit:true)}
        var config = RemoteTunnelConfiguration();config.executable = "/usr/bin/true"
        try await controller.start(config);let key = controller.accessKey,local = controller.status.localURL
        for _ in 0..<600 where controller.status.quality.reconnects < 9 {try await Task.sleep(for:.milliseconds(5))}
        try expect(controller.status.quality.reconnects >= 9,"Owned connector exits remain recoverable beyond five restarts")
        try expectEqual(controller.accessKey,key);try expectEqual(controller.status.localURL,local);try expect(controller.status.active)
        controller.stop(waitForExit:true);let count = attempts.snapshot().1.count
        try await Task.sleep(for:.milliseconds(30));try expectEqual(attempts.snapshot().1.count,count);try expectEqual(controller.status.phase,"off")
    }
    func testRecoveryCloudflaredCredentialErrorsStopWithoutRetrying() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-rejected-connector-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:root)}
        for message in ["Provided Tunnel token is not valid.","Unauthorized: Invalid tunnel secret"] {
            let executable = root.appendingPathComponent("synthetic-connector")
            try Data(("#!/bin/sh\nprintf '%s\\n' '"+message+"'\nexec /bin/sleep 2\n").utf8).write(to:executable)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
            let recovery = RemoteNetworkRecovery(observesSystem:false,deadline:{_ in .now()+0.005})
            let controller = RemoteTunnelController(directory:root,handler:{_ in RemoteHTTPResponse(body:Data(),contentType:"text/plain")},recovery:recovery,onStatus:{_ in})
            defer {controller.stop(waitForExit:true)}
            var config = RemoteTunnelConfiguration();config.executable = executable.path;try await controller.start(config)
            for _ in 0..<200 where controller.status.phase != "failed" {try await Task.sleep(for:.milliseconds(5))}
            try expectEqual(controller.status.phase,"failed");try expectNil(controller.accessKey)
            try expectFalse(controller.status.detail.contains(message));try expectFalse(controller.status.detail.contains(root.path))
            try await Task.sleep(for:.milliseconds(30));try expectEqual(controller.status.phase,"failed");try expectEqual(controller.status.quality.reconnects,0)
        }
    }
}
