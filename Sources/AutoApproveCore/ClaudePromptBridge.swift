import Foundation
import CryptoKit

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

    private static func directory(path: String, paths: AppPaths) -> URL? {
        let directory = URL(fileURLWithPath: path)
        let root = paths.directory.appendingPathComponent("claude-prompt-bridge").standardizedFileURL.path
        guard UUID(uuidString: directory.lastPathComponent) != nil,
              directory.deletingLastPathComponent().standardizedFileURL.path == root else { return nil }
        return directory
    }

    static func setAutomatic(_ enabled: Bool, path: String, paths: AppPaths) throws {
        guard let directory = directory(path: path, paths: paths) else { throw AppError.message("Claude 입력창 연결 경로를 확인해주세요.") }
        let marker = directory.appendingPathComponent("automatic")
        if enabled {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data().write(to: marker, options: .atomic)
        } else {
            do { try FileManager.default.removeItem(at: marker) }
            catch let error as CocoaError where error.code == .fileNoSuchFile {}
        }
    }

    static func state(path: String, paths: AppPaths, conversation: String?, expectedDraft: String? = nil) async -> String? {
        guard let conversation = conversation.flatMap(UUID.init(uuidString:)),
              let directory = directory(path: path, paths: paths) else { return nil }
        let fm = FileManager.default
        let nonce = UUID()
        let request = directory.appendingPathComponent("request")
        let response = directory.appendingPathComponent(nonce.uuidString)
        let challenge = directory.appendingPathComponent("match-" + nonce.uuidString)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { if expectedDraft != nil { try? fm.removeItem(at: challenge) } }
            if let expectedDraft {
                let digest = SHA256.hash(data: Data(expectedDraft.precomposedStringWithCanonicalMapping.utf8))
                try Data(digest.map { String(format: "%02x", $0) }.joined().utf8).write(to: challenge, options: .atomic)
            }
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
