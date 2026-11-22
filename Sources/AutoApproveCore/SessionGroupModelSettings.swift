import Foundation
import Darwin
import CSQLite

public struct SessionGroupModelSettings: Equatable, Sendable {
    public var model: String?
    public var reasoningEffort: String?
    public var source: String
    public var recordedAt: Date?

    public init(model: String?, reasoningEffort: String?, source: String, recordedAt: Date? = nil) {
        self.model = Self.token(model); self.reasoningEffort = Self.token(reasoningEffort)
        self.source = source; self.recordedAt = recordedAt
    }
    private static func token(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 256,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.:/+".contains($0)) }) else { return nil }
        return value
    }
}

public final class SessionGroupModelSettingsReader: @unchecked Sendable {
    private struct Identity: Equatable {
        var device: dev_t, inode: ino_t, size: off_t
        var modified: timespec, changed: timespec
        static func == (a: Self, b: Self) -> Bool {
            a.device == b.device && a.inode == b.inode && a.size == b.size &&
            a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec &&
            a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
        }
        init?(_ path: String) {
            var s = stat()
            guard lstat(path, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid() else { return nil }
            device = s.st_dev; inode = s.st_ino; size = s.st_size; modified = s.st_mtimespec; changed = s.st_ctimespec
        }
    }
    package typealias GroupTurn = (prompt: String, date: Date, response: WorkCompletion)
    private struct Cached {
        var groupTurns: [UUID: GroupTurn]
        var path: String, identity: Identity, value: SessionGroupModelSettings?
        var finalTurn: FinalTurn?, completionLoaded: Bool
    }
    private struct FinalTurn {
        var completion: WorkCompletion
        var prompt: String?
        var promptAt: Date?
    }
    private let lock = NSLock()
    private var cache: [String: Cached] = [:]
    public init() {}

    public func read(_ live: SessionGroupLiveSession) -> SessionGroupModelSettings? {
        guard let uuid = live.conversationID.flatMap(UUID.init(uuidString:)), let home = live.providerHome,
              home.hasPrefix("/") else { return nil }
        let id = uuid.uuidString.lowercased()
        if live.session.agent == .codex { return codex(home: home, id: id) }
        if live.session.agent == .agy {
            let brain = URL(fileURLWithPath: home).deletingLastPathComponent().appendingPathComponent("antigravity-cli/brain")
            return agy(brain: brain, id: id)
        }
        return claude(live, home: home, id: id, includeCompletion: false)?.value
    }

    private func agy(brain: URL, id: String) -> SessionGroupModelSettings? {
        let directory = brain.appendingPathComponent(id + "/.system_generated/logs").standardizedFileURL
        guard directory.resolvingSymlinksInPath().path == directory.path else { return nil }
        lock.lock()
        defer { lock.unlock() }
        for filename in ["transcript.jsonl", "transcript_full.jsonl"] {
            let path = directory.appendingPathComponent(filename).path
            guard let identity = Identity(path) else { continue }
            if let cached = cache[path], cached.identity == identity {
                if let value = cached.value { return value }
                continue
            }
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { continue }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_dev == identity.device, info.st_ino == identity.inode else { continue }
            let start = max(0, info.st_size - 4_194_304)
            guard (try? handle.seek(toOffset: UInt64(start))) != nil,
                  let bytes = try? handle.read(upToCount: 4_194_304), Identity(path) == identity else { continue }
            var lines = bytes.split(separator: 10, omittingEmptySubsequences: false).dropLast()
            if start > 0 { lines = lines.dropFirst() }
            var value: SessionGroupModelSettings?
            for line in lines.reversed() {
                guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? JSONObject,
                      row["source"] as? String == "MODEL", row["type"] as? String == "PLANNER_RESPONSE",
                      let model = row["model"] as? String else { continue }
                let effort = model.hasPrefix("gemini-4-neon-") ? String(model.dropFirst("gemini-4-neon-".count)) : ""
                let settings = SessionGroupModelSettings(model: model, reasoningEffort: ["low","medium","high"].contains(effort) ? effort : nil,
                    source: "agy_transcript", recordedAt: (row["created_at"] as? String).flatMap(Self.date))
                if settings.model != nil { value = settings; break }
            }
            cache[path] = Cached(groupTurns: [:], path: path, identity: identity, value: value, finalTurn: nil, completionLoaded: false)
            if let value { return value }
        }
        return nil
    }

    public func completion(_ live: SessionGroupLiveSession, after: Date, task: String? = nil) -> WorkCompletion? {
        guard let uuid = live.conversationID.flatMap(UUID.init(uuidString:)), let home = live.providerHome,
              home.hasPrefix("/"), let turn = claude(live, home: home, id: uuid.uuidString.lowercased(), includeCompletion: true)?.finalTurn,
              turn.completion.date >= after, turn.completion.date <= Date().addingTimeInterval(5) else { return nil }
        if let task {
            guard let promptAt = turn.promptAt, promptAt >= after, promptAt <= turn.completion.date,
                  turn.prompt == SessionGroupOrchestration.oneLine(task) else { return nil }
        }
        var completion = turn.completion
        completion.originalPromptAt = turn.promptAt
        return completion
    }

    package func groupTurns(_ live: SessionGroupLiveSession) -> [UUID: GroupTurn] {
        guard let id = live.conversationID.flatMap(UUID.init(uuidString:))?.uuidString.lowercased(),
              let home = live.providerHome, home.hasPrefix("/") else { return [:] }
        return claude(live, home: home, id: id, includeCompletion: true)?.groupTurns ?? [:]
    }

    private static func groupTurns(_ bytes: Data, id: String) -> [UUID: GroupTurn] {
        var turns: [UUID: GroupTurn] = [:]
        var seen = Set<UUID>()
        var active: (id: UUID, prompt: String, date: Date)?
        for line in bytes.split(separator: 10) {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? JSONObject else { active = nil; continue }
            guard row["isSidechain"] as? Bool != true,
                  (row["sessionId"] as? String)?.lowercased() == id else { continue }
            if row["type"] as? String == "user" {
                let content = (row["message"] as? JSONObject)?["content"]
                let parts = content as? [JSONObject]
                if let parts, !parts.isEmpty, parts.allSatisfy({ $0["type"] as? String == "tool_result" }) { continue }
                active = nil
                let text = content as? String ?? parts?.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                guard let text, let key = SessionGroupMessage.terminalMessageID(text) else { continue }
                turns.removeValue(forKey: key)
                guard seen.insert(key).inserted, let submitted = (row["timestamp"] as? String).flatMap(date) else { continue }
                active = (key, text, submitted)
            } else if row["type"] as? String == "assistant", let active {
                turns.removeValue(forKey: active.id)
                guard let message = row["message"] as? JSONObject, message["stop_reason"] as? String == "end_turn",
                      let item = row["uuid"] as? String, UUID(uuidString: item) != nil,
                      let ended = (row["timestamp"] as? String).flatMap(date), ended >= active.date,
                      ended <= Date().addingTimeInterval(5), let parts = message["content"] as? [JSONObject] else { continue }
                let text = parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                let result = WorkCompletion(id: "claude-log:" + id + ":" + item, date: ended, summary: text)
                if result.originalResponse != nil { turns[active.id] = (active.prompt, active.date, result) }
            }
        }
        return turns
    }

    private func claude(_ live: SessionGroupLiveSession, home: String, id: String, includeCompletion: Bool) -> Cached? {
        guard live.session.agent == .claude else { return nil }
        lock.lock(); defer { lock.unlock() }
        let key = home + "\n" + id
        if let previous = cache[key], let identity = Identity(previous.path), previous.identity == identity,
           !includeCompletion || previous.completionLoaded { return previous }
        let projects = URL(fileURLWithPath: home).appendingPathComponent("projects", isDirectory: true)
        let encoded = live.session.cwd.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
        let direct = projects.appendingPathComponent(encoded, isDirectory: true).appendingPathComponent(id + ".jsonl").path
        let path: String
        if Identity(direct) != nil { path = direct }
        else if let previous = cache[key], Identity(previous.path) != nil { path = previous.path }
        else {
            guard let children = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil), children.count <= 2048 else { return nil }
            let matches = children.map { $0.appendingPathComponent(id + ".jsonl").path }.filter { Identity($0) != nil }
            guard matches.count == 1 else { return nil }
            path = matches[0]
        }
        guard let before = Identity(path), let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        let start = max(0, before.size - 1_048_576)
        guard (try? handle.seek(toOffset: UInt64(start))) != nil,
              var bytes = try? handle.read(upToCount: Int(before.size - start)), let end = bytes.lastIndex(of: 10) else { return nil }
        if includeCompletion, bytes.last != 10 { return nil }
        bytes = Data(bytes[...end])
        if start > 0 {
            guard let first = bytes.firstIndex(of: 10) else { return nil }
            bytes = Data(bytes[bytes.index(after: first)...])
        }
        let value = Self.claude(bytes, id: id)
        let completion = includeCompletion ? Self.claudeCompletion(bytes, id: id) : nil
        guard Identity(path) == before else { return nil }
        if cache.count >= 256, cache[key] == nil { cache.removeAll(keepingCapacity: true) }
        let result = Cached(groupTurns: includeCompletion ? Self.groupTurns(bytes, id: id) : [:], path: path, identity: before, value: value, finalTurn: completion, completionLoaded: includeCompletion)
        cache[key] = result
        return result
    }

    static func claude(_ bytes: Data, id: String) -> SessionGroupModelSettings? {
        for line in bytes.split(separator: 10).reversed() {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? JSONObject,
                  row["type"] as? String == "assistant", row["isSidechain"] as? Bool != true,
                  (row["sessionId"] as? String).flatMap(UUID.init(uuidString:)) == UUID(uuidString: id),
                  let message = row["message"] as? JSONObject else { continue }
            let value = SessionGroupModelSettings(model: message["model"] as? String ?? row["requestedModel"] as? String,
                reasoningEffort: row["perTurnEffort"] as? String ?? row["effort"] as? String,
                source: "claude_turn_metadata", recordedAt: (row["timestamp"] as? String).flatMap(date))
            return value.model == nil && value.reasoningEffort == nil ? nil : value
        }
        return nil
    }

    private static func claudeCompletion(_ bytes: Data, id: String) -> FinalTurn? {
        var final: WorkCompletion?
        for line in bytes.split(separator: 10).reversed() {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? JSONObject,
                  row["isSidechain"] as? Bool != true,
                  (row["sessionId"] as? String).flatMap(UUID.init(uuidString:)) == UUID(uuidString: id),
                  let type = row["type"] as? String else { continue }
            if type == "user" {
                guard let message = row["message"] as? JSONObject else { return nil }
                let parts = message["content"] as? [JSONObject]
                if let parts, !parts.isEmpty, parts.allSatisfy({ $0["type"] as? String == "tool_result" }) { continue }
                guard let final else { return nil }
                let text = message["content"] as? String ?? parts?.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                return FinalTurn(completion: final, prompt: text, promptAt: (row["timestamp"] as? String).flatMap(date))
            }
            guard type == "assistant" else { continue }
            if final != nil { continue }
            guard let message = row["message"] as? JSONObject, message["stop_reason"] as? String == "end_turn",
                  let timestamp = row["timestamp"] as? String, let ended = date(timestamp),
                  let item = row["uuid"] as? String, UUID(uuidString: item) != nil,
                  let content = message["content"] as? [JSONObject] else { return nil }
            let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            final = WorkCompletion(id: "claude-log:\(id):\(item)", date: ended, summary: text)
        }
        return final.map { FinalTurn(completion: $0) }
    }

    private func codex(home: String, id: String) -> SessionGroupModelSettings? {
        let path = URL(fileURLWithPath: home).appendingPathComponent("state_5.sqlite").path
        guard Identity(path) != nil, let db = try? CodexHistoryAccess.open(path, subject: "모델 설정") else { return nil }
        defer { sqlite3_close_v2(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT model, reasoning_effort, updated_at FROM threads WHERE id = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let timestamp = sqlite3_column_double(statement, 2)
        let value = SessionGroupModelSettings(model: sqlite3_column_text(statement, 0).map { String(cString: $0) },
            reasoningEffort: sqlite3_column_text(statement, 1).map { String(cString: $0) }, source: "codex_session_metadata",
            recordedAt: timestamp > 0 && timestamp.isFinite ? Date(timeIntervalSince1970: timestamp > 1_000_000_000_000 ? timestamp / 1000 : timestamp) : nil)
        return value.model == nil && value.reasoningEffort == nil ? nil : value
    }

    private static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
