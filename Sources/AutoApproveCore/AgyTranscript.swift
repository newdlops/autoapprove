import Foundation
import Darwin

enum AgyTranscript {
    struct Turn {
        let prompt: String
        let step: Int
        let answer: String
        let date: Date
    }

    // Read only the bounded tail of the official transcript for this conversation.
    // A partial turn cannot prove delivery. A later user prompt supersedes earlier answers.
    static func finalTurn(path: String, conversation: String) -> Turn? {
        guard UUID(uuidString: conversation) != nil else { return nil }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity-cli/brain")
        let directory = root.appendingPathComponent(conversation).appendingPathComponent(".system_generated/logs").standardizedFileURL
        let file = directory.appendingPathComponent("transcript.jsonl")
        guard file.path == URL(fileURLWithPath: path).standardizedFileURL.path,
              directory.resolvingSymlinksInPath().path == directory.path else { return nil }

        func read(_ url: URL) -> Turn? {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { return nil }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else { return nil }
            let start = max(0, info.st_size - 1_048_576)
            guard (try? handle.seek(toOffset: UInt64(start))) != nil,
                  let bytes = try? handle.read(upToCount: 1_048_576) else { return nil }
            var lines = bytes.split(separator: 10)[...]
            if start > 0 { lines = lines.dropFirst() }
            var prompt: String?, turn: Turn?
            for line in lines {
                guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? JSONObject else { return nil }
                if row["source"] as? String == "USER_EXPLICIT", row["type"] as? String == "USER_INPUT" {
                    prompt = nil
                    turn = nil
                    guard row["truncated_fields"] == nil, let content = row["content"] as? String,
                          content.hasPrefix("<USER_REQUEST>"), let end = content.range(of: "</USER_REQUEST>") else { continue }
                    prompt = String(content[..<end.lowerBound].dropFirst("<USER_REQUEST>".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if row["source"] as? String == "MODEL", row["type"] as? String == "PLANNER_RESPONSE" {
                    turn = nil
                    guard let prompt, row["status"] as? String == "DONE", row["truncated_fields"] == nil,
                          let step = row["step_index"] as? Int, let answer = row["content"] as? String, !answer.isEmpty,
                          let timestamp = row["created_at"] as? String else { continue }
                    let format = ISO8601DateFormatter()
                    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    guard let date = format.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp) else { continue }
                    turn = Turn(prompt: prompt, step: step, answer: answer, date: date)
                }
            }
            return turn
        }
        return read(file) ?? read(directory.appendingPathComponent("transcript_full.jsonl"))
    }
}
