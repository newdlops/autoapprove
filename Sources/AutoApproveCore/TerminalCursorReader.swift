import Foundation
import AppKit
import ApplicationServices

/// Reads an authoritative insertion range only from the exact selected Terminal window.
enum TerminalCursorReader {
    static func snapshot(screen: String, windowID: UInt32, title: String, bounds: TerminalWindowBounds) -> TerminalTextSnapshot? {
        guard AXIsProcessTrusted(), !screen.isEmpty,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first else { return nil }
        // Native tab groups also expose hidden virtual windows as selected.
        // Their titles/bounds can coincide. CG metadata identifies the actual
        // on-screen window without capturing pixels or requesting recording.
        let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard visible.contains(where: { ($0[kCGWindowNumber as String] as? UInt32) == windowID
            && ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier }) else { return nil }
        let deadline = Date().addingTimeInterval(0.35)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            guard Date() < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.05)
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
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
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let matches = windows.filter { window in
            guard attribute(window, kAXTitleAttribute) as? String == title,
                  let position = point(attribute(window, kAXPositionAttribute)), let dimensions = size(attribute(window, kAXSizeAttribute)) else { return false }
            return abs(position.x - bounds.x) < 2 && abs(position.y - bounds.y) < 2
                && abs(dimensions.width - bounds.width) < 2 && abs(dimensions.height - bounds.height) < 2
        }
        guard matches.count == 1 else { return nil }
        var pending = [matches[0]], checked = 0, snapshots: [TerminalTextSnapshot] = []
        while let element = pending.popLast(), checked < 256, Date() < deadline {
            checked += 1
            if attribute(element, kAXRoleAttribute) as? String == kAXTextAreaRole {
                // Codex redraws while working. One AX response keeps its visible
                // text and insertion range on the same source snapshot.
                var values: CFArray?
                let names = [kAXValueAttribute, kAXSelectedTextRangeAttribute, kAXVisibleCharacterRangeAttribute] as CFArray
                if AXUIElementCopyMultipleAttributeValues(element, names, [], &values) == .success,
                   let fields = values as? [Any], fields.count == 3, let value = fields[0] as? String {
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
            let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
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

    @MainActor init?(changed: @escaping @Sendable () -> Void) {
        guard AXIsProcessTrusted(), let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first else { return nil }
        var value: AXObserver?
        guard AXObserverCreate(app.processIdentifier, { observer, _, _, _ in TerminalCursorObservation.callbacks.notify(observer) }, &value) == .success,
              let value else { return nil }
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
        observer = value; elements = targets
        Self.callbacks.set(value, changed)
        for element in targets { for name in notifications { _ = AXObserverAddNotification(value, element, name as CFString, nil) } }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(value), .commonModes)
    }
    deinit {
        Self.callbacks.set(observer, nil)
        for element in elements { for name in notifications { _ = AXObserverRemoveNotification(observer, element, name as CFString) } }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}
