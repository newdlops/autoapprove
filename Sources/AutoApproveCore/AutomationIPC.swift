import Foundation
import AppKit
import Carbon

private final class IPCWorkers: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let condition = NSCondition()
        var jobs: [() -> Void] = []
        var stopping = false
        func loop() {
            while true {
                condition.lock()
                while jobs.isEmpty && !stopping { condition.wait() }
                if stopping && jobs.isEmpty { condition.unlock(); return }
                let job = jobs.removeFirst()
                condition.unlock()
                autoreleasepool(invoking:job)
            }
        }
    }
    private let state = State()
    private var count = 0
    func submit(_ job:@escaping () -> Void) {
        state.condition.lock()
        state.jobs.append(job)
        if count < 2 {
            count += 1
            Thread.detachNewThread { [state] in state.loop() }
        }
        state.condition.signal()
        state.condition.unlock()
    }
    deinit {
        state.condition.lock()
        state.stopping = true
        state.condition.broadcast()
        state.condition.unlock()
    }
}

package final class AutomationIPC: @unchecked Sendable {
    package enum Failure: LocalizedError {
        case busy, timeout, open, invalidated
        package var errorDescription: String? {
            switch self {
            case .busy: return "터미널 자동화가 사용 중입니다. 잠시 후 다시 확인해주세요."
            case .timeout,.open: return "터미널 자동화 응답이 지연되어 일시 중단했습니다. 대기 중인 요청은 원본 터미널에서 직접 확인해주세요."
            case .invalidated: return "자동화 대상 또는 요청 상태가 변경되었습니다."
            }
        }
    }
    package struct Metrics: Codable, Sendable {
        package var inFlight = 0
        var peak = 0, rejected = 0, timeouts = 0, cancelled = 0
        package var late = 0
        var admitted = 0, permissions = 0, permissionHits = 0, permissionJoined = 0
        var activeHosts: [String] = [], openHosts: [String] = []
        var p50MS: Double = 0, p95MS: Double = 0, p99MS: Double = 0
    }
    private class Flight {
        let id = UUID()
        let start = ProcessInfo.processInfo.systemUptime
        let deadline: TimeInterval
        var failed: Failure?
        var readOnly = false
        init(_ budget: TimeInterval) { deadline = start + budget }
    }
    private final class ResultFlight<Value>: Flight, @unchecked Sendable {
        let finished = DispatchGroup()
        var result: Result<Value, Error>?
        init(budget: TimeInterval) { super.init(budget); finished.enter() }
    }
    static let shared = AutomationIPC()
    private let workers = IPCWorkers()
    private let threadKey = UUID().uuidString
    private let lock = NSLock()
    private var active: [String:Flight] = [:]
    private var reopen: [String:TimeInterval] = [:]
    private var metrics = Metrics()
    private var durations: [Double] = []
    private let cooldown: TimeInterval
    private var permissions: [String:(key:String,status:OSStatus,until:TimeInterval)] = [:]
    private var probes: [String:(key:String,flight:ResultFlight<OSStatus>)] = [:]
    package init(cooldown: TimeInterval = 15) { self.cooldown = cooldown }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private func expire(_ host:String, _ flight: Flight, _ reason: Failure) {
        guard active[host] === flight, flight.failed == nil else { return }
        flight.failed = reason
        reopen[host] = now + cooldown
        permissions.removeValue(forKey:host)
        if reason == .timeout { metrics.timeouts += 1 } else { metrics.cancelled += 1 }
    }
    private func reserve<T>(_ host:String, readOnly:Bool, budget:TimeInterval, body:@escaping () throws -> T) throws -> ResultFlight<T> {
        if let current = active[host], now >= current.deadline { expire(host,current,.timeout) }
        if let time = reopen[host], !readOnly || now < time || active[host] != nil { metrics.rejected += 1; throw Failure.open }
        guard active.count < 2, active[host] == nil else { metrics.rejected += 1; throw Failure.busy }
        let flight = ResultFlight<T>(budget:budget)
        flight.readOnly = readOnly
        active[host] = flight
        metrics.admitted += 1
        metrics.peak = max(metrics.peak,active.count)
        workers.submit { [self] in
            Thread.current.threadDictionary[threadKey] = flight
            defer { Thread.current.threadDictionary.removeObject(forKey:threadKey) }
            Thread.current.name = "AutoApprove IPC " + host
            let result: Result<T,Error> = autoreleasepool {
                Result {
                    try lock.withLock {
                        if now >= flight.deadline { expire(host,flight,.timeout) }
                        if let failure = flight.failed { throw failure }
                    }
                    return try body()
                }
            }
            lock.withLock {
                if now >= flight.deadline { expire(host,flight,.timeout) }
                if let failure = flight.failed {
                    flight.result = .failure(failure); metrics.late += 1
                    if failure == .invalidated && now < flight.deadline { reopen.removeValue(forKey:host) }
                }
                else {
                    flight.result = result
                    switch result {
                    case .success: if probes[host]?.flight.id != flight.id { reopen.removeValue(forKey:host) }
                    case .failure(let error):
                        if (error as NSError).code == -1712 || reopen[host] != nil { reopen[host] = now + cooldown }
                        permissions.removeValue(forKey:host)
                    }
                }
                durations.append((now-flight.start)*1000)
                if durations.count > 256 { durations.removeFirst() }
                active.removeValue(forKey:host)
                if let probe = probes[host], probe.flight.id == flight.id {
                    if case .success(let status) = probe.flight.result { permissions[host] = (probe.key,status,now+0.5) }
                    probes.removeValue(forKey:host)
                }
                flight.finished.leave()
            }
        }
        return flight
    }
    private func wait<T>(_ flight:ResultFlight<T>, host:String) throws -> T {
        while true {
            if let result = lock.withLock({ () -> Result<T,Error>? in
                if Task.isCancelled { expire(host,flight,.invalidated) }
                if now >= flight.deadline { expire(host,flight,.timeout) }
                if let failure = flight.failed { return .failure(failure) }
                return flight.result
            }) { return try result.get() }
            _ = flight.finished.wait(timeout:.now() + min(0.025,max(0,flight.deadline-now)))
        }
    }
    package func run<T>(host:String,readOnly:Bool,budget:TimeInterval,body:@escaping () throws -> T) throws -> T {
        try Task.checkCancellation()
        if let parent = Thread.current.threadDictionary[threadKey] as? Flight {
            try lock.withLock {
                guard active[host] === parent, readOnly || !parent.readOnly else { throw Failure.busy }
                if now >= parent.deadline { expire(host,parent,.timeout) }
                if let failure = parent.failed { throw failure }
            }
            let end = min(parent.deadline,now+budget)
            let result = Result { try body() }
            try lock.withLock {
                if now >= end { expire(host,parent,.timeout) }
                if case .failure(let error) = result, (error as NSError).code == -1712 { expire(host,parent,.timeout) }
                if let failure = parent.failed { throw failure }
            }
            return try result.get()
        }
        guard !Thread.isMainThread || Bundle.main.bundleIdentifier != "local.autoapprove.mac" else { throw Failure.busy }
        let flight = try lock.withLock { try reserve(host,readOnly:readOnly,budget:budget,body:body) }
        return try wait(flight,host:host)
    }
    package func read<T>(host:String,budget:TimeInterval = 5,body:@escaping () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let flight = try lock.withLock { try reserve(host,readOnly:true,budget:budget,body:body) }
        do {
            while true {
                try Task.checkCancellation()
                if let result = lock.withLock({ () -> Result<T,Error>? in
                    if now >= flight.deadline { expire(host,flight,.timeout) }
                    if let failure = flight.failed { return .failure(failure) }
                    return flight.result
                }) { return try result.get() }
                try await Task.sleep(for:.milliseconds(8))
            }
        } catch is CancellationError {
            lock.withLock { expire(host,flight,.invalidated) }
            throw CancellationError()
        }
    }

    func blocksWrites(_ host:String) -> Bool {
        lock.withLock {
            if let flight = active[host], now >= flight.deadline { expire(host,flight,.timeout) }
            return reopen[host] != nil
        }
    }
    package func permission(host:String,key:String,cacheOnly:Bool,query:@escaping () -> OSStatus) throws -> OSStatus? {
        try Task.checkCancellation()
        lock.lock()
        if let value = permissions[host], value.key == key, now < value.until, now >= (reopen[host] ?? 0) {
            metrics.permissionHits += 1; lock.unlock(); return value.status
        }
        if let parent = Thread.current.threadDictionary[threadKey] as? Flight, active[host] === parent {
            lock.unlock()
            let status = try run(host:host,readOnly:true,budget:2,body:query)
            lock.withLock {
                if parent.failed == nil && now < parent.deadline { permissions[host] = (key,status,now+0.5) }
                metrics.permissions += 1
            }
            return status
        }
        if let existing = probes[host], existing.key == key {
            if now >= existing.flight.deadline { expire(host,existing.flight,.timeout) }
            metrics.permissionJoined += 1
            let failure = existing.flight.failed
            lock.unlock()
            if let failure { throw failure }
            return nil
        }
        let flight: ResultFlight<OSStatus>
        do {
            flight = try reserve(host,readOnly:true,budget:2,body:query)
            probes[host] = (key,flight)
            metrics.permissions += 1
        } catch { lock.unlock(); throw error }
        lock.unlock()
        if cacheOnly { return nil }
        return try wait(flight,host:host)
    }
    package func invalidate(_ host:String) {
        lock.withLock {
            permissions.removeValue(forKey:host)
            if let flight = active[host] { expire(host,flight,.invalidated) }
        }
    }
    func revokePermission(_ host:String) { lock.withLock { _ = permissions.removeValue(forKey:host) } }
    package func snapshot() -> Metrics {
        lock.withLock {
            for (host,flight) in active where now >= flight.deadline { expire(host,flight,.timeout) }
            var result = metrics
            result.activeHosts = active.keys.sorted(); result.inFlight = active.count; result.openHosts = reopen.keys.sorted()
            let sorted = durations.sorted()
            if !sorted.isEmpty {
                result.p50MS = sorted[(sorted.count-1)/2]; result.p95MS = sorted[(sorted.count-1)*95/100]; result.p99MS = sorted[(sorted.count-1)*99/100]
            }
            return result
        }
    }
}

enum HostAutomationPermission {
    static func check(_ host:ScreenHost) async throws -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier:host.bundleID).first else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        repeat {
            try Task.checkCancellation()
            do {
                if let status = try status(host,application:app,eventClass:typeWildCard,eventID:typeWildCard,cacheOnly:true) {
                    if status == noErr { return true }
                    if [errAEEventNotPermitted,errAEEventWouldRequireUserConsent].contains(Int(status)) { return false }
                    throw NSError(domain:NSOSStatusErrorDomain,code:Int(status))
                }
            } catch AutomationIPC.Failure.busy {}
            try await Task.sleep(for:.milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw AutomationIPC.Failure.timeout
    }
    static func request(_ host:ScreenHost) throws {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier:host.bundleID).first else { return }
        let status = try AutomationIPC.shared.run(host:host.title,readOnly:false,budget:45) {
            guard !app.isTerminated else { throw AutomationIPC.Failure.invalidated }
            let target = NSAppleEventDescriptor(processIdentifier:app.processIdentifier)
            return AEDeterminePermissionToAutomateTarget(target.aeDesc,typeWildCard,typeWildCard,true)
        }
        AutomationIPC.shared.revokePermission(host.title)
        guard status == noErr else { throw TerminalAdapterError.automationDenied(host.title) }
    }

    static func status(_ host:ScreenHost, application:NSRunningApplication, eventClass:AEEventClass, eventID:AEEventID, cacheOnly:Bool) throws -> OSStatus? {
        let pid = application.processIdentifier
        guard pid > 0, !application.isTerminated else { throw AutomationIPC.Failure.invalidated }
        let key = "\(pid):\(application.launchDate?.timeIntervalSince1970 ?? 0):\(eventClass):\(eventID)"
        return try AutomationIPC.shared.permission(host:host.title,key:key,cacheOnly:cacheOnly) {
            guard !application.isTerminated else { return OSStatus(procNotFound) }
            let target = NSAppleEventDescriptor(processIdentifier:pid)
            let status = AEDeterminePermissionToAutomateTarget(target.aeDesc,eventClass,eventID,false)
            return application.isTerminated ? OSStatus(procNotFound) : status
        }
    }
}
