import Foundation
import AppKit
import Carbon

private func aeCode(_ text: String) -> OSType { text.utf8.reduce(0) { ($0 << 8) | OSType($1) } }

private enum TerminalReadEventError: Error {
    case incompatible, timedOut, ambiguous
}

/// Read-only Terminal dictionary queries. Each contents query contains its own
/// exact TTY predicate; no tab index, screen or process identity is cached.
/// The injected transport keeps the wire contract testable without Apple events.
public struct TerminalAppleEventReader {
    public typealias Sender = (NSAppleEventDescriptor, TimeInterval) throws -> NSAppleEventDescriptor
    private let send: Sender
    private let clock: () -> TimeInterval
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 8, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, send: @escaping Sender) {
        self.timeout = timeout; self.clock = clock; self.send = send
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
        guard var left = NSAppleEventDescriptor(descriptorType: aeCode("exmn"), data: Data()) else { throw TerminalReadEventError.incompatible }
        for name in path { left = try property(name, of: left) }
        let comparison = NSAppleEventDescriptor.record()
        comparison.setDescriptor(.init(enumCode: aeCode("=   ")), forKeyword: aeCode("relo"))
        comparison.setDescriptor(left, forKeyword: aeCode("obj1"))
        comparison.setDescriptor(.init(string: tty), forKeyword: aeCode("obj2"))
        guard let test = comparison.coerce(toDescriptorType: aeCode("cmpd")) else { throw TerminalReadEventError.incompatible }
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
    public func screens(ttys: [String], includeTitles: Bool = true,
                        presentation: ((String, UInt32) -> TerminalTextSnapshot?)? = nil) throws -> TerminalSnapshot {
        try autoreleasepool {
            guard !ttys.isEmpty else { return TerminalSnapshot() }
            let deadline = clock() + max(0, timeout)
            func getValue(_ subject: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
                try Task.checkCancellation()
                let remaining = deadline - clock()
                guard remaining > 0.02 else { throw TerminalReadEventError.timedOut }
                return try send(subject, remaining)
            }
            func get(_ subject: NSAppleEventDescriptor) throws -> [String] {
                try strings(getValue(subject))
            }
            // An absolute ordinal has type 'abso', not a generic enumeration.
            guard let all = NSAppleEventDescriptor(descriptorType: aeCode("abso"), data: NSAppleEventDescriptor(enumCode: aeCode("all ")).data) else {
                throw TerminalReadEventError.incompatible
            }
            let windows = try object("cwin", form: "indx", selector: all)
            var result = TerminalSnapshot(), seen = Set<String>()
            for tty in ttys where seen.insert(tty).inserted {
                do {
                    let tab = try matching("ttab", property: ["ttty"], tty: tty, container: windows)
                    let contents = try RemoteTerminalPerformance.shared.measure(.terminalContents) { try get(property("pcnt", of: tab)) }
                    guard contents.count <= 1 else { throw TerminalReadEventError.ambiguous }
                    guard let screen = contents.first else { continue }
                    var title: String?
                    if includeTitles { do {
                        let titles = try RemoteTerminalPerformance.shared.measure(.terminalMetadata) { try get(property("titl", of: tab)) }
                        if titles.count == 1 { title = titles[0].trimmingCharacters(in: .whitespacesAndNewlines) }
                    } catch {
                        // A title may disappear after the screen was read. The
                        // contents still came from this exact TTY, not a neighbour.
                        if error is TerminalAdapterError || error is CancellationError || error is TerminalReadEventError { throw error }
                        if (error as NSError).code != -1728 { throw error }
                    } }
                    var output = TerminalScreen(tty: tty, contents: screen, title: title?.isEmpty == false ? title : nil)
                    if let presentation {
                        let selectedWindow = try matching("cwin", property: ["tcnt", "ttty"], tty: tty)
                        let ids = try RemoteTerminalPerformance.shared.measure(.terminalMetadata) { try getValue(property("ID  ", of: selectedWindow)) }
                        var displays: [(UInt32, TerminalTextSnapshot)] = []
                        for id in Set(try windowIDs(ids)) {
                            try Task.checkCancellation()
                            if let display = presentation(screen, id) { displays.append((id, display)) }
                        }
                        // Native tab groups expose hidden virtual windows too.
                        // Never choose an arbitrary match or infer a cursor.
                        if displays.count == 1 {
                            let confirmed = try RemoteTerminalPerformance.shared.measure(.terminalMetadata) { try windowIDs(getValue(property("ID  ", of: selectedWindow))) }
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
            if includeTitles, result.screens.contains(where: { $0.title == nil }) {
                do {
                    let before = try getValue(property("ID  ", of: windows))
                    let selected = try get(property("ttty", of: property("tcnt", of: windows)))
                    let names = try get(property("pnam", of: windows))
                    let after = try getValue(property("ID  ", of: windows))
                    // Pair names only while the window identity/order is stable.
                    // This is presentation metadata, never an input binding.
                    if before.descriptorType == aeCode("list"), after.descriptorType == aeCode("list"),
                       before.data == after.data, before.numberOfItems == selected.count, selected.count == names.count {
                        for index in result.screens.indices where result.screens[index].title == nil {
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
    private static var incompatiblePID: pid_t?
    private static var incompatiblePresentationPID: pid_t?

    /// nil uses the existing script's initial consent/compatibility path. A
    /// revoked permission or timeout never starts a second read or launches Terminal.
    static func screens(ttys: [String], includeTitles: Bool = true, includeCursor: Bool = false) throws -> TerminalSnapshot? {
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first else {
            throw AppError.message("Terminal 앱을 먼저 실행해주세요.")
        }
        guard !ttys.isEmpty else { return TerminalSnapshot() }
        let pid = application.processIdentifier
        lock.lock(); let unsupported = incompatiblePID == pid || (includeCursor && incompatiblePresentationPID == pid); lock.unlock()
        if unsupported { return nil }
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        // Never request a new permission from a background read. Explicit setup
        // retains the existing osascript consent behaviour if it is needed.
        let access = AEDeterminePermissionToAutomateTarget(target.aeDesc!, aeCode("core"), aeCode("getd"), false)
        if access == errAEEventNotPermitted { throw TerminalAdapterError.permissionDenied }
        if access == errAEEventWouldRequireUserConsent { return nil }
        guard access == noErr else { throw AppError.message("Terminal 자동화 상태를 확인하지 못했습니다. (\(access))") }
        let reader = TerminalAppleEventReader { subject, timeout in
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
        do { return try reader.screens(ttys: ttys, includeTitles: includeTitles,
            presentation: includeCursor ? { TerminalCursorReader.snapshot(screen: $0, windowID: $1) } : nil) }
        catch TerminalReadEventError.incompatible {
            lock.lock()
            if includeCursor { incompatiblePresentationPID = pid } else { incompatiblePID = pid }
            lock.unlock()
            return nil
        }
        catch TerminalReadEventError.timedOut { throw AppError.message("Terminal 화면 조회 시간이 초과되었습니다.") }
    }
}
