import AppKit
import AutoApproveCore

/// Drives real Calculator and TextEdit windows. It runs only with
/// AUTOAPPROVE_LIVE_DESKTOP=1 from a process that has Accessibility and
/// Screen Recording permission, and never with an app the user already opened.
extension ApprovalTests {
    func testBackgroundDesktopLiveControlKeepsFocus() async throws {
        guard ProcessInfo.processInfo.environment["AUTOAPPROVE_LIVE_DESKTOP"] == "1" else { return }
        let targets = ["com.apple.calculator", "com.apple.TextEdit"]
        for bundle in targets where !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty {
            throw AppError.message("\(bundle) is already open; the live check only uses apps it launches itself")
        }
        var activated: [String] = []
        let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            if let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier { MainActor.assumeIsolated { activated.append(bundle) } }
        }
        let controller = BackgroundDesktopController(), owner = UUID().uuidString
        defer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            for bundle in targets { NSRunningApplication.runningApplications(withBundleIdentifier: bundle).forEach { $0.terminate() } }
        }
        func call(_ tool: String, _ arguments: JSONObject) async throws -> JSONObject {
            let result = try await controller.handle(tool: tool, arguments, owner: owner)
            if let focus = result["focus"] as? JSONObject { try expectEqual(focus["frontmostUnchanged"] as? Bool, true, "\(tool) kept the user's app in front") }
            return result
        }
        func ref(_ tree: String, _ marker: String) throws -> String {
            guard let line = tree.split(separator: "\n").first(where: { $0.contains(marker) }),
                  let open = line.firstIndex(of: "["), let close = line.firstIndex(of: "]") else { throw AppError.message("No element \(marker) in:\n\(tree)") }
            return String(line[line.index(after: open)..<close])
        }

        _ = try await call("desktop_open_app", ["app": "com.apple.calculator"])
        try await Task.sleep(nanoseconds: 1_500_000_000)
        var tree = try await call("desktop_snapshot", ["app": "com.apple.calculator"])["tree"] as? String ?? ""
        for marker in ["#AllClear", "#Seven", "#Add", "#Five", "#Equals"] {
            _ = try await call("desktop_press", ["app": "com.apple.calculator", "ref": try ref(tree, marker)])
        }
        tree = try await call("desktop_snapshot", ["app": "com.apple.calculator"])["tree"] as? String ?? ""
        try expect(tree.contains("12"), "Background presses computed 7+5:\n\(tree)")
        _ = try await call("desktop_type", ["app": "com.apple.calculator", "text": "2*3="])
        tree = try await call("desktop_snapshot", ["app": "com.apple.calculator"])["tree"] as? String ?? ""
        try expect(tree.split(separator: "\n").contains { $0.contains("staticText") && $0.hasSuffix("6\"") }, "Background typing computed 2*3:\n\(tree)")
        let shot = try await call("desktop_screenshot", ["app": "com.apple.calculator"])
        try expect(((shot["image"] as? JSONObject)?["data"] as? String)?.count ?? 0 > 1000, "The window capture returned an image")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("aa-desktop-\(UUID().uuidString).txt")
        try "first line\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await call("desktop_open_app", ["app": "com.apple.TextEdit", "path": file.path])
        try await Task.sleep(nanoseconds: 1_500_000_000)
        tree = try await call("desktop_snapshot", ["app": "com.apple.TextEdit"])["tree"] as? String ?? ""
        let area = try ref(tree, "textArea")
        _ = try await call("desktop_set_value", ["app": "com.apple.TextEdit", "ref": area, "value": "inserted ", "mode": "insert"])
        let typed = try await call("desktop_type", ["app": "com.apple.TextEdit", "ref": area, "text": "typed\nnext"])
        try expect((typed["value"] as? String ?? "").contains("inserted typed⏎next"), "Insert and typing reached the background text view: \(typed)")
        _ = try await call("desktop_key", ["app": "com.apple.TextEdit", "key": "left", "repeat": 2])

        do { _ = try await controller.handle(tool: "desktop_snapshot", ["app": "com.apple.Terminal"], owner: owner); throw AppError.message("Terminal was not blocked") }
        catch let error as RemoteHTTPError { try expectEqual(error.status, 403) }

        try await Task.sleep(nanoseconds: 300_000_000)
        try expect(!activated.contains(where: targets.contains), "No target app was activated: \(activated)")
    }
}
