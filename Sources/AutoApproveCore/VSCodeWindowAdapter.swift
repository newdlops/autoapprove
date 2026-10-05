import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// The bridge first confirms its exact terminal object in its own focused window.
/// AX then confirms the terminal input is visible before any window is captured.
public enum VSCodeWindowAdapter {
    private static let bundles: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "com.vscodium"
    ]
    public static func ownerBundleID(ownerPID: Int32) -> String? {
        guard ownerPID > 0, let value = NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier,
              bundles.contains(value) else { return nil }
        return value
    }
    /// VS Code sets the xterm textarea's accessible label to `Terminal <id>, <title>`.
    /// An editor textarea or the last active (now hidden) terminal is insufficient.
    public static func terminalInputMatches(role: String, label: String, terminalName: String) -> Bool {
        guard role == kAXTextAreaRole, !terminalName.isEmpty, terminalName.utf8.count <= 2_000,
              !terminalName.contains("\n"), !terminalName.contains("\r"), label.utf8.count <= 8_000 else { return false }
        let first = String(label.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
        let name = NSRegularExpression.escapedPattern(for: terminalName)
        return first.range(of: "^(?:Terminal|터미널) [0-9]+, " + name + "$", options: .regularExpression) != nil
    }
    public static func windowMarkerMatches(label: String, token: String) -> Bool {
        guard token.utf8.count == 36, UUID(uuidString: token) != nil else { return false }
        return label == "AutoApprove window " + token
    }
    public static func metadata(ownerPID: Int32, tty: String, selected: Bool, bindingToken: String,
                                terminalName: String, windowToken: String) throws -> TerminalWindowMetadata? {
        guard selected, AXIsProcessTrusted(), !bindingToken.isEmpty,
              UUID(uuidString: windowToken) != nil,
              NSRunningApplication(processIdentifier: ownerPID)?.isActive == true,
              let bundle = ownerBundleID(ownerPID: ownerPID) else { return nil }
        let application = AXUIElementCreateApplication(ownerPID)
        AXUIElementSetMessagingTimeout(application, 0.2)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func element(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        guard let window = element(attribute(application, kAXFocusedWindowAttribute)),
              let input = element(attribute(application, kAXFocusedUIElementAttribute)),
              let inputWindow = element(attribute(input, kAXWindowAttribute)), CFEqual(window, inputWindow),
              let role = attribute(input, kAXRoleAttribute) as? String,
              [attribute(input, kAXDescriptionAttribute), attribute(input, kAXTitleAttribute)].contains(where: {
                  guard let label = $0 as? String else { return false }
                  return terminalInputMatches(role: role, label: label, terminalName: terminalName)
              }), let title = attribute(window, kAXTitleAttribute) as? String,
              let positionValue = attribute(window, kAXPositionAttribute), CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = attribute(window, kAXSizeAttribute), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        // The main PID and terminal names can be shared across editor windows.
        // Verify this bridge's accessible status item in the exact focused window.
        let deadline = Date().addingTimeInterval(0.35)
        var queue: [(AXUIElement, Int)] = [(window, 0)], offset = 0, seen = Set<CFHashCode>()
        var hasMarker = false
        while offset < queue.count && offset < 1_024 && Date() < deadline {
            let (node, depth) = queue[offset]; offset += 1
            guard seen.insert(CFHash(node)).inserted else { continue }
            if [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute].contains(where: {
                guard let label = attribute(node, $0) as? String else { return false }
                return windowMarkerMatches(label: label, token: windowToken)
            }) { hasMarker = true; break }
            if depth < 16, let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
                for child in children.prefix(max(0, 1_024 - queue.count)) { queue.append((child, depth + 1)) }
            }
        }
        guard hasMarker else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              [point.x, point.y, size.width, size.height].allSatisfy(\.isFinite), size.width > 0, size.height > 0,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let bounds = TerminalWindowBounds(x: point.x, y: point.y, width: size.width, height: size.height)
        let candidates = windows.compactMap { value -> UInt32? in
            guard (value[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPID,
                  (value[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  value[kCGWindowName as String] as? String == title,
                  let object = value[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: object as CFDictionary),
                  abs(frame.minX - bounds.x) < 2, abs(frame.minY - bounds.y) < 2,
                  abs(frame.width - bounds.width) < 2, abs(frame.height - bounds.height) < 2,
                  let identifier = (value[kCGWindowNumber as String] as? NSNumber)?.uint32Value, identifier > 0 else { return nil }
            return identifier
        }
        guard candidates.count == 1, ownerBundleID(ownerPID: ownerPID) == bundle,
              NSRunningApplication(processIdentifier: ownerPID)?.isActive == true,
              let currentWindow = element(attribute(application, kAXFocusedWindowAttribute)), CFEqual(window, currentWindow),
              let currentInput = element(attribute(application, kAXFocusedUIElementAttribute)), CFEqual(input, currentInput) else { return nil }
        return TerminalWindowMetadata(tty: tty, windowID: candidates[0], ownerPID: ownerPID, ownerBundleID: bundle,
            selected: true, minimized: attribute(window, kAXMinimizedAttribute) as? Bool == true,
            bounds: bounds, bindingToken: bindingToken)
    }
}
