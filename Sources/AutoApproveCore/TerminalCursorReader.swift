import Foundation
import AppKit
import ApplicationServices

/// Reads an authoritative insertion range only from the exact selected Terminal window.
enum TerminalCursorReader {
    /// The native Terminal predicate supplies the selected window ID. Core
    /// Graphics supplies its current bounds without another Terminal event or
    /// screen capture. Ambiguous AX windows are rejected below.
    static func snapshot(screen: String, windowID: UInt32) -> TerminalTextSnapshot? {
        snapshot(screen: screen, windowID: windowID, title: nil, bounds: nil)
    }
    static func snapshot(screen: String, windowID: UInt32, title: String, bounds: TerminalWindowBounds) -> TerminalTextSnapshot? {
        snapshot(screen: screen, windowID: windowID, title: Optional(title), bounds: Optional(bounds))
    }
    private static func snapshot(screen: String, windowID: UInt32, title: String?, bounds: TerminalWindowBounds?) -> TerminalTextSnapshot? {
        guard AXIsProcessTrusted(), !screen.isEmpty,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first else { return nil }
        // Native tab groups also expose hidden virtual windows as selected.
        // Their titles/bounds can coincide. CG metadata identifies the actual
        // on-screen window without capturing pixels or requesting recording.
        guard let currentBounds = visibleWindowBounds(windowInfo(windowID: windowID), windowID: windowID,
            ownerPID: app.processIdentifier) else { return nil }
        let bounds = bounds ?? TerminalWindowBounds(x: currentBounds.minX, y: currentBounds.minY, width: currentBounds.width, height: currentBounds.height)
        let deadline = Date().addingTimeInterval(0.35)
        func attributes(_ element: AXUIElement, _ names: [String]) -> [Any]? {
            guard Date() < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.05)
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values) == .success,
                  let fields = values as? [Any], fields.count == names.count else { return nil }
            return fields
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        return accessibilitySnapshot(screen: screen, title: title, bounds: bounds, application: application,
            deadline: deadline, attributes: attributes)
    }

    static func windowInfo(windowID: UInt32) -> [[String: Any]] {
        guard windowID != kCGNullWindowID, let ids = CFArrayCreateMutable(nil, 1, nil) else { return [] }
        // Quartz window-ID arrays contain unretained integer values, not CFNumbers.
        CFArrayAppendValue(ids, UnsafeRawPointer(bitPattern: UInt(windowID)))
        return CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]] ?? []
    }
    static func visibleWindowBounds(_ windows: [[String: Any]], windowID: UInt32, ownerPID: Int32) -> CGRect? {
        guard let window = windows.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == windowID
            && ($0[kCGWindowOwnerPID as String] as? Int32) == ownerPID
            && ($0[kCGWindowIsOnscreen as String] as? Bool) == true }),
              let rectangle = window[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: rectangle), bounds.width > 0, bounds.height > 0 else { return nil }
        return bounds
    }
    static func accessibilitySnapshot(screen: String, title: String?, bounds: TerminalWindowBounds,
                                      application: AXUIElement, deadline: Date,
                                      attributes: (AXUIElement, [String]) -> [Any]?) -> TerminalTextSnapshot? {
        func point(_ value: CFTypeRef?) -> CGPoint? {
            guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero
            return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
        }
        func size(_ value: CFTypeRef?) -> CGSize? {
            guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            var size = CGSize.zero
            return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
        }
        let windows = attributes(application, [kAXWindowsAttribute])?.first as? [AXUIElement] ?? []
        let matches = windows.filter { window in
            if let title, attributes(window, [kAXTitleAttribute])?.first as? String != title { return false }
            guard let values = attributes(window, [kAXPositionAttribute, kAXSizeAttribute]), values.count == 2,
                  let position = point(values[0] as CFTypeRef),
                  let dimensions = size(values[1] as CFTypeRef) else { return false }
            return abs(position.x - bounds.x) < 2 && abs(position.y - bounds.y) < 2
                && abs(dimensions.width - bounds.width) < 2 && abs(dimensions.height - bounds.height) < 2
        }
        guard matches.count == 1 else { return nil }
        var pending = [matches[0]], checked = 0, snapshots: [TerminalTextSnapshot] = []
        while let element = pending.popLast(), checked < 256, Date() < deadline {
            checked += 1
            let identity = attributes(element, [kAXRoleAttribute, kAXChildrenAttribute]) ?? []
            if identity.count == 2, identity[0] as? String == kAXTextAreaRole {
                // Codex redraws while working. One AX response keeps its visible
                // text and insertion range on the same source snapshot.
                let names = [kAXValueAttribute, kAXSelectedTextRangeAttribute, kAXVisibleCharacterRangeAttribute]
                if let fields = attributes(element, names), fields.count == 3, let value = fields[0] as? String {
                    let selected = fields[1] as CFTypeRef, visible = fields[2] as CFTypeRef
                    var range = CFRange(), viewport = CFRange()
                    if CFGetTypeID(selected) == AXValueGetTypeID(), AXValueGetValue(selected as! AXValue, .cfRange, &range), range.length == 0 {
                        if CFGetTypeID(visible) == AXValueGetTypeID(), AXValueGetValue(visible as! AXValue, .cfRange, &viewport),
                           let snapshot = TerminalTextSnapshot.fromAccessibility(value: value, insertion: range.location,
                               visible: NSRange(location: viewport.location, length: viewport.length)) {
                            snapshots.append(snapshot)
                        } else if let cursor = TerminalCursor.fromAccessibility(value: value, insertion: range.location, screen: screen) {
                            snapshots.append(TerminalTextSnapshot(screen: screen, cursor: cursor))
                        }
                    }
                }
            }
            let children = identity.count == 2 ? identity[1] as? [AXUIElement] ?? [] : []
            pending.append(contentsOf: children.prefix(max(0, 256 - pending.count - checked)))
        }
        return snapshots.count == 1 ? snapshots[0] : nil
    }
}

extension TerminalCursor {
    /// Terminal may expose scrollback before its visible text; map only an exact visible range.
    public static func fromAccessibility(value: String, insertion: Int, screen: String) -> TerminalCursor? {
        guard !screen.isEmpty, insertion >= 0 else { return nil }
        let range = (value as NSString).range(of: screen, options: .backwards)
        guard range.location != NSNotFound, insertion >= range.location, insertion <= range.location + range.length else { return nil }
        return TerminalCursor(offset: insertion - range.location).validated(for: screen)
    }
}

/// A browser subscription reads the original terminal when its native text or
/// insertion range changes. It never focuses a window or posts keyboard events.
final class TerminalCursorObservation: @unchecked Sendable {
    private struct Identity: Equatable { let pid: Int32; let started: Date }
    @MainActor private static let pool = TerminalObservationPool<Identity,TerminalCursorObserver>()
    private let lease: TerminalObservationLease<TerminalCursorObserver>

    @MainActor init?(changed: @escaping @Sendable () -> Void) {
        guard AXIsProcessTrusted(), let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first,
              !app.isTerminated, let targets = TerminalCursorObserver.targets(application:app) else { return nil }
        let identity = app.launchDate.map { Identity(pid:app.processIdentifier,started:$0) }
        guard AXIsProcessTrusted(), !app.isTerminated else { return nil }
        guard let lease = Self.pool.subscribe(identity:identity,canReuse:{
            let matches = $0.matches(targets)
            if matches { RemoteTerminalPerformance.shared.increment(.sharedNativeObservers) }
            return matches
        },
            make:{ TerminalCursorObserver(application:app,targets:targets,changed:$0) },changed:changed) else { return nil }
        self.lease = lease
    }
}

private final class TerminalCursorObserver {
    private final class Callbacks: @unchecked Sendable {
        let lock = NSLock()
        var values: [UnsafeMutableRawPointer: @Sendable () -> Void] = [:]
        func set(_ observer: AXObserver, _ value: (@Sendable () -> Void)?) {
            lock.lock(); defer { lock.unlock() }
            values[Unmanaged.passUnretained(observer).toOpaque()] = value
        }
        func notify(_ observer: AXObserver) {
            lock.lock(); let value = values[Unmanaged.passUnretained(observer).toOpaque()]; lock.unlock()
            value?()
        }
    }
    private static let callbacks = Callbacks()
    private let observer: AXObserver
    private let elements: [AXUIElement]
    private let notifications = [kAXValueChangedNotification, kAXSelectedTextChangedNotification]

    /// Enumerate on every new subscription, even when a native observer can be
    /// shared. New tabs/windows must retain the old fresh-target coverage.
    @MainActor static func targets(application app: NSRunningApplication) -> [AXUIElement]? {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.1)
        let deadline = Date().addingTimeInterval(0.3)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            guard Date() < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.05)
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
        }
        var pending = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        var targets: [AXUIElement] = [], count = 0
        while let element = pending.popLast(), count < 256, Date() < deadline {
            count += 1
            if attribute(element, kAXRoleAttribute) as? String == kAXTextAreaRole { targets.append(element) }
            pending.append(contentsOf: (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(max(0, 256 - count - pending.count)))
        }
        guard !targets.isEmpty else { return nil }
        return targets
    }
    func matches(_ targets: [AXUIElement]) -> Bool {
        elements.count == targets.count && zip(elements,targets).allSatisfy { CFEqual($0.0,$0.1) }
    }
    @MainActor init?(application app: NSRunningApplication, targets: [AXUIElement], changed: @escaping @Sendable () -> Void) {
        guard AXIsProcessTrusted(), !app.isTerminated, !targets.isEmpty else { return nil }
        var value: AXObserver?
        guard AXObserverCreate(app.processIdentifier, { observer, _, _, _ in TerminalCursorObserver.callbacks.notify(observer) }, &value) == .success,
              let value else { return nil }
        observer = value; elements = targets
        Self.callbacks.set(value, changed)
        for element in targets { for name in notifications { _ = AXObserverAddNotification(value, element, name as CFString, nil) } }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(value), .commonModes)
        RemoteTerminalPerformance.shared.increment(.nativeObservers)
    }
    deinit {
        Self.callbacks.set(observer, nil)
        for element in elements { for name in notifications { _ = AXObserverRemoveNotification(observer, element, name as CFString) } }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        RemoteTerminalPerformance.shared.increment(.releasedNativeObservers)
    }
}
