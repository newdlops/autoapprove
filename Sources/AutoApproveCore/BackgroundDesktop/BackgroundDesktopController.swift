import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Operates other Mac apps without moving the pointer or changing the active
/// app. It uses only Accessibility element actions, attribute writes, events
/// posted to one process and ScreenCaptureKit window captures. Any agent
/// reaches it through MCP; nothing here knows which agent is calling.
///
/// Measured on macOS 26 (TextEdit, Calculator): element presses, value writes,
/// caret moves and plain typing work in a background app. Menu commands,
/// ⌘ shortcuts and coordinate clicks have no effect there, so no tool offers them.
public final class BackgroundDesktopController: @unchecked Sendable {
    private let lock = NSLock()
    /// owner (MCP connection) → pid → ref → element. A new snapshot of an app replaces its refs.
    private var references: [String: [pid_t: [String: AXUIElement]]] = [:]
    private static let maximumChildren = 200

    public init() {}

    public func release(owner: String) { lock.withLock { _ = references.removeValue(forKey: owner) } }

    public func handle(tool: String, _ object: JSONObject, owner: String) async throws -> JSONObject {
        let box = UncheckedBox(object)
        return try await Task.detached(priority: .userInitiated) { [self] in
            try await perform(tool, box.value, owner: owner)
        }.value
    }

    private func perform(_ tool: String, _ object: JSONObject, owner: String) async throws -> JSONObject {
        guard AXIsProcessTrusted() else {
            throw RemoteHTTPError(409, "Mac의 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 AutoApprove를 허용해야 백그라운드 조작을 할 수 있습니다.")
        }
        switch tool {
        case "desktop_list_apps": return listApps()
        case "desktop_open_app": return try await openApp(object)
        case "desktop_snapshot": return try snapshot(try target(object), object, owner: owner)
        case "desktop_screenshot": return try await screenshot(try target(object), object)
        case "desktop_press": return try press(try target(object), object, owner: owner)
        case "desktop_set_value": return try setValue(try target(object), object, owner: owner)
        case "desktop_type": return try type(try target(object), object, owner: owner)
        case "desktop_key": return try key(try target(object), object)
        default: throw RemoteHTTPError(400, "지원하지 않는 백그라운드 조작 도구입니다.")
        }
    }

    // MARK: Targets

    private struct Target {
        let app: NSRunningApplication
        let element: AXUIElement
        var pid: pid_t { app.processIdentifier }
        var name: String { app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)" }
        var summary: JSONObject { ["app": name, "bundleID": app.bundleIdentifier ?? NSNull(), "pid": Int(pid)] }
    }

    private func candidates() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
    }

    private func target(_ object: JSONObject) throws -> Target {
        guard let query = (object["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            throw RemoteHTTPError(400, "조작할 앱의 번들 ID, 이름 또는 pid를 app에 지정해주세요.")
        }
        let apps = candidates()
        let match = Int32(query).flatMap { pid in apps.first { $0.processIdentifier == pid } }
            ?? apps.first { $0.bundleIdentifier?.caseInsensitiveCompare(query) == .orderedSame }
            ?? apps.first { $0.localizedName?.caseInsensitiveCompare(query) == .orderedSame }
        guard let app = match else {
            throw RemoteHTTPError(404, "‘\(query)’ 앱이 실행 중이지 않습니다. desktop_list_apps로 확인하거나 desktop_open_app으로 뒤에서 실행해주세요.")
        }
        if let reason = BackgroundDesktopPolicy.blockReason(bundleID: app.bundleIdentifier, name: app.localizedName ?? query) {
            throw RemoteHTTPError(403, reason)
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 2)
        return Target(app: app, element: element)
    }

    private func listApps() -> JSONObject {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let apps: [JSONObject] = candidates().map { app in
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.5)
            let windows = (Self.attribute(element, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            var entry: JSONObject = ["app": app.localizedName ?? "", "bundleID": app.bundleIdentifier ?? NSNull(), "pid": Int(app.processIdentifier),
                                     "frontmost": app.processIdentifier == front, "hidden": app.isHidden, "windows": windows.count]
            if let reason = BackgroundDesktopPolicy.blockReason(bundleID: app.bundleIdentifier, name: app.localizedName ?? "") { entry["blocked"] = reason }
            return entry
        }
        return ["apps": apps, "note": "frontmost인 앱은 사용자가 쓰는 중입니다. 백그라운드 도구는 어느 앱도 앞으로 가져오지 않습니다."]
    }

    private func openApp(_ object: JSONObject) async throws -> JSONObject {
        guard let query = (object["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            throw RemoteHTTPError(400, "실행할 앱의 번들 ID나 이름을 app에 지정해주세요.")
        }
        let workspace = NSWorkspace.shared
        let url = workspace.urlForApplication(withBundleIdentifier: query) ?? ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent(query.hasSuffix(".app") ? query : query + ".app") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let url else { throw RemoteHTTPError(404, "‘\(query)’ 앱을 찾지 못했습니다. 번들 ID(예: com.apple.TextEdit)로 지정해주세요.") }
        let bundleID = Bundle(url: url)?.bundleIdentifier
        if let reason = BackgroundDesktopPolicy.blockReason(bundleID: bundleID, name: url.deletingPathExtension().lastPathComponent) { throw RemoteHTTPError(403, reason) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false; configuration.addsToRecentItems = false
        let before = workspace.frontmostApplication
        let app: NSRunningApplication
        if let path = object["path"] as? String, !path.isEmpty {
            let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: file.path) else { throw RemoteHTTPError(404, "열 파일을 찾지 못했습니다: \(file.path)") }
            app = try await workspace.open([file], withApplicationAt: url, configuration: configuration)
        } else {
            app = try await workspace.openApplication(at: url, configuration: configuration)
        }
        let target = Target(app: app, element: AXUIElementCreateApplication(app.processIdentifier))
        // A launching app may activate itself after its first window appears.
        var focus: JSONObject = ["frontmostUnchanged": true]
        for _ in 0..<15 {
            try await Task.sleep(nanoseconds: 100_000_000)
            focus = restoreIfStolen(target, before: before)
            if focus["frontmostUnchanged"] as? Bool == false { break }
        }
        return target.summary.merging(["focus": focus, "next": "desktop_snapshot으로 창과 요소를 확인하세요."]) { $1 }
    }

    // MARK: Snapshot

    private func snapshot(_ target: Target, _ object: JSONObject, owner: String) throws -> JSONObject {
        let limit = min(max(Self.integer(object["maxNodes"]) ?? 400, 50), 1500)
        let frames = object["frames"] as? Bool ?? false
        let windows = (Self.attribute(target.element, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var roots: [AXUIElement]
        if let index = Self.integer(object["window"]) {
            guard windows.indices.contains(index) else { throw RemoteHTTPError(404, "창 번호 \(index)가 없습니다. 이 앱의 창은 \(windows.count)개입니다.") }
            roots = [windows[index]]
        } else { roots = Array(windows.prefix(6)) }
        if object["includeMenuBar"] as? Bool == true, let bar = Self.attribute(target.element, kAXMenuBarAttribute) { roots.append(bar as! AXUIElement) }
        let focused = Self.attribute(target.element, kAXFocusedUIElementAttribute).map { $0 as! AXUIElement }
        var lines: [String] = [], table: [String: AXUIElement] = [:], truncated = false, focusedRef: String?

        func visit(_ element: AXUIElement, depth: Int, indent: Int) {
            guard table.count < limit else { truncated = true; return }
            guard depth < 40 else { return }
            let role = Self.attribute(element, kAXRoleAttribute) as? String ?? "AXUnknown"
            let subrole = Self.attribute(element, kAXSubroleAttribute) as? String
            let secure = BackgroundDesktopPolicy.secureRoles.contains(role) || subrole.map(BackgroundDesktopPolicy.secureRoles.contains) == true
            let title = Self.text(Self.attribute(element, kAXTitleAttribute))
            let description = Self.text(Self.attribute(element, kAXDescriptionAttribute))
            let identifier = Self.text(Self.attribute(element, kAXIdentifierAttribute))
            let value = secure ? nil : Self.text(Self.attribute(element, kAXValueAttribute), limit: 160)
            let actions = Self.actions(element).filter(BackgroundDesktopPolicy.elementActions.contains)
            var settable = DarwinBoolean(false)
            let editable = !secure && AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
            let labelled = title != nil || description != nil || value != nil || !actions.isEmpty || editable
            var childIndent = indent
            if !(BackgroundDesktopPolicy.containerRoles.contains(role) && !labelled) {
                let ref = "e\(table.count + 1)"
                table[ref] = element
                if let focused, CFEqual(focused, element) { focusedRef = ref }
                var line = String(repeating: "  ", count: indent) + "[\(ref)] " + Self.roleName(role, subrole: subrole)
                if let title { line += " \"\(title)\"" }
                if let description, description != title { line += " (\(description))" }
                if let identifier { line += " #\(identifier)" }
                if let value { line += " value=\"\(value)\"" }
                if secure { line += " secure" }
                if !actions.isEmpty { line += " {" + actions.map { $0.replacingOccurrences(of: "AX", with: "").lowercased() }.joined(separator: ",") + "}" }
                if editable { line += " editable" }
                if Self.attribute(element, kAXEnabledAttribute) as? Bool == false { line += " disabled" }
                if focusedRef == ref { line += " focused" }
                if role == "AXWindow", Self.attribute(element, kAXMinimizedAttribute) as? Bool == true { line += " minimized" }
                if frames, let frame = Self.frame(element) { line += String(format: " @%.0f,%.0f %.0fx%.0f", frame.minX, frame.minY, frame.width, frame.height) }
                lines.append(line); childIndent += 1
            }
            for child in Self.children(element) { visit(child, depth: depth + 1, indent: childIndent) }
        }
        for root in roots { visit(root, depth: 0, indent: 0) }
        lock.withLock { references[owner, default: [:]][target.pid] = table }
        var result = target.summary
        result["frontmost"] = target.app.isActive
        result["windows"] = windows.count
        result["nodes"] = table.count
        result["truncated"] = truncated
        result["focused"] = focusedRef ?? NSNull()
        result["tree"] = lines.isEmpty ? "(창이 없거나 이 앱이 손쉬운 사용 정보를 제공하지 않습니다)" : lines.joined(separator: "\n")
        result["legend"] = "[ref] 역할 \"제목\" (설명) #식별자 value=값 {누를 수 있는 동작} editable=값 지정 가능. ref는 이 앱의 다음 스냅숏 전까지 유효합니다."
        return result
    }

    private func element(_ target: Target, _ object: JSONObject, owner: String) throws -> AXUIElement {
        guard let ref = object["ref"] as? String, !ref.isEmpty else { throw RemoteHTTPError(400, "desktop_snapshot에서 받은 요소 ref를 지정해주세요.") }
        guard let element = lock.withLock({ references[owner]?[target.pid]?[ref] }) else {
            throw RemoteHTTPError(404, "\(target.name)의 요소 \(ref)를 찾지 못했습니다. 먼저 이 앱에 desktop_snapshot을 호출해주세요.")
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == target.pid, Self.attribute(element, kAXRoleAttribute) != nil else {
            throw RemoteHTTPError(409, "요소 \(ref)가 화면에서 사라졌습니다. desktop_snapshot을 다시 호출해주세요.")
        }
        return element
    }

    // MARK: Actions

    private func press(_ target: Target, _ object: JSONObject, owner: String) throws -> JSONObject {
        let element = try element(target, object, owner: owner)
        let requested = (object["action"] as? String).map { $0.hasPrefix("AX") ? $0 : "AX" + $0.prefix(1).uppercased() + $0.dropFirst() } ?? "AXPress"
        guard BackgroundDesktopPolicy.elementActions.contains(requested) else {
            throw RemoteHTTPError(400, "백그라운드에서 쓸 수 있는 동작은 " + BackgroundDesktopPolicy.elementActions.sorted().joined(separator: ", ") + "입니다.")
        }
        guard Self.actions(element).contains(requested) else { throw RemoteHTTPError(409, "이 요소는 \(requested) 동작을 지원하지 않습니다.") }
        let before = NSWorkspace.shared.frontmostApplication
        let status = AXUIElementPerformAction(element, requested as CFString)
        guard status == .success else { throw RemoteHTTPError(502, "\(requested) 동작이 실패했습니다(AXError \(status.rawValue)).") }
        return target.summary.merging(["performed": requested, "focus": watchFocus(target, before: before),
            "next": "결과는 desktop_snapshot이나 desktop_screenshot으로 확인하세요. 메뉴 항목은 누르기에 성공해도 백그라운드 앱에서 실행되지 않을 수 있습니다."]) { $1 }
    }

    private func setValue(_ target: Target, _ object: JSONObject, owner: String) throws -> JSONObject {
        let element = try element(target, object, owner: owner)
        try Self.rejectSecure(element)
        guard let raw = object["value"] else { throw RemoteHTTPError(400, "지정할 값을 value에 넣어주세요.") }
        let insert = object["mode"] as? String == "insert"
        let attribute = insert ? kAXSelectedTextAttribute : kAXValueAttribute
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success, settable.boolValue else {
            throw RemoteHTTPError(409, insert ? "이 요소에는 커서 위치에 글자를 넣을 수 없습니다." : "이 요소의 값은 바꿀 수 없습니다. 입력란이면 desktop_type을 사용해주세요.")
        }
        let value: CFTypeRef
        if !insert, Self.attribute(element, kAXValueAttribute) is NSNumber {
            if let number = raw as? NSNumber { value = number }
            else if let text = raw as? String, let number = Double(text) { value = NSNumber(value: number) }
            else { throw RemoteHTTPError(400, "이 요소의 값은 숫자입니다.") }
        } else if let text = raw as? String { value = text as CFString }
        else { value = "\(raw)" as CFString }
        let before = NSWorkspace.shared.frontmostApplication
        let status = AXUIElementSetAttributeValue(element, attribute as CFString, value)
        guard status == .success else { throw RemoteHTTPError(502, "값을 지정하지 못했습니다(AXError \(status.rawValue)).") }
        let focus = watchFocus(target, before: before)
        return target.summary.merging(["mode": insert ? "insert" : "replace", "value": Self.text(Self.attribute(element, kAXValueAttribute), limit: 400) ?? NSNull(), "focus": focus]) { $1 }
    }

    private func type(_ target: Target, _ object: JSONObject, owner: String) throws -> JSONObject {
        guard let text = object["text"] as? String, !text.isEmpty else { throw RemoteHTTPError(400, "입력할 글자를 text에 넣어주세요.") }
        guard text.count <= 4000 else { throw RemoteHTTPError(400, "한 번에 4,000자까지 입력할 수 있습니다.") }
        let before = NSWorkspace.shared.frontmostApplication
        func focusedElement() -> AXUIElement? {
            guard let value = Self.attribute(target.element, kAXFocusedUIElementAttribute),
                  CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        var focused = focusedElement()
        if object["ref"] != nil {
            let requested = try element(target, object, owner: owner)
            try Self.rejectSecure(requested)
            if focused.map({ CFEqual($0, requested) }) != true {
                let status = AXUIElementSetAttributeValue(requested, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                usleep(80_000)
                let focus = restoreIfStolen(target, before: before)
                guard focus["frontmostUnchanged"] as? Bool == true else {
                    return target.summary.merging(["typed": false, "focus": focus, "error": "입력란에 포커스를 주자 앱이 앞으로 나와서 입력하지 않았습니다. desktop_set_value를 사용해주세요."]) { $1 }
                }
                focused = focusedElement()
                guard status == .success, focused.map({ CFEqual($0, requested) }) == true else {
                    throw RemoteHTTPError(409, "지정한 입력란의 포커스를 확인할 수 없습니다. desktop_snapshot으로 대상을 확인하거나 desktop_set_value를 사용해주세요.")
                }
            }
        }
        guard let focused else {
            throw RemoteHTTPError(409, "\(target.name)에 입력을 받을 요소가 없습니다. ref로 입력란을 지정해주세요.")
        }
        try Self.rejectSecure(focused)
        let source = CGEventSource(stateID: .privateState)
        for stroke in BackgroundDesktopKeys.strokes(text) {
            switch stroke {
            case .key(let code): post(code, flags: [], source: source, to: target.pid)
            case .text(let character):
                var units = Array(character.utf16)
                for down in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                    event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                    event.postToPid(target.pid)
                }
            }
            usleep(8_000)
        }
        let focus = watchFocus(target, before: before)
        return target.summary.merging(["typed": true, "characters": text.count, "into": Self.roleName(Self.attribute(focused, kAXRoleAttribute) as? String ?? "", subrole: nil),
            "value": Self.text(Self.attribute(focused, kAXValueAttribute), limit: 400) ?? NSNull(), "focus": focus]) { $1 }
    }

    private func key(_ target: Target, _ object: JSONObject) throws -> JSONObject {
        guard let name = object["key"] as? String, let code = BackgroundDesktopKeys.virtualKey(name) else {
            throw RemoteHTTPError(400, "지원하는 키: return, enter, tab, space, delete, escape, forwarddelete, home, end, pageup, pagedown, left, right, up, down, 영문자와 숫자")
        }
        let names = (object["modifiers"] as? [String] ?? []).map { $0.lowercased() }
        guard names.allSatisfy(BackgroundDesktopKeys.modifiers.contains) else { throw RemoteHTTPError(400, "modifiers에는 shift, option, control, command만 쓸 수 있습니다.") }
        var flags: CGEventFlags = []
        if names.contains("shift") { flags.insert(.maskShift) }
        if names.contains("option") { flags.insert(.maskAlternate) }
        if names.contains("control") { flags.insert(.maskControl) }
        if names.contains("command") { flags.insert(.maskCommand) }
        let count = min(max(Self.integer(object["repeat"]) ?? 1, 1), 50)
        if let focused = Self.attribute(target.element, kAXFocusedUIElementAttribute) { try Self.rejectSecure(focused as! AXUIElement) }
        let before = NSWorkspace.shared.frontmostApplication, source = CGEventSource(stateID: .privateState)
        for _ in 0..<count { post(code, flags: flags, source: source, to: target.pid); usleep(8_000) }
        var result = target.summary.merging(["key": name, "repeat": count, "focus": watchFocus(target, before: before)]) { $1 }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            result["note"] = "⌘·⌃ 단축키는 메뉴를 거치므로 백그라운드 앱에서 대부분 실행되지 않습니다. 결과를 확인하고, 실행되지 않았으면 해당 버튼을 desktop_press로 누르세요."
        }
        return result
    }

    private func post(_ code: UInt16, flags: CGEventFlags, source: CGEventSource?, to pid: pid_t) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            event.postToPid(pid)
        }
    }

    // MARK: Screenshot

    private func screenshot(_ target: Target, _ object: JSONObject) async throws -> JSONObject {
        guard CGPreflightScreenCaptureAccess() else {
            throw RemoteHTTPError(409, "Mac의 시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음에서 AutoApprove를 허용해주세요.")
        }
        let axWindows = (Self.attribute(target.element, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        let index = Self.integer(object["window"]) ?? 0
        guard axWindows.indices.contains(index) else { throw RemoteHTTPError(404, "\(target.name)에 \(index)번 창이 없습니다. 창은 \(axWindows.count)개입니다.") }
        let axWindow = axWindows[index]
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let owned = content.windows.filter { $0.owningApplication?.processID == target.pid && $0.windowLayer == 0 && $0.frame.width >= 40 && $0.frame.height >= 40 }
        let frame = Self.frame(axWindow)
        let title = Self.text(Self.attribute(axWindow, kAXTitleAttribute))
        let window = owned.min { lhs, rhs in Self.distance(lhs, frame: frame, title: title) < Self.distance(rhs, frame: frame, title: title) }
        guard let window else { throw RemoteHTTPError(404, "\(target.name)의 창을 캡처 대상에서 찾지 못했습니다.") }
        let longest = max(window.frame.width, window.frame.height)
        let scale = min(1, 1440 / max(longest, 1))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * scale)); configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false; configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            throw RemoteHTTPError(500, "캡처한 창을 이미지로 변환하지 못했습니다.")
        }
        var result = target.summary.merging(["window": index, "title": title ?? NSNull(), "width": image.width, "height": image.height,
            "onScreen": window.isOnScreen, "image": ["data": data.base64EncodedString(), "mimeType": "image/jpeg"]]) { $1 }
        if Self.attribute(axWindow, kAXMinimizedAttribute) as? Bool == true { result["note"] = "최소화된 창이라 내용이 최신이 아닐 수 있습니다." }
        return result
    }

    private static func distance(_ window: SCWindow, frame: CGRect?, title: String?) -> CGFloat {
        var score: CGFloat = 0
        if let frame { score += abs(window.frame.minX - frame.minX) + abs(window.frame.minY - frame.minY) + abs(window.frame.width - frame.width) + abs(window.frame.height - frame.height) }
        if let title, window.title != title { score += 10_000 }
        return score
    }

    // MARK: Focus guard

    /// Every action is followed by a check that the target app did not bring
    /// itself forward. If it did, the previous app is put back at once.
    private func watchFocus(_ target: Target, before: NSRunningApplication?) -> JSONObject {
        var result: JSONObject = ["frontmostUnchanged": true]
        for _ in 0..<4 {
            usleep(60_000)
            result = restoreIfStolen(target, before: before)
            if result["frontmostUnchanged"] as? Bool == false { break }
        }
        return result
    }

    private func restoreIfStolen(_ target: Target, before: NSRunningApplication?) -> JSONObject {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid, before?.processIdentifier != target.pid else {
            return ["frontmostUnchanged": true]
        }
        var result: JSONObject = ["frontmostUnchanged": false,
            "warning": "\(target.name)이(가) 스스로 앞으로 나왔습니다. 같은 조작을 반복하지 말고 다른 요소나 desktop_set_value를 사용하세요."]
        if let before, !before.isTerminated {
            let restored = AXUIElementSetAttributeValue(AXUIElementCreateApplication(before.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success
            result["restoredTo"] = before.localizedName ?? before.bundleIdentifier ?? ""
            result["restored"] = restored
        }
        return result
    }

    // MARK: Accessibility helpers

    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success, count > 0 else { return [] }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, min(count, maximumChildren), &values) == .success else { return [] }
        return (values as? [AXUIElement]) ?? []
    }

    private static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    private static func text(_ value: AnyObject?, limit: Int = 120) -> String? {
        let string: String
        if let value = value as? String { string = value }
        else if let number = value as? NSNumber { string = number.stringValue }
        else { return nil }
        let line = string.replacingOccurrences(of: "\n", with: "⏎").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    private static func roleName(_ role: String, subrole: String?) -> String {
        let base = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        let name = base.prefix(1).lowercased() + base.dropFirst()
        guard let subrole, subrole.hasPrefix("AX"), subrole != "AXStandardWindow" else { return name }
        return name + "/" + subrole.dropFirst(2).prefix(1).lowercased() + subrole.dropFirst(3)
    }

    private static func rejectSecure(_ element: AXUIElement) throws {
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
        if BackgroundDesktopPolicy.secureRoles.contains(role) || BackgroundDesktopPolicy.secureRoles.contains(subrole) {
            throw RemoteHTTPError(403, "비밀번호 입력란에는 백그라운드로 입력하지 않습니다. 사용자에게 직접 입력을 요청해주세요.")
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }
}

private struct UncheckedBox<T>: @unchecked Sendable { let value: T; init(_ value: T) { self.value = value } }
