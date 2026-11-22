import Foundation

public enum AgyHookInstaller {
    public static var file: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/config/hooks.json") }

    public static func isInstalled(url: URL = file) -> Bool {
        guard let data = try? Data(contentsOf: url), let root = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject,
              let events = root["autoapprove"] as? JSONObject, let handlers = events["SessionStart"] as? [JSONObject] else { return false }
        return handlers.contains { ($0["command"] as? String)?.hasSuffix(" hook --agy --autoapprove-managed") == true }
    }

    public static func update(executable: String?, home: String, url: URL = file) throws {
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil { throw AppError.message("실제 hooks.json 파일을 지정해주세요.") }
        let previous = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        var config: JSONObject = [:]
        if let previous {
            let bytes = previous.starts(with: [0xef, 0xbb, 0xbf]) ? Data(previous.dropFirst(3)) : previous
            guard let parsed = try JSONSerialization.jsonObject(with: bytes) as? JSONObject else { throw AppError.message("agy 훅 설정 형식이 올바르지 않습니다.") }
            config = parsed
        }
        let suffix = " hook --agy --autoapprove-managed"
        if let existing = config["autoapprove"] {
            guard let entry = existing as? JSONObject, let start = entry["SessionStart"] as? [JSONObject],
                  (start.first?["command"] as? String)?.hasSuffix(suffix) == true else { throw AppError.message("autoapprove라는 이름의 다른 훅이 이미 있습니다.") }
        }
        if let executable {
            let command = "AUTOAPPROVE_HOME=" + HookInstaller.quote(home) + " " + HookInstaller.quote(executable) + suffix
            var events: JSONObject = [:]
            for name in ["SessionStart","PreInvocation","PreToolUse","PostToolUse","Stop"] {
                let handler: JSONObject = ["type":"command","command":command,"timeout":name == "PreToolUse" ? 30 : 10]
                events[name] = ["PreToolUse","PostToolUse"].contains(name) ? [["matcher":"*","hooks":[handler]]] : [handler]
            }
            if let old = config["autoapprove"] as? NSDictionary, old.isEqual(to: events) { return }
            config["autoapprove"] = events
        } else if config.removeValue(forKey: "autoapprove") == nil { return }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let previous {
            guard try Data(contentsOf: url) == previous else { throw AppError.message("agy 설정이 변경되었습니다. 다시 시도해주세요.") }
            try previous.write(to: url.appendingPathExtension(UUID().uuidString + ".backup"), options: .withoutOverwriting)
        }
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])
        try (data + Data([10])).write(to: url, options: .atomic)
    }
}
