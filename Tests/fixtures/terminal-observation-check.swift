import Foundation
import Darwin

private enum Failure: Error { case check(String) }
private func require(_ value: Bool, _ message: String) throws { if !value { throw Failure.check(message) } }
private final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String:Int] = [:]
    func add(_ name: String) { lock.lock(); values[name,default:0] += 1; lock.unlock() }
    func value(_ name: String) -> Int { lock.lock(); defer { lock.unlock() }; return values[name,default:0] }
}
private final class Handle: @unchecked Sendable {
    let notify: @Sendable () -> Void
    let counts: Counts
    let targets: [Int]
    init(_ counts: Counts, targets: [Int] = [], notify: @escaping @Sendable () -> Void) { self.counts = counts; self.targets = targets; self.notify = notify; counts.add("created") }
    deinit { counts.add("destroyed") }
}
private final class LeaseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lease: TerminalObservationLease<Handle>?
    func set(_ value: TerminalObservationLease<Handle>?) { lock.lock(); lease = value; lock.unlock() }
    func clear() { lock.lock(); let old = lease; lease = nil; lock.unlock(); withExtendedLifetime(old) {} }
}
private struct Identity: Equatable { let pid: Int; let start: Int }

@main private struct ObservationCheck {
    @MainActor static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("Observation check failed: \(error)\n".utf8)); exit(1) }
    }
    @MainActor static func run() throws {
        let pool = TerminalObservationPool<Identity,Handle>(), counts = Counts()
        let key = Identity(pid:10,start:1)
        weak var latest: Handle?
        func make(_ notify: @escaping @Sendable () -> Void) -> Handle? {
            let handle = Handle(counts,notify:notify); latest = handle; return handle
        }
        var leases: [TerminalObservationLease<Handle>] = []
        for index in 0..<6 {
            guard let lease = pool.subscribe(identity:key,make:make,changed:{ counts.add("listener-\(index)") }) else { throw Failure.check("A valid source failed") }
            leases.append(lease)
        }
        let created = counts.value("created")
        print("Six subscribers created \(created) source handles")
        try require(created == 1,"Same live Terminal identity must share one handle; received \(created)")
        latest?.notify()
        try require((0..<6).allSatisfy {counts.value("listener-\($0)") == 1},"One native event must wake every subscriber")
        leases.removeFirst(); latest?.notify()
        try require(counts.value("listener-0") == 1 && (1..<6).allSatisfy {counts.value("listener-\($0)") == 2},"Closing one subscriber must not stop its neighbours")
        leases.removeAll()
        try require(latest == nil && counts.value("destroyed") == 1,"The pool must not retain the last native handle")
        var again = pool.subscribe(identity:key,make:make,changed:{ counts.add("again") })
        try require(counts.value("created") == 2,"A later connection must create a fresh observation")
        latest?.notify(); try require(counts.value("again") == 1,"The replacement subscription must receive events")
        again = nil
        try require(latest == nil,"Replacement handle leaked")

        var checks = ["one handle for six same-identity subscribers", "event fanout and independent close", "last-close teardown and fresh reopening"]
        let isolation = Counts()
        weak var first: Handle?, second: Handle?
        var old = pool.subscribe(identity:key,make:{ notify in let h = Handle(isolation,notify:notify); first = h; return h },changed:{isolation.add("old")})
        var failed = pool.subscribe(identity:Identity(pid:11,start:1),make:{_ in nil},changed:{isolation.add("failed")})
        try require(failed == nil,"Failed setup must not reuse another Terminal")
        var same = pool.subscribe(identity:key,make:{ _ in throwUnexpectedFactory() },changed:{isolation.add("same")})
        first?.notify(); try require(isolation.value("old") == 1 && isolation.value("same") == 1,"Failed setup must not invalidate the existing source")
        var replacement = pool.subscribe(identity:Identity(pid:10,start:2),make:{ notify in let h = Handle(isolation,notify:notify); second = h; return h },changed:{isolation.add("new")})
        second?.notify(); try require(isolation.value("new") == 1 && isolation.value("old") == 1,"Reused PID with a different lifetime must use a distinct source")
        first?.notify(); try require(isolation.value("old") == 2 && isolation.value("new") == 1,"Old and new source notifications must stay isolated")
        old = nil; same = nil; replacement = nil; failed = nil
        try require(first == nil && second == nil && isolation.value("created") == isolation.value("destroyed"),"A replaced source or callback leaked")
        checks.append("failure, retry, reused PID and old/new source isolation")

        let anonymous = Counts()
        var unidentified = (0..<2).compactMap { _ in pool.subscribe(identity:nil,make:{Handle(anonymous,notify:$0)},changed:{}) }
        try require(unidentified.count == 2 && anonymous.value("created") == 2,"Missing launch identity must not be shared")
        unidentified.removeAll(); try require(anonymous.value("destroyed") == 2,"Unidentified sources must still tear down")
        checks.append("no sharing without an authoritative launch identity")

        let concurrent = Counts()
        weak var concurrentHandle: Handle?
        var concurrentLeases = (0..<6).compactMap { index in pool.subscribe(identity:key,make:{ notify in let h = Handle(concurrent,notify:notify); concurrentHandle = h; return h },changed:{concurrent.add("\(index)")}) }
        guard let emit = concurrentHandle?.notify else { throw Failure.check("Missing concurrent source") }
        DispatchQueue.concurrentPerform(iterations:1000) { _ in emit() }
        try require((0..<6).allSatisfy {concurrent.value("\($0)") == 1000},"Concurrent event delivery lost or duplicated callbacks")
        concurrentLeases.removeAll()
        try require(concurrentHandle == nil && concurrent.value("destroyed") == 1,"Concurrent source was retained")
        emit(); try require((0..<6).allSatisfy {concurrent.value("\($0)") == 1000},"An already queued native callback must not retain closed subscribers")
        checks.append("concurrent notifications and queued-callback cleanup")

        let reentrant = Counts(), closing = LeaseBox()
        weak var reentrantHandle: Handle?
        var primary = pool.subscribe(identity:key,make:{notify in let h = Handle(reentrant,notify:notify); reentrantHandle = h; return h},changed:{[weak closing] in closing?.clear(); reentrant.add("primary")})
        closing.set(pool.subscribe(identity:key,make:{_ in throwUnexpectedFactory()},changed:{reentrant.add("closed")}))
        try withExtendedLifetime((closing,primary)) {
            reentrantHandle?.notify(); let previous = reentrant.value("closed")
            reentrantHandle?.notify()
            try require(reentrant.value("primary") == 2 && reentrant.value("closed") == previous,"A callback must be able to close another lease without deadlock or later notifications")
        }
        primary = nil; closing.clear()
        try require(reentrantHandle == nil,"Reentrant close leaked its source")
        checks.append("a callback can close another subscriber")

        let detached = Counts()
        var temporary: TerminalObservationPool<Identity,Handle>? = TerminalObservationPool()
        weak var detachedHandle: Handle?
        var detachedLease = temporary?.subscribe(identity:key,make:{notify in let h = Handle(detached,notify:notify); detachedHandle = h; return h},changed:{detached.add("notified")})
        try withExtendedLifetime(detachedLease) {
            temporary = nil; detachedHandle?.notify()
            try require(detached.value("notified") == 1,"Releasing the weak cache must not stop a live subscription")
        }
        detachedLease = nil
        try require(detachedHandle == nil,"A lease outliving its cache retained the native handle")
        checks.append("live leases can outlive the weak cache")

        let topologyPool = TerminalObservationPool<Identity,Handle>(), topologyCounts = Counts()
        var currentTargets = [1], validations = 0
        weak var beforeTopology: Handle?, afterTopology: Handle?
        func compatible(_ handle: Handle) -> Bool { validations += 1; return handle.targets == currentTargets }
        func setup(_ notify: @escaping @Sendable () -> Void) -> Handle? {
            if currentTargets == [3] { return nil }
            let h = Handle(topologyCounts,targets:currentTargets,notify:notify)
            if currentTargets == [1] { beforeTopology = h } else { afterTopology = h }
            return h
        }
        var firstTopology = topologyPool.subscribe(identity:key,canReuse:compatible,make:setup,changed:{topologyCounts.add("before")})
        var sameTopology = topologyPool.subscribe(identity:key,canReuse:compatible,make:setup,changed:{topologyCounts.add("same")})
        try require(topologyCounts.value("created") == 1,"Fresh identical targets should share registration")
        currentTargets = [1,2]
        var changedTopology = topologyPool.subscribe(identity:key,canReuse:compatible,make:setup,changed:{topologyCounts.add("after")})
        try require(topologyCounts.value("created") == 2,"A new window/tab must rebuild registration even with the same app lifetime")
        try require(validations == 2,"Every repeated subscription must validate its freshly enumerated targets")
        beforeTopology?.notify(); afterTopology?.notify()
        try require(topologyCounts.value("before") == 1 && topologyCounts.value("same") == 1 && topologyCounts.value("after") == 1,"Old and new target coverage must stay alive for their own leases")
        currentTargets = [3]
        var missingTopology = topologyPool.subscribe(identity:key,canReuse:compatible,make:setup,changed:{topologyCounts.add("missing")})
        try require(missingTopology == nil,"Failed target refresh must not fall back to stale registrations")
        currentTargets = [1,2]
        var recoveredTopology = topologyPool.subscribe(identity:key,canReuse:compatible,make:setup,changed:{topologyCounts.add("recovered")})
        try require(topologyCounts.value("created") == 2 && validations == 4,"A failed replacement must preserve the last valid target set")
        try withExtendedLifetime((firstTopology,sameTopology,changedTopology,recoveredTopology)) {
            afterTopology?.notify()
            try require(topologyCounts.value("before") == 1 && topologyCounts.value("after") == 2 && topologyCounts.value("recovered") == 1,"A later subscriber must receive events from the fresh target coverage")
        }
        firstTopology = nil; sameTopology = nil; changedTopology = nil; missingTopology = nil; recoveredTopology = nil
        try require(beforeTopology == nil && afterTopology == nil && topologyCounts.value("destroyed") == 2,"Topology replacement must not retain either native handle")
        checks.append("fresh target validation, topology replacement and refresh failure isolation")
        // Keep reads explicit so compiler diagnostics also verify lease lifetimes.
        _ = again; _ = old; _ = same; _ = replacement; _ = failed; _ = primary; _ = detachedLease
        _ = firstTopology; _ = sameTopology; _ = changedTopology; _ = missingTopology; _ = recoveredTopology
        let result: [String:Any] = ["passed":checks.count,"checks":checks,"sameIdentitySubscribers":6,"createdHandles":created,"originalInputPosts":0,"scope":"Actual production observation pool with injected handle allocation and notifications; no native AX, screens, sockets or original terminal input. No whole-program or LAN speed claim."]
        print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self))
    }
    static func throwUnexpectedFactory() -> Handle? { fatalError("Same-identity acquisition reran the factory") }
}
