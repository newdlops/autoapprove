import Foundation

public enum CodexDesktopHookInstaller {
    private static let suffix = " codex-desktop-hook --autoapprove-managed"

    public static var defaultHome: URL {
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    /// Adds a user hook without rewriting existing handlers or granting Codex hook trust.
    @discardableResult
    public static func update(home: URL, executable: String?, applicationHome: String) throws -> Bool {
        let manager = FileManager.default
        let config = home.appendingPathComponent("hooks.json")
        if (try? manager.destinationOfSymbolicLink(atPath: config.path)) != nil {
            throw AppError.message("Codex hooks.json이 심볼릭 링크입니다. 실제 파일이 있는 CODEX_HOME을 지정해주세요.")
        }

        let previous = manager.fileExists(atPath: config.path) ? try Data(contentsOf: config) : nil
        var document: JSONObject = [:]
        if let previous {
            guard let value = try JSONSerialization.jsonObject(with: previous) as? JSONObject else {
                throw AppError.message("Codex hooks.json의 형식을 확인해주세요.")
            }
            document = value
        }

        var hooks: JSONObject = [:]
        if let declared = document["hooks"] {
            guard let value = declared as? JSONObject else {
                throw AppError.message("Codex hooks.json의 hooks 형식을 확인해주세요.")
            }
            hooks = value
        }
        var groups: [JSONObject] = []
        if let declared = hooks["PreToolUse"] {
            guard let value = declared as? [JSONObject] else {
                throw AppError.message("Codex hooks.json의 PreToolUse 형식을 확인해주세요.")
            }
            groups = value
        }

        let command = executable.map {
            "AUTOAPPROVE_HOME=" + HookInstaller.quote(applicationHome) + " " +
            HookInstaller.quote($0) + suffix
        }
        var modified = false
        var installed = false
        var updated: [JSONObject] = []
        for var group in groups {
            guard group["matcher"] as? String == CodexComputerUseRedirect.matcher,
                  let handlers = group["hooks"] as? [JSONObject] else {
                updated.append(group)
                continue
            }
            var kept: [JSONObject] = []
            for handler in handlers {
                guard handler["type"] as? String == "command",
                      let existing = handler["command"] as? String,
                      existing.hasSuffix(suffix) else {
                    kept.append(handler)
                    continue
                }
                if !installed, let command {
                    var replacement = handler
                    replacement["command"] = command
                    kept.append(replacement)
                    installed = true
                    modified = modified || existing != command
                } else {
                    modified = true
                }
            }
            if !kept.isEmpty || handlers.isEmpty {
                group["hooks"] = kept
                updated.append(group)
            }
        }

        if !installed, let command {
            updated.append(["matcher": CodexComputerUseRedirect.matcher,
                            "hooks": [["type": "command", "command": command, "timeout": 5]]])
            modified = true
        }
        guard modified else { return false }
        if updated.isEmpty { hooks.removeValue(forKey: "PreToolUse") } else { hooks["PreToolUse"] = updated }
        if hooks.isEmpty { document.removeValue(forKey: "hooks") } else { document["hooks"] = hooks }

        try manager.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let next = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        if let previous {
            guard try Data(contentsOf: config) == previous else {
                throw AppError.message("Codex 훅 설정이 동시에 바뀌었습니다. 명령을 다시 실행해주세요.")
            }
        } else if manager.fileExists(atPath: config.path) {
            throw AppError.message("Codex 훅 설정이 동시에 생성되었습니다. 명령을 다시 실행해주세요.")
        }
        try (next + Data([10])).write(to: config, options: .atomic)
        return true
    }
}
