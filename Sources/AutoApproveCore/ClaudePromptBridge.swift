import Foundation

enum ClaudePromptBridge {
    static let key = "AUTOAPPROVE_CLAUDE_PROMPT_BRIDGE"
    static let plugin: URL = {
        let relative = "AutoApprove_AutoApproveCore.bundle/ClaudePromptBridge.zip"
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        for candidate in [Bundle.main.resourceURL?.appendingPathComponent(relative),
                          executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/" + relative)].compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return Bundle.module.resourceURL!.appendingPathComponent("ClaudePromptBridge")
    }()

    static func channel(_ paths: AppPaths) -> URL {
        paths.directory.appendingPathComponent("claude-prompt-bridge").appendingPathComponent(UUID().uuidString)
    }

    struct Reply: Decodable {
        let nonce: UUID
        let session: UUID
        let state: String
    }

    static func state(path: String, paths: AppPaths, conversation: String?) async -> String? {
        let directory = URL(fileURLWithPath: path)
        let root = paths.directory.appendingPathComponent("claude-prompt-bridge").standardizedFileURL.path
        guard let conversation = conversation.flatMap(UUID.init(uuidString:)),
              UUID(uuidString: directory.lastPathComponent) != nil,
              directory.deletingLastPathComponent().standardizedFileURL.path == root else { return nil }
        let fm = FileManager.default
        let nonce = UUID()
        let request = directory.appendingPathComponent("request")
        let response = directory.appendingPathComponent(nonce.uuidString)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(nonce.uuidString.utf8).write(to: request, options: .atomic)
            defer {
                if (try? String(contentsOf: request, encoding: .utf8)) == nonce.uuidString { try? fm.removeItem(at: request) }
                try? fm.removeItem(at: response)
            }
            for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(100))
                if let data = try? Data(contentsOf: response), let reply = try? JSONDecoder().decode(Reply.self, from: data),
                   reply.nonce == nonce, reply.session == conversation { return reply.state }
            }
        } catch {}
        return nil
    }
}
