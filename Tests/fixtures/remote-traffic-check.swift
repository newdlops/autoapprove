import Foundation
import Network
import Darwin

// Compiles with the production admission actors. Only the HTTP exchange below
// is replaced; it never opens a socket, discovers a host or sends user input.
struct RemoteHTTPResponse: Sendable { let status: Int = 200 }
final class RemoteHTTPExchange: @unchecked Sendable {
    let label: String
    init(endpoint: NWEndpoint, path: String, method: String, body: Data, expectedNodeID: String?, timeout: TimeInterval, retryReads: Bool) throws {
        guard method == "GET", body.isEmpty, !retryReads else { throw CheckError.failed("Discovery changed the read-only single-attempt boundary") }
        label = path
    }
    func run() async throws -> RemoteHTTPResponse {
        try Task.checkCancellation()
        await Wire.shared.begin(label)
        do { try await Task.sleep(for: .milliseconds(320)) }
        catch { await Wire.shared.end(); throw error }
        await Wire.shared.end(); return RemoteHTTPResponse()
    }
}
enum CheckError: Error { case failed(String) }
func require(_ value: Bool, _ message: String) throws {
    if !value { throw CheckError.failed(message) }
}
actor Wire {
    static let shared = Wire()
    var starts: [(String, Double)] = [], active = 0, peak = 0
    func begin(_ label: String) { starts.append((label,now())); active += 1; peak = max(peak,active) }
    func end() { active -= 1 }
    func reset() { starts = []; active = 0; peak = 0 }
    func values() -> ([(String, Double)], Int) { (starts,peak) }
}
actor Held {
    private var waiters: [Int: CheckedContinuation<Void,Never>] = [:]
    private var entered: Set<Int> = []
    func wait(_ id: Int) async {
        entered.insert(id)
        await withCheckedContinuation { waiters[id] = $0 }
    }
    func contains(_ id: Int) -> Bool { entered.contains(id) }
    func release(_ id: Int) { waiters.removeValue(forKey:id)?.resume() }
    func releaseAll() { let all = waiters; waiters.removeAll(); all.values.forEach { $0.resume() } }
}
actor Started {
    var values: [Int] = [], active = 0, peak = 0
    func begin(_ id: Int) { values.append(id); active += 1; peak = max(peak,active) }
    func end() { active -= 1 }
    func contains(_ id: Int) -> Bool { values.contains(id) }
    func count() -> Int { values.count }
    func maximum() -> Int { peak }
}
func now() -> Double { ProcessInfo.processInfo.systemUptime }
func cpu() -> Double {
    var value = rusage(); getrusage(RUSAGE_SELF,&value)
    return Double(value.ru_utime.tv_sec+value.ru_stime.tv_sec)+Double(value.ru_utime.tv_usec+value.ru_stime.tv_usec)/1_000_000
}
func until(_ message: String, _ predicate: () async -> Bool) async throws {
    let end = now()+5
    while !(await predicate()) {
        try require(now()<end,message)
        try await Task.sleep(for:.milliseconds(1))
    }
}
@main struct TrafficCheck {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("Traffic check failed: \(error)\n".utf8)); exit(1) }
    }
    static func run() async throws {
        let strict = !CommandLine.arguments.contains("--baseline")
        var checks: [String] = [], handovers: [Double] = []
        // A released slot must wake its queued reader, not wait for a 50ms poll.
        for _ in 0..<7 {
            let budget = RemoteDashboardTraffic(), held = Held()
            let busy = (0..<3).map { id in Task { try await budget.read { await held.wait(id); return RemoteHTTPResponse() } } }
            try await until("Three background slots must be occupied") {
                let a = await held.contains(0), b = await held.contains(1), c = await held.contains(2)
                return a && b && c
            }
            let next = Task { try await budget.read { RemoteHTTPResponse() } }
            try await Task.sleep(for:.milliseconds(12))
            let began = now(); await held.release(0); _ = try await next.value
            handovers.append((now()-began)*1000)
            await held.releaseAll(); for task in busy { _ = try await task.value }
        }
        let median = handovers.sorted()[3]
        if strict { try require(median<20,"Released slots waited for the periodic poll: median \(median)ms") }
        checks.append("Seven queued slot handovers measured")

        let budget = RemoteDashboardTraffic(), held = Held(), started = Started()
        func launch(_ id: Int, foreground: Bool = false) -> Task<RemoteHTTPResponse,Error> {
            Task { try await budget.read(foreground:foreground) { await started.begin(id); await held.wait(id); await started.end(); return RemoteHTTPResponse() } }
        }
        let busy = (0..<3).map { launch($0) }
        try await until("Background slots occupied") { await started.count() == 3 }
        let queued = launch(3)
        try await Task.sleep(for:.milliseconds(12))
        try require(!(await started.contains(3)),"Background read used the selected Mac's reserved slot")
        let selected = launch(4,foreground:true)
        try await until("Selected Mac needs its reserved fourth slot") { await started.contains(4) }
        try require(await started.maximum() == 4,"Selected read exceeded the four-read total")
        queued.cancel()
        do { _ = try await queued.value; throw CheckError.failed("Queued cancellation was ignored") } catch is CancellationError {}
        try require(!(await started.contains(3)),"Cancelled waiting reader ran its operation")
        let fifth = launch(5,foreground:true)
        try await Task.sleep(for:.milliseconds(12)); try require(!(await started.contains(5)),"A fifth concurrent read entered")
        await held.release(4); _ = try await selected.value
        try await until("Cancelled waiter must not leak a slot") { await started.contains(5) }
        await held.releaseAll(); for task in busy+[fifth] { _ = try await task.value }
        checks.append("Background three, selected fourth, total four, waiting cancellation and slot reuse")

        // Error and cancellation after admission must return the reservation.
        enum Synthetic: Error { case failure }
        do { _ = try await budget.read { throw Synthetic.failure }; throw CheckError.failed("Operation error disappeared") } catch Synthetic.failure {}
        let cancelled = Task { try await budget.read { try await Task.sleep(for:.seconds(10)); return RemoteHTTPResponse() } }
        try await Task.sleep(for:.milliseconds(5)); cancelled.cancel()
        do { _ = try await cancelled.value; throw CheckError.failed("Active cancellation disappeared") } catch is CancellationError {}
        _ = try await budget.read { RemoteHTTPResponse() }
        checks.append("Throw and active cancellation return the slot")

        let quiet = RemoteDashboardTraffic(), quietCPU = cpu(), quietTime = now()
        for _ in 0..<2000 { _ = try await quiet.read { RemoteHTTPResponse() } }
        let quietCPUSeconds = cpu()-quietCPU, quietMS = (now()-quietTime)*1000
        checks.append("Two thousand uncontended reads retain the direct admission path")

        // Measure actual actor queue work while all physical-equivalent slots
        // are held. The harness sleeps once; the production queue does the rest.
        var idleCPU: [Double] = []
        for _ in 0..<3 {
            let budget = RemoteDashboardTraffic(), held = Held()
            let busy = (0..<3).map { id in Task { try await budget.read { await held.wait(id); return RemoteHTTPResponse() } } }
            try await until("Idle fixture slots occupied") {
                let a = await held.contains(0), b = await held.contains(1), c = await held.contains(2)
                return a && b && c
            }
            let pending = (0..<96).map { _ in Task { try await budget.read { RemoteHTTPResponse() } } }
            try await Task.sleep(for:.milliseconds(20)); let began = cpu()
            try await Task.sleep(for:.milliseconds(600)); idleCPU.append(cpu()-began)
            pending.forEach { $0.cancel() }
            for task in pending { do { _ = try await task.value; throw CheckError.failed("Cancelled idle waiter ran") } catch is CancellationError {} }
            await held.releaseAll(); for task in busy { _ = try await task.value }
            _ = try await budget.read { RemoteHTTPResponse() }
        }
        checks.append("96 queued readers cancelled cleanly after three600ms idle CPU samples")

        let discovery = RemoteDiscoveryTraffic(), endpoint = NWEndpoint.hostPort(host:"127.0.0.1",port:8765)
        await Wire.shared.reset()
        let probes = (0..<6).map { id in Task { try await discovery.get(endpoint,path:"probe-\(id)",expectedID:id.isMultiple(of:2) ? "known" : nil) } }
        for task in probes { _ = try await task.value }
        let (wire,peak) = await Wire.shared.values()
        try require(wire.count == 6 && peak<=2,"Discovery exceeded two physical-equivalent exchanges or lost a read")
        let spaces = zip(wire.dropFirst(),wire).map { $0.1-$1.1 }
        try require(spaces.allSatisfy { $0 >= 0.24 },"Discovery exceeded its 250ms start pacing")
        checks.append("Discovery uses two slots and preserves250ms start pacing")
        await Wire.shared.reset()
        let first = Task { try await discovery.get(endpoint,path:"active",expectedID:"known") }
        try await until("Discovery initial request admitted") { await Wire.shared.values().0.count == 1 }
        let cancelledProbe = Task { try await discovery.get(endpoint,path:"cancelled",expectedID:"known") }
        try await Task.sleep(for:.milliseconds(10)); cancelledProbe.cancel()
        do { _ = try await cancelledProbe.value; throw CheckError.failed("Discovery cancellation ignored") } catch is CancellationError {}
        _ = try await first.value
        let (cancelledWire,_) = await Wire.shared.values()
        try require(!cancelledWire.contains { $0.0 == "cancelled" },"Cancelled discovery opened an exchange")
        _ = try await discovery.get(endpoint,path:"after-cancel",expectedID:"known")
        checks.append("Discovery cancellation never opens an exchange and returns admission")

        let priority = RemoteDiscoveryTraffic()
        await Wire.shared.reset()
        let initialBlind = Task { try await priority.get(endpoint,path:"blind-first") }
        try await until("Initial blind probe admitted") { await Wire.shared.values().0.count == 1 }
        let blind = Task { try await priority.get(endpoint,path:"blind-queued") }
        try await Task.sleep(for:.milliseconds(10))
        let known = (0..<10).map { id in Task { try await priority.get(endpoint,path:"known-\(id)",expectedID:"known") } }
        _ = try await initialBlind.value; _ = try await blind.value
        for task in known { _ = try await task.value }
        let (ordered,_) = await Wire.shared.values()
        try require(ordered[1].0.hasPrefix("known-"),"Unknown discovery took the saved identity's next slot")
        guard let firstBlind = ordered.first(where:{$0.0 == "blind-first"}),
              let nextBlind = ordered.first(where:{$0.0 == "blind-queued"}) else { throw CheckError.failed("Blind probe was lost") }
        try require(nextBlind.1-firstBlind.1 >= 2 && nextBlind.1-firstBlind.1 < 3,"Known probes starved fallback discovery or removed its priority interval")
        checks.append("Known identities take the next start; a queued blind probe progresses after two seconds")

        let expired = RemoteDiscoveryTraffic()
        await Wire.shared.reset()
        _ = try await expired.get(endpoint,path:"timer-base",expectedID:"known")
        let running = Task { try await expired.get(endpoint,path:"timer-active",expectedID:"known") }
        try await until("Wake replacement fixture admitted") { await Wire.shared.values().0.count == 2 }
        let abandoned = (0..<32).map { id in Task { try await expired.get(endpoint,path:"abandoned-\(id)",expectedID:"known") } }
        try await Task.sleep(for:.milliseconds(10)); abandoned.forEach { $0.cancel() }
        for task in abandoned { do { _ = try await task.value; throw CheckError.failed("Abandoned wake request ran") } catch is CancellationError {} }
        let replacement = Task { try await expired.get(endpoint,path:"timer-replacement",expectedID:"known") }
        _ = try await running.value; _ = try await replacement.value
        let (replaced,_) = await Wire.shared.values()
        try require(replaced.map(\.0) == ["timer-base","timer-active","timer-replacement"],"A cancelled wake revived an abandoned request or lost its replacement")
        checks.append("Cancelling the entire paced queue releases its wake; a replacement still runs once")

        let race = RemoteDashboardTraffic(), raceStarted = Started()
        var races: [Task<RemoteHTTPResponse,Error>] = []
        for id in 0..<160 {
            let task = Task { try await race.read(foreground:id.isMultiple(of:7)) {
                await raceStarted.begin(id)
                do { try await Task.sleep(for:.milliseconds(2)) }
                catch { await raceStarted.end(); throw error }
                await raceStarted.end(); return RemoteHTTPResponse()
            } }
            if id.isMultiple(of:2) { task.cancel() }; races.append(task)
        }
        for task in races { do { _ = try await task.value } catch is CancellationError {} }
        try require(await raceStarted.maximum() <= 4,"Cancellation race exceeded the total read budget")
        _ = try await race.read { RemoteHTTPResponse() }
        checks.append("160 mixed-priority cancellation races leave a reusable bounded budget")
        let report: [String:Any] = ["baseline":!strict,"checks":checks,"handoverMS":handovers,"handoverMedianMS":median,
            "queuedIdleCPUSeconds":idleCPU,"queuedIdleMedianCPUSeconds":idleCPU.sorted()[1],"discoveryStartSpacing":spaces,"discoveryPeak":peak,
            "uncontended2000CPUSeconds":quietCPUSeconds,"uncontended2000MS":quietMS,
            "inputPosts":0,"scope":"Actual production traffic actors; only exchange completion is synthetic. No socket, listener, manager, original terminal or OS policy changes."]
        print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
    }
}
