import Foundation
import AppKit
import Carbon

private func aeCode(_ text: String) -> OSType { text.utf8.reduce(0) { ($0 << 8) | OSType($1) } }

private enum TerminalReadEventError: Error {
    case incompatible, timedOut, ambiguous
}

/// Read-only Terminal dictionary queries. Content batches contain only requested
/// exact TTY predicates and are accepted only while their TTY order stays stable;
/// individual fallback queries also carry an exact predicate. No tab index,
/// screen or process identity is cached. The injected transport keeps the
/// descriptor contract testable without sending Apple events.
public struct TerminalAppleEventReader {
    public typealias Sender = (NSAppleEventDescriptor, TimeInterval) throws -> NSAppleEventDescriptor
    private let send: Sender
    private let clock: () -> TimeInterval
    private let timeout: TimeInterval
    private let batchTitles: Bool
    private let batchContents: Bool
    private let titleBatchUnavailable: () -> Void
    private let contentsBatchUnavailable: () -> Void
    private let slowContentsBatch: () -> Void
    private let slowTitlesBatch: () -> Void
    private let diagnostics: RemoteTerminalPerformance?
    private let purpose: RemoteTerminalPerformance.NativePurpose
    private static let slowBatchThreshold: TimeInterval = 1.5

    public init(timeout: TimeInterval = 8, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                batchTitles: Bool = true, titleBatchUnavailable: @escaping () -> Void = {},
                batchContents: Bool = true, contentsBatchUnavailable: @escaping () -> Void = {},
                slowContentsBatch: @escaping () -> Void = {},
                slowTitlesBatch: @escaping () -> Void = {},
                diagnostics: RemoteTerminalPerformance? = nil, purpose: RemoteTerminalPerformance.NativePurpose = .other,
                send: @escaping Sender) {
        self.timeout = timeout; self.clock = clock; self.send = send
        self.batchTitles = batchTitles; self.titleBatchUnavailable = titleBatchUnavailable
        self.batchContents = batchContents; self.contentsBatchUnavailable = contentsBatchUnavailable
        self.slowContentsBatch = slowContentsBatch; self.slowTitlesBatch = slowTitlesBatch
        self.diagnostics = diagnostics; self.purpose = purpose
    }

    private func object(_ kind: String, form: String, selector: NSAppleEventDescriptor, container: NSAppleEventDescriptor = .null()) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(.init(typeCode: aeCode(kind)), forKeyword: aeCode("want"))
        record.setDescriptor(.init(enumCode: aeCode(form)), forKeyword: aeCode("form"))
        record.setDescriptor(selector, forKeyword: aeCode("seld"))
        record.setDescriptor(container, forKeyword: aeCode("from"))
        guard let descriptor = record.coerce(toDescriptorType: aeCode("obj ")) else { throw TerminalReadEventError.incompatible }
        return descriptor
    }

    private func property(_ name: String, of container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try object("prop", form: "prop", selector: .init(typeCode: aeCode(name)), container: container)
    }

    private func matching(_ kind: String, property path: [String], tty: String, container: NSAppleEventDescriptor = .null()) throws -> NSAppleEventDescriptor {
        try matching(kind, property: path, ttys: [tty], container: container)
    }

    private func matching(_ kind: String, property path: [String], ttys: [String], container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        guard var left = NSAppleEventDescriptor(descriptorType: aeCode("exmn"), data: Data()) else { throw TerminalReadEventError.incompatible }
        for name in path { left = try property(name, of: left) }
        let terms = NSAppleEventDescriptor.list()
        for tty in ttys {
            let comparison = NSAppleEventDescriptor.record()
            comparison.setDescriptor(.init(enumCode: aeCode("=   ")), forKeyword: aeCode("relo"))
            comparison.setDescriptor(left, forKeyword: aeCode("obj1"))
            comparison.setDescriptor(.init(string: tty), forKeyword: aeCode("obj2"))
            guard let term = comparison.coerce(toDescriptorType: aeCode("cmpd")) else { throw TerminalReadEventError.incompatible }
            terms.insert(term, at: terms.numberOfItems + 1)
        }
        let test: NSAppleEventDescriptor
        if terms.numberOfItems == 1 { test = terms.atIndex(1)! }
        else {
            let logical = NSAppleEventDescriptor.record()
            logical.setDescriptor(.init(enumCode: aeCode("OR  ")), forKeyword: aeCode("logc"))
            logical.setDescriptor(terms, forKeyword: aeCode("term"))
            guard let value = logical.coerce(toDescriptorType: aeCode("logi")) else { throw TerminalReadEventError.incompatible }
            test = value
        }
        return try object(kind, form: "test", selector: test, container: container)
    }

    private func strings(_ value: NSAppleEventDescriptor, depth: Int = 0) throws -> [String] {
        guard depth < 8, value.numberOfItems <= 4096 else { throw TerminalReadEventError.incompatible }
        if value.descriptorType == aeCode("list") {
            guard value.numberOfItems > 0 else { return [] }
            return try (1...value.numberOfItems).flatMap { index in
                guard let item = value.atIndex(index) else { throw TerminalReadEventError.incompatible }
                return try strings(item, depth: depth + 1)
            }
        }
        guard ["utxt", "utf8", "TEXT"].contains(where: { value.descriptorType == aeCode($0) }),
              let text = value.stringValue else { throw TerminalReadEventError.incompatible }
        return [text]
    }

    private func windowIDs(_ value: NSAppleEventDescriptor, depth: Int = 0) throws -> [UInt32] {
        guard depth < 8, value.numberOfItems <= 4096 else { throw TerminalReadEventError.incompatible }
        if value.descriptorType == aeCode("list") {
            guard value.numberOfItems > 0 else { return [] }
            return try (1...value.numberOfItems).flatMap { index in
                guard let item = value.atIndex(index) else { throw TerminalReadEventError.incompatible }
                return try windowIDs(item, depth: depth + 1)
            }
        }
        guard value.descriptorType == aeCode("long"), value.int32Value > 0 else { throw TerminalReadEventError.incompatible }
        return [UInt32(value.int32Value)]
    }

    /// First frames need only contents. Live frames may obtain the selected
    /// window's ID in one exact-TTY event, without a JXA process or a
    /// scan of unrelated titles. The callback independently verifies visibility.
    public func screens(ttys: [String], includeTitles: Bool = true, titleTTYS: [String]? = nil,
                        presentation: ((String, UInt32) -> TerminalTextSnapshot?)? = nil) throws -> TerminalSnapshot {
        try autoreleasepool {
            guard !ttys.isEmpty else { return TerminalSnapshot() }
            var seen = Set<String>()
            let targets = ttys.filter { seen.insert($0).inserted }
            var seenTitles = Set<String>()
            let titleTargets = (titleTTYS ?? targets).filter { seen.contains($0) && seenTitles.insert($0).inserted }
            let deadline = clock() + max(0, timeout)
            func recordSlowBatch(_ started: TimeInterval?, query: RemoteTerminalPerformance.NativeQuery) {
                guard let started, clock() - started >= Self.slowBatchThreshold else { return }
                if query == .bulkContentsBefore { slowContentsBatch() }
                else { slowTitlesBatch() }
            }
            func getValue(_ subject: NSAppleEventDescriptor, _ query: RemoteTerminalPerformance.NativeQuery) throws -> NSAppleEventDescriptor {
                try Task.checkCancellation()
                let remaining = deadline - clock()
                guard remaining > 0.02 else { throw TerminalReadEventError.timedOut }
                let isContentsBatch = query == .bulkContentsBefore
                let isTitlesBatch = query == .bulkBefore || query == .bulkTitle || query == .bulkAfter
                let started = isContentsBatch || isTitlesBatch ? clock() : nil
                do {
                    let value: NSAppleEventDescriptor
                    if let diagnostics {
                        value = try diagnostics.measureNativeQuery(purpose:purpose,query:query,targets:targets.count,remaining:remaining,
                            reply:{ .init(kind:$0.descriptorType,items:$0.numberOfItems) }) { try send(subject,remaining) }
                    } else { value = try send(subject, remaining) }
                    recordSlowBatch(started, query: query)
                    return value
                } catch {
                    recordSlowBatch(started, query: query)
                    throw error
                }
            }
            func get(_ subject: NSAppleEventDescriptor, _ query: RemoteTerminalPerformance.NativeQuery) throws -> [String] {
                try strings(getValue(subject,query))
            }
            // An absolute ordinal has type 'abso', not a generic enumeration.
            guard let all = NSAppleEventDescriptor(descriptorType: aeCode("abso"), data: NSAppleEventDescriptor(enumCode: aeCode("all ")).data) else {
                throw TerminalReadEventError.incompatible
            }
            let windows = try object("cwin", form: "indx", selector: all)
            var result = TerminalSnapshot()
            var titlesByTTY: [String: String] = [:]
            var contentsByTTY: [String: String]?
            var titleReadTimedOut = false
            // An exact TTY predicate is part of its single get event. A stable
            // batch needs three events regardless of size, so it saves events
            // only from four targets onward; keep tiny reads individual.
            if batchContents, targets.count >= 4, targets.count <= 256 {
                do {
                    let tabs = try matching("ttab", property: ["ttty"], ttys: targets, container: windows)
                    let values = try RemoteTerminalPerformance.shared.measure(.terminalContents) { () -> [String: String] in
                        let before = try getValue(property("ttty", of: tabs), .bulkContentsBefore)
                        let contents = try get(property("pcnt", of: tabs), .bulkContents)
                        let after = try getValue(property("ttty", of: tabs), .bulkContentsAfter)
                        let selected = try strings(before)
                        guard before.descriptorType == after.descriptorType, before.data == after.data,
                              selected.count == contents.count, Set(selected).count == selected.count,
                              selected.allSatisfy({ seen.contains($0) }) else { return [:] }
                        return Dictionary(uniqueKeysWithValues: zip(selected, contents))
                    }
                    // A structurally invalid or partial batch must not be
                    // retried on every monitor pass. Empty terminal contents
                    // still have a TTY key, so an empty/partial map means the
                    // batch identity check failed; exact-TTY reads below stay
                    // authoritative for this pass.
                    if values.count == targets.count && Set(values.keys) == Set(targets) {
                        contentsByTTY = values
                    } else {
                        contentsBatchUnavailable()
                    }
                } catch {
                    let status = (error as NSError).code
                    if [-1743, -1744].contains(status) { throw TerminalAdapterError.permissionDenied }
                    if status == -1712 { throw TerminalReadEventError.timedOut }
                    if error is TerminalAdapterError || error is CancellationError { throw error }
                    if case TerminalReadEventError.timedOut = error { throw error }
                    if case TerminalReadEventError.incompatible = error { contentsBatchUnavailable() }
                    else if [-1700, -1708].contains(status) { contentsBatchUnavailable() }
                    else if status != -1728 { throw error }
                }
            }
            // Like screen contents, title matching is encoded in each exact
            // get event. Batch only when four or more stale labels amortize the
            // stable three-event identity check.
            if includeTitles, batchTitles, titleTargets.count >= 4, titleTargets.count <= 256 {
                do {
                    // Read only requested tabs' presentation metadata. Contents
                    // and input binding still use their own exact-TTY predicate.
                    let tabs = try matching("ttab", property: ["ttty"], ttys: titleTargets, container: windows)
                    let values = try RemoteTerminalPerformance.shared.measure(.terminalMetadata) { () -> [String: String] in
                        let before = try getValue(property("ttty", of: tabs),.bulkBefore)
                        let names = try get(property("titl", of: tabs),.bulkTitle)
                        let after = try getValue(property("ttty", of: tabs),.bulkAfter)
                        let selected = try strings(before)
                        guard before.descriptorType == after.descriptorType, before.data == after.data,
                              selected.count == names.count, Set(selected).count == selected.count,
                              selected.allSatisfy({ titleTargets.contains($0) }) else { return [:] }
                        return Dictionary(uniqueKeysWithValues: zip(selected, names))
                    }
                    if values.count == titleTargets.count && Set(values.keys) == Set(titleTargets) {
                        titlesByTTY = values
                    } else {
                        // Optional labels can fall back to exact reads once;
                        // remember an incompatible batch for this Terminal PID.
                        titleBatchUnavailable()
                    }
                } catch {
                    let status = (error as NSError).code
                    if [-1743, -1744].contains(status) { throw TerminalAdapterError.permissionDenied }
                    // Titles are presentation metadata. A slow title query must
                    // never discard fresh terminal contents or block approvals.
                    if status == -1712 { titleReadTimedOut = true }
                    if error is TerminalAdapterError || error is CancellationError { throw error }
                    if case TerminalReadEventError.timedOut = error { titleReadTimedOut = true }
                    if case TerminalReadEventError.incompatible = error { titleBatchUnavailable(); titleReadTimedOut = true }
                    else if [-1700, -1708].contains(status) { titleBatchUnavailable(); titleReadTimedOut = true }
                    else if status != -1728 && status != -1712 && !(error is TerminalReadEventError) { throw error }
                    // Unsupported bulk metadata does not disable the native
                    // exact contents reader or start a second script process.
                }
            }
            for tty in targets {
                do {
                    let tab = try matching("ttab", property: ["ttty"], tty: tty, container: windows)
                    let contents: [String]
                    if let batched = contentsByTTY?[tty] { contents = [batched] }
                    else {
                        contents = try RemoteTerminalPerformance.shared.measure(.terminalContents) { try get(property("pcnt", of: tab),.text) }
                    }
                    guard contents.count <= 1 else { throw TerminalReadEventError.ambiguous }
                    guard let screen = contents.first else { continue }
                    var title: String?
                    if includeTitles && !titleReadTimedOut && titleTargets.contains(tty) { do {
                        let titles = try titlesByTTY[tty].map { [$0] } ?? RemoteTerminalPerformance.shared.measure(.terminalMetadata) { try get(property("titl", of: tab),.customTitle) }
                        if titles.count == 1 { title = titles[0].trimmingCharacters(in: .whitespacesAndNewlines) }
                    } catch {
                        // A title may disappear after the screen was read. The
                        // contents still came from this exact TTY, not a neighbour.
                        // Optional metadata failure never invalidates that fresh read.
                        if error is TerminalAdapterError || error is CancellationError { throw error }
                        if error is TerminalReadEventError { titleReadTimedOut = true }
                        let status = (error as NSError).code
                        if status == -1712 { titleReadTimedOut = true }
                        if !(error is TerminalReadEventError), ![-1728, -1712].contains(status) { throw error }
                    } }
                    var output = TerminalScreen(tty: tty, contents: screen, title: title?.isEmpty == false ? title : nil)
                    if let presentation {
                        let selectedWindow = try matching("cwin", property: ["tcnt", "ttty"], tty: tty)
                        let ids = try RemoteTerminalPerformance.shared.measure(.terminalMetadata) { try getValue(property("ID  ", of: selectedWindow),.selectedWindow) }
                        var displays: [(UInt32, TerminalTextSnapshot)] = []
                        for id in Set(try windowIDs(ids)) {
                            try Task.checkCancellation()
                            if let display = presentation(screen, id) { displays.append((id, display)) }
                        }
                        // Native tab groups expose hidden virtual windows too.
                        // Never choose an arbitrary match or infer a cursor.
                        if displays.count == 1 {
                            let confirmed = try RemoteTerminalPerformance.shared.measure(.terminalMetadata) { try windowIDs(getValue(property("ID  ", of: selectedWindow),.selectedConfirm)) }
                            if confirmed.contains(displays[0].0) {
                                output.display = displays[0].1
                                if displays[0].1.screen == screen { output.cursor = displays[0].1.cursor }
                            }
                        }
                    }
                    result.screens.append(output)
                } catch {
                    if error is TerminalAdapterError || error is CancellationError { throw error }
                    if case TerminalReadEventError.incompatible = error { throw error }
                    if case TerminalReadEventError.timedOut = error { throw error }
                    let status = (error as NSError).code
                    if status == -1743 { throw TerminalAdapterError.permissionDenied }
                    if [-1700, -1708].contains(status) { throw TerminalReadEventError.incompatible }
                    if status == -1712 { throw TerminalReadEventError.timedOut }
                    result.failures.append(TerminalReadFailure(tty: tty, message: "원본 Terminal 탭을 읽지 못했습니다. (\(status))"))
                }
            }
            if includeTitles, result.screens.contains(where: { titleTargets.contains($0.tty) && $0.title == nil }) {
                do {
                    let before = try getValue(property("ID  ", of: windows),.windowBefore)
                    let selected = try get(property("ttty", of: property("tcnt", of: windows)),.windowSelection)
                    let names = try get(property("pnam", of: windows),.windowName)
                    let after = try getValue(property("ID  ", of: windows),.windowAfter)
                    // Pair names only while the window identity/order is stable.
                    // This is presentation metadata, never an input binding.
                    if before.descriptorType == aeCode("list"), after.descriptorType == aeCode("list"),
                       before.data == after.data, before.numberOfItems == selected.count, selected.count == names.count {
                        for index in result.screens.indices where titleTargets.contains(result.screens[index].tty) && result.screens[index].title == nil {
                            let matches = selected.indices.filter { selected[$0] == result.screens[index].tty }
                            if matches.count == 1 {
                                let name = names[matches[0]].trimmingCharacters(in: .whitespacesAndNewlines)
                                result.screens[index].title = name.isEmpty ? nil : name
                            }
                        }
                    }
                } catch {
                    let status = (error as NSError).code
                    if status == -1743 { throw TerminalAdapterError.permissionDenied }
                    if [-1700, -1708].contains(status) { throw TerminalReadEventError.incompatible }
                    if status == -1712 { throw TerminalReadEventError.timedOut }
                    if error is TerminalAdapterError || error is CancellationError || error is TerminalReadEventError { throw error }
                    if status != -1728 { throw error }
                }
            }
            return result
        }
    }
}

enum TerminalAppleEvents {
    private static let lock = NSLock()
    private struct CachedTitle {
        let value: String?
        let at: TimeInterval
    }
    private static var incompatiblePID: pid_t?
    private static var incompatiblePresentationPID: pid_t?
    private static var incompatibleTitlesPID: pid_t?
    private static var incompatibleContentsPID: pid_t?
    private static var slowContentsBatchPID: pid_t?
    private static var slowContentsBatchUntil: TimeInterval = 0
    private static var slowTitlesBatchPID: pid_t?
    private static var slowTitlesBatchUntil: TimeInterval = 0
    private static var titleCachePID: pid_t?
    private static var titlesByTTY: [String: CachedTitle] = [:]
    // Titles only label the session list; approval and input always use fresh
    // contents. A five-minute label refresh avoids optional Apple Events on the
    // frequent monitor cadence, which can stall on busy Terminal. Newly seen
    // or expired TTYs alone enter the title query set.
    private static let titleCacheLifetime: TimeInterval = 300

    /// nil uses the existing script's initial consent/compatibility path. A
    /// revoked permission or timeout never starts a second read or launches Terminal.
    static func screens(ttys: [String], includeTitles: Bool = true, includeCursor: Bool = false,
                        preflight: Bool = true, purpose: RemoteTerminalPerformance.NativePurpose = .other) throws -> TerminalSnapshot? {
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first else {
            throw AppError.message("Terminal 앱을 먼저 실행해주세요.")
        }
        guard !ttys.isEmpty else { return TerminalSnapshot() }
        let pid = application.processIdentifier
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if titleCachePID != pid {
            titleCachePID = pid; titlesByTTY.removeAll(keepingCapacity: true)
            slowContentsBatchPID = nil; slowContentsBatchUntil = 0
            slowTitlesBatchPID = nil; slowTitlesBatchUntil = 0
        }
        let unsupported = incompatiblePID == pid || (includeCursor && incompatiblePresentationPID == pid)
        // Terminal's multi-tab title batch has shown multi-second tail latency.
        // Keep batches for explicit presentation reads, but scope optional
        // monitor metadata to exact TTYs.
        let batchTitles = incompatibleTitlesPID != pid && purpose != .monitor
        let slowContentsFallback = slowContentsBatchPID == pid && now < slowContentsBatchUntil
        let slowTitlesFallback = slowTitlesBatchPID == pid && now < slowTitlesBatchUntil
        let suppressTitleReads = slowContentsFallback || slowTitlesFallback
        let batchContents = incompatibleContentsPID != pid && !slowContentsFallback
        let uniqueTTYS = Set(ttys)
        let titleTargets = includeTitles ? uniqueTTYS.filter {
            titlesByTTY[$0].map { now - $0.at >= titleCacheLifetime } ?? true
        } : []
        let cachedTitles: [String: String?] = Dictionary(uniqueKeysWithValues: uniqueTTYS.compactMap { tty in
            titlesByTTY[tty].map { (tty, $0.value) }
        })
        lock.unlock()
        if unsupported { return nil }
        // Never request a new permission from a background read. Explicit setup
        // retains the existing osascript consent behaviour if it is needed.
        if preflight {
            let access = readAccess(pid: pid)
            if access == errAEEventNotPermitted { throw TerminalAdapterError.permissionDenied }
            if access == errAEEventWouldRequireUserConsent { return nil }
            guard access == noErr else { throw AppError.message("Terminal 자동화 상태를 확인하지 못했습니다. (\(access))") }
        }
        let reader = TerminalAppleEventReader(batchTitles: batchTitles, titleBatchUnavailable: {
            lock.lock(); incompatibleTitlesPID = pid; lock.unlock()
        }, batchContents: batchContents, contentsBatchUnavailable: {
            lock.lock(); incompatibleContentsPID = pid; lock.unlock()
        }, slowContentsBatch: {
            lock.lock()
            slowContentsBatchPID = pid
            slowContentsBatchUntil = ProcessInfo.processInfo.systemUptime + 60
            lock.unlock()
        }, slowTitlesBatch: {
            lock.lock()
            slowTitlesBatchPID = pid
            slowTitlesBatchUntil = ProcessInfo.processInfo.systemUptime + 60
            lock.unlock()
        }, diagnostics: .shared, purpose: purpose) { subject, timeout in
            let event = NSAppleEventDescriptor(eventClass: aeCode("core"), eventID: aeCode("getd"),
                targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid), returnID: -1, transactionID: 0)
            event.setParam(subject, forKeyword: aeCode("----"))
            let reply: NSAppleEventDescriptor
            let noConsent = NSAppleEventDescriptor.SendOptions(rawValue: UInt(kAEDoNotPromptForUserConsent))
            do { reply = try event.sendEvent(options: [.waitForReply, .neverInteract, noConsent], timeout: timeout) }
            catch {
                if [-1743, -1744].contains((error as NSError).code) { throw TerminalAdapterError.permissionDenied }
                throw error
            }
            let status = reply.paramDescriptor(forKeyword: aeCode("errn"))?.int32Value ?? 0
            if [-1743, -1744].contains(status) { throw TerminalAdapterError.permissionDenied }
            guard status == 0 else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
            guard let value = reply.paramDescriptor(forKeyword: aeCode("----")) else { throw TerminalReadEventError.incompatible }
            return value
        }
        do {
            var snapshot = try reader.screens(ttys: ttys, includeTitles: includeTitles && !titleTargets.isEmpty && !suppressTitleReads,
                titleTTYS: titleTargets,
                presentation: includeCursor ? { TerminalCursorReader.snapshot(screen: $0, windowID: $1) } : nil)
            guard includeTitles else { return snapshot }
            let recordedAt = ProcessInfo.processInfo.systemUptime
            lock.lock()
            for index in snapshot.screens.indices {
                let tty = snapshot.screens[index].tty
                if let value = snapshot.screens[index].title {
                    titlesByTTY[tty] = CachedTitle(value:value,at:recordedAt)
                } else if titleTargets.contains(tty), !suppressTitleReads {
                    // A failed optional title read stays cached for the same
                    // lifetime; it must not trigger a slow retry on every
                    // screen poll. Keep any older label while it expires.
                    titlesByTTY[tty] = CachedTitle(value:cachedTitles[tty] ?? nil,at:recordedAt)
                }
                snapshot.screens[index].title = snapshot.screens[index].title ?? cachedTitles[tty] ?? nil
            }
            if titlesByTTY.count > 512 {
                titlesByTTY = titlesByTTY.filter { recordedAt - $0.value.at < titleCacheLifetime * 2 }
            }
            lock.unlock()
            return snapshot
        }
        catch TerminalReadEventError.incompatible {
            lock.lock()
            if includeCursor { incompatiblePresentationPID = pid } else { incompatiblePID = pid }
            lock.unlock()
            return nil
        }
        catch TerminalReadEventError.timedOut { throw AppError.message("Terminal 화면 조회 시간이 초과되었습니다.") }
    }
    /// A compatibility read must obtain a fresh result; no completed grant is cached.
    static func readPermission() throws -> Bool {
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first else {
            throw AppError.message("Terminal 앱을 먼저 실행해주세요.")
        }
        let access = readAccess(pid: application.processIdentifier)
        if access == errAEEventNotPermitted || access == errAEEventWouldRequireUserConsent { return false }
        guard access == noErr else { throw AppError.message("Terminal 자동화 상태를 확인하지 못했습니다. (\(access))") }
        return true
    }
    private static func readAccess(pid: pid_t) -> OSStatus {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc!, aeCode("core"), aeCode("getd"), false)
    }
}
