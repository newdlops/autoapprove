import Foundation

public enum HookInstaller {
    public static let marker = "AutoApprove local bridge"
    public static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop", "SessionEnd", "Notification"]
    public static var settingsURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json") }
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func owned(_ hook: JSONObject) -> Bool {
        guard let command = hook["command"] as? String else { return false }
        return command.hasSuffix(" hook --autoapprove-managed")
    }
    public static func merged(_ original: JSONObject, executable: String?, home: String? = nil) -> JSONObject {
        var result = original
        var hooks = original["hooks"] as? [String: [JSONObject]] ?? [:]
        for event in events {
            var groups: [JSONObject] = []
            for var group in hooks[event] ?? [] {
                if let handlers = group["hooks"] as? [JSONObject] {
                    let remaining = handlers.filter { !owned($0) }
                    guard !remaining.isEmpty else { continue }
                    group["hooks"] = remaining
                }
                groups.append(group)
            }
            if let executable {
                let prefix = home.map { "AUTOAPPROVE_HOME=" + quote($0) + " " } ?? ""
                groups.append(["matcher": "", "hooks": [["type": "command", "command": prefix + quote(executable) + " hook --autoapprove-managed", "timeout": 4]]])
            }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        if hooks.isEmpty { result.removeValue(forKey: "hooks") } else { result["hooks"] = hooks }
        return result
    }
    public static func isInstalled(url: URL = settingsURL) -> Bool {
        guard let data = try? Data(contentsOf: url), let settings = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject,
              let hooks = settings["hooks"] as? [String: [JSONObject]] else { return false }
        return (hooks["PermissionRequest"] ?? []).contains { (($0["hooks"] as? [JSONObject]) ?? []).contains(where: owned) }
    }
    public static func install(executable: String?, url: URL = settingsURL, home: String? = nil) throws -> URL? {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let data = exists ? try Data(contentsOf: url) : Data("{}".utf8)
        guard let original = try JSONSerialization.jsonObject(with: data) as? JSONObject else { throw AppError.message("Claude 설정이 올바른 JSON 객체가 아닙니다. 기존 파일을 확인해주세요.") }
        if let existing = original["hooks"], !(existing is [String: [JSONObject]]) { throw AppError.message("기존 Claude 훅 형식을 해석하지 못했습니다. 설정을 변경하지 않았습니다.") }
        let updated = merged(original, executable: executable, home: home)
        let newData = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var backup: URL?
        if exists {
            let location = url.appendingPathExtension("autoapprove-\(UUID().uuidString.prefix(8)).backup")
            try data.write(to: location, options: .atomic); backup = location
        }
        try newData.write(to: url, options: .atomic)
        return backup
    }
}
