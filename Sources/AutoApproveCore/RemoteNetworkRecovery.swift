import AppKit
import Foundation
import Network

/// Recovery is unbounded in duration, bounded in rate, and never replays input.
public struct RemoteReconnectBackoff: Sendable {
    public private(set) var failures = 0
    public init() {}
    public mutating func nextDelay(healthyFor:TimeInterval = 0,jitter:Double = Double.random(in:0...1)) -> TimeInterval {
        if healthyFor >= 60 {failures = 0}
        failures = min(16,failures+1)
        let unit = jitter.isFinite ? min(1,max(0,jitter)):0.5
        return min(30,Double(1 << min(5,failures-1))*(0.8+0.4*unit))
    }
}

/// Separate monitor sources must not turn initial Wi-Fi/Ethernet observations
/// into alternating recovery events. A return on the same IP still counts.
public struct RemoteNetworkPathChanges: Sendable {
    private struct Value:Equatable,Sendable {let available:Bool,fingerprint:String}
    private var values:[String:Value] = [:]
    public init() {}
    public mutating func update(source:String,available:Bool,fingerprint:String) -> Bool {
        let next = Value(available:available,fingerprint:fingerprint),previous = values.updateValue(next,forKey:source)
        return available && previous != nil && previous != next
    }
    static func fingerprint(_ path:NWPath) -> String {
        let types:[NWInterface.InterfaceType] = [.wifi,.wiredEthernet,.cellular,.loopback,.other]
        return types.filter {path.usesInterfaceType($0)}.map {String(describing:$0)}.joined(separator:",")
            + "|\(path.supportsIPv4)|\(path.supportsIPv6)|\(path.isExpensive)|\(path.isConstrained)|"
            + path.gateways.map {String(describing:$0)}.sorted().joined(separator:",")
    }
}

/// One cancellable wait per connector. Link return and system wake can bypass
/// backoff without polling or creating additional connection attempts.
@MainActor public final class RemoteNetworkRecovery {
    private let observesSystem:Bool
    private let deadline:@Sendable(TimeInterval) -> DispatchTime
    private var monitor:NWPathMonitor?,wake:NSObjectProtocol?
    private var paths = RemoteNetworkPathChanges()
    private var generation = UUID()
    private var active = false,lastSignal = -Double.infinity
    private var pendingSignal = false,interruptible = true
    private var onAvailable:(@MainActor()->Void)?
    private var ticket:UUID?,continuation:CheckedContinuation<Void,Error>?,timer:DispatchWorkItem?
    public init(observesSystem:Bool = true,deadline:@escaping @Sendable(TimeInterval) -> DispatchTime = {.now()+$0}) {
        self.observesSystem = observesSystem;self.deadline = deadline
    }
    public func start(onAvailable:@escaping @MainActor()->Void = {}) {
        stop();active = true;lastSignal = -Double.infinity;pendingSignal = false;self.onAvailable = onAvailable
        let epoch = generation
        guard observesSystem else {return}
        let monitor = NWPathMonitor();self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied,fingerprint = RemoteNetworkPathChanges.fingerprint(path)
            Task { @MainActor [weak self] in
                guard let self,self.active,self.generation == epoch else {return}
                if self.paths.update(source:"default",available:available,fingerprint:fingerprint) {self.notifyAvailable()}
            }
        }
        monitor.start(queue:DispatchQueue(label:"local.autoapprove.connection-recovery",qos:.utility))
        wake = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor [weak self] in guard let self,self.generation == epoch else {return};self.notifyAvailable() }
        }
    }
    public func stop() {
        active = false;pendingSignal = false;generation = UUID();monitor?.cancel();monitor = nil
        if let wake {NSWorkspace.shared.notificationCenter.removeObserver(wake)};wake = nil
        paths = RemoteNetworkPathChanges();onAvailable = nil
        if let ticket {finish(ticket,result:.failure(CancellationError()))}
    }
    public func notifyAvailable() {
        guard active else {return}
        let now = ProcessInfo.processInfo.systemUptime
        guard now-lastSignal >= 0.25 else {return};lastSignal = now
        pendingSignal = true
        if let ticket,interruptible {pendingSignal = false;finish(ticket,result:.success(()))}
        onAvailable?()
    }
    public func wait(seconds:TimeInterval,interruptible:Bool = true) async throws {
        try Task.checkCancellation();guard active else {throw CancellationError()}
        // A link return may cancel the old handshake before its failure reaches
        // this wait. Retain one recent signal so it cannot be lost in that gap.
        if interruptible,pendingSignal,ProcessInfo.processInfo.systemUptime-lastSignal < 10 {pendingSignal = false;return}
        pendingSignal = false
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
                guard active,!Task.isCancelled else {continuation.resume(throwing:CancellationError());return}
                if let ticket {finish(ticket,result:.failure(CancellationError()))}
                self.ticket = id;self.continuation = continuation;self.interruptible = interruptible
                let timer = DispatchWorkItem { [weak self] in
                    Task { @MainActor [weak self] in self?.finish(id,result:.success(())) }
                }
                self.timer = timer;DispatchQueue.main.asyncAfter(deadline:deadline(seconds),execute:timer)
            }
        } onCancel: {Task { @MainActor [weak self] in self?.finish(id,result:.failure(CancellationError())) }}
    }
    private func finish(_ id:UUID,result:Result<Void,Error>) {
        guard ticket == id else {return}
        let pending = continuation;continuation = nil;ticket = nil
        timer?.cancel();timer = nil;pending?.resume(with:result)
    }
}
