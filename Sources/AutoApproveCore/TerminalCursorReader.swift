import Foundation
import AppKit
import ApplicationServices

/// Reads an authoritative insertion range only from the exact selected Terminal window.
enum TerminalCursorReader {
    static func read(screen: String, title: String, bounds: TerminalWindowBounds) -> TerminalCursor? {
        guard AXIsProcessTrusted(), !screen.isEmpty,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first else { return nil }
        let deadline = Date().addingTimeInterval(0.35)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            guard Date() < deadline else { return nil }
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
        var pending = [matches[0]], checked = 0, cursors: [TerminalCursor] = []
        while let element = pending.popLast(), checked < 256, Date() < deadline {
            checked += 1
            if attribute(element, kAXRoleAttribute) as? String == kAXTextAreaRole,
               let value = attribute(element, kAXValueAttribute) as? String,
               let selected = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(selected) == AXValueGetTypeID() {
                var range = CFRange()
                if AXValueGetValue(selected as! AXValue, .cfRange, &range), range.length == 0,
                   let cursor = TerminalCursor.fromAccessibility(value: value, insertion: range.location, screen: screen) {
                    cursors.append(cursor)
                }
            }
            let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            pending.append(contentsOf: children.prefix(max(0, 256 - pending.count - checked)))
        }
        return cursors.count == 1 ? cursors[0] : nil
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
