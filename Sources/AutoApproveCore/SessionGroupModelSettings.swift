import Foundation
import Darwin
import CSQLite

public struct SessionGroupModelSettings: Equatable, Sendable {
    public var model: String?
    public var reasoningEffort: String?
    public var serviceTier: String?
    public var source: String
    public var recordedAt: Date?

    public init(model: String?, reasoningEffort: String?, source: String, recordedAt: Date? = nil) {
        self.model = Self.token(model); self.reasoningEffort = Self.token(reasoningEffort)
        self.source = source; self.recordedAt = recordedAt
    }
    fileprivate static func token(_ value: String?) -> String? {
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
    private enum Field: Hashable { case model, completion, groupTurns, goal }
    private struct Cached {
        var goal: ClaudeGroupGoalEvidence?
        var groupTurns: [UUID: GroupTurn] = [:]
        var path: String, identity: Identity, value: SessionGroupModelSettings?
        var finalTurn: FinalTurn?
        var fields: Set<Field> = []
    }
    private struct FinalTurn {
        var completion: WorkCompletion
        var prompt: String?
        var promptAt: Date?
    }
    private let lock = NSLock()
    private var cache: [String: Cached] = [:]
    private let threadReader: (@Sendable (String, String) -> JSONObject?)?
    private var checkpoints: [String: (UUID, Identity, SessionGroupModelSettings?)] = [:]

    public init(threadReader: (@Sendable (String, String) -> JSONObject?)? = nil) {
        self.threadReader = threadReader
    }

    public func read(_ live: SessionGroupLiveSession) -> SessionGroupModelSettings? {
        read(live, connection: CodexThreadSettingsConnection())
    }

    func readAll(_ targets: [SessionGroupLiveSession]) -> [String: SessionGroupModelSettings] {
        let connection = CodexThreadSettingsConnection()
        var result: [String: SessionGroupModelSettings] = [:], seen = Set<String>()
        for live in targets where seen.insert(live.id).inserted && !Task.isCancelled {
            result[live.id] = read(live, connection: connection)
        }
        return result
    }

    private func read(_ live: SessionGroupLiveSession, connection: CodexThreadSettingsConnection) -> SessionGroupModelSettings? {
        guard !live.providerIdentityAmbiguous else { return nil }
        return read(agent: live.session.agent, cwd: live.session.cwd, conversationID: live.conversationID,
                    home: live.providerHome, connection: connection)
    }

    func read(agent: AgentKind, cwd: String, conversationID: String?, home: String?, includeTier: Bool = false,
              connection: CodexThreadSettingsConnection) -> SessionGroupModelSettings? {
        guard let uuid = conversationID.flatMap(UUID.init(uuidString:)), let home, home.hasPrefix("/") else { return nil }
        let id = uuid.uuidString.lowercased()
        switch agent {
        case .codex:
            let row: JSONObject?
            if let threadReader { row = threadReader(home, id) }
            else { row = connection.read(home: home, id: id) }
            if let row {
                guard (row["id"] as? String).flatMap(UUID.init(uuidString:)) == uuid,
                      let directory = row["cwd"] as? String,
                      URL(fileURLWithPath: directory).resolvingSymlinksInPath().path == URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path else { return nil }
                if row["reasoningEffort"] != nil {
                    var value = SessionGroupModelSettings(model: row["model"] as? String, reasoningEffort: row["reasoningEffort"] as? String,
                        source: "codex_thread_read", recordedAt: (row["updatedAt"] as? Double).map(Date.init(timeIntervalSince1970:)))
                    if includeTier || row["model"] == nil {
                        let saved = codex(home: home, id: id)
                        if row["model"] == nil { value.model = saved?.model }
                        value.serviceTier = saved?.serviceTier
                    }
                    return value
                }
            }
            return codex(home: home, id: id)
        case .agy:
            let brain = URL(fileURLWithPath: home).deletingLastPathComponent().appendingPathComponent("antigravity-cli/brain")
            return agy(brain: brain, id: id)
        case .claude:
            return claude(cwd, home: home, id: id, field: .model)?.value
        case .shell: return nil
        }
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
                let settings = SessionGroupModelSettings(model: model, reasoningEffort: Self.agyEffort(model),
                    source: "agy_transcript", recordedAt: (row["created_at"] as? String).flatMap(Self.date))
                if settings.model != nil { value = settings; break }
            }
            cache[path] = Cached(path: path, identity: identity, value: value, fields: [.model])
            if let value { return value }
        }
        return nil
    }

    public func completion(_ live: SessionGroupLiveSession, after: Date, task: String? = nil) -> WorkCompletion? {
        guard let uuid = live.conversationID.flatMap(UUID.init(uuidString:)), let home = live.providerHome,
              home.hasPrefix("/"), live.session.agent == .claude, let turn = claude(live.session.cwd, home: home, id: uuid.uuidString.lowercased(), field: .completion)?.finalTurn,
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
        guard live.session.agent == .claude else { return [:] }
        return claude(live.session.cwd, home: home, id: id, field: .groupTurns)?.groupTurns ?? [:]
    }

    func claudeGoal(_ live: SessionGroupLiveSession) -> ClaudeGroupGoalEvidence? {
        guard let id = live.conversationID.flatMap(UUID.init(uuidString:))?.uuidString.lowercased(),
              let home = live.providerHome, home.hasPrefix("/") else { return nil }
        guard live.session.agent == .claude else { return nil }
        return claude(live.session.cwd, home:home, id:id, field: .goal)?.goal
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

    private func claude(_ cwd: String, home: String, id: String, field: Field) -> Cached? {
        lock.lock(); defer { lock.unlock() }
        let key = home + "\n" + id
        if let previous = cache[key], let identity = Identity(previous.path), previous.identity == identity,
           previous.fields.contains(field) { return previous }
        let projects = URL(fileURLWithPath: home).appendingPathComponent("projects", isDirectory: true)
        let encoded = cwd.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
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
        if field != .model, bytes.last != 10 { return nil }
        bytes = Data(bytes[...end])
        if start > 0 {
            guard let first = bytes.firstIndex(of: 10) else { return nil }
            bytes = Data(bytes[bytes.index(after: first)...])
        }
        var result: Cached
        if let previous = cache[key], previous.path == path, previous.identity == before {
            result = previous
        } else {
            result = Cached(path: path, identity: before, value: nil)
        }
        switch field {
        case .model: result.value = Self.claude(bytes, id: id)
        case .completion: result.finalTurn = Self.claudeCompletion(bytes, id: id)
        case .groupTurns: result.groupTurns = Self.groupTurns(bytes, id: id)
        case .goal: result.goal = ClaudeGroupGoalEvidence.read(bytes, id: id, complete: start == 0)
        }
        guard Identity(path) == before else { return nil }
        result.fields.insert(field)
        if cache.count >= 256, cache[key] == nil { cache.removeAll(keepingCapacity: true) }
        cache[key] = result
        return result
    }

    static func agyEffort(_ model: String) -> String? {
        let prefix = "gemini-4-neon-"
        guard model.hasPrefix(prefix) else { return nil }
        let effort = String(model.dropFirst(prefix.count))
        return ["low", "medium", "high"].contains(effort) ? effort : nil
    }

    static func claude(_ bytes: Data, id: String) -> SessionGroupModelSettings? {
        var selection: SessionGroupModelSettings?
        for line in bytes.split(separator: 10).reversed() {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? JSONObject,
                  row["isSidechain"] as? Bool != true, (row["sessionId"] as? String)?.lowercased() == id else { continue }
            if selection == nil, row["type"] as? String == "system", row["subtype"] as? String == "local_command",
               let run = row["commandRun"] as? JSONObject, let command = run["command"] as? String,
               ["effort", "/effort"].contains(command), let content = row["content"] as? String,
               content.hasPrefix("<local-command-stdout>"), content.hasSuffix("</local-command-stdout>") {
                let output = content.dropFirst("<local-command-stdout>".count).dropLast("</local-command-stdout>".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let prefixes = ["Set effort level to ", "Effort level set to ", "Effort set to "]
                if let prefix = prefixes.first(where: { output.hasPrefix($0) }) {
                    let level = String(output.dropFirst(prefix.count)).lowercased()
                    if ["low", "medium", "high", "xhigh", "max", "auto", "default"].contains(level) {
                        selection = .init(model: nil, reasoningEffort: ["auto", "default"].contains(level) ? nil : level,
                                          source: "claude_effort_command", recordedAt: (row["timestamp"] as? String).flatMap(date))
                    }
                }
            }
            guard row["type"] as? String == "assistant", let message = row["message"] as? JSONObject else { continue }
            let model = message["model"] as? String ?? row["requestedModel"] as? String
            if var selection {
                selection.model = SessionGroupModelSettings.token(model)
                return selection
            }
            let level = row["effort"] as? String ?? row["perTurnEffort"] as? String
            let value = SessionGroupModelSettings(model: model, reasoningEffort: ["auto", "default"].contains(level) ? nil : level,
                source: "claude_turn_metadata", recordedAt: (row["timestamp"] as? String).flatMap(date))
            return value.model == nil && value.reasoningEffort == nil ? nil : value
        }
        return selection
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
        let select = "SELECT model,reasoning_effort,updated_at,"
        let filter = " FROM threads WHERE id=? LIMIT 1"
        if sqlite3_prepare_v2(db, select + "rollout_path" + filter, -1, &statement, nil) != SQLITE_OK {
            guard sqlite3_prepare_v2(db, select + "NULL" + filter, -1, &statement, nil) == SQLITE_OK else { return nil }
        }
        guard let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        if let raw = sqlite3_column_text(statement, 3), let uuid = UUID(uuidString: id),
           let checkpoint = checkpoint(path: String(cString: raw), home: home, id: uuid) { return checkpoint }
        let timestamp = sqlite3_column_double(statement, 2)
        let value = SessionGroupModelSettings(model: sqlite3_column_text(statement, 0).map { String(cString: $0) },
            reasoningEffort: sqlite3_column_text(statement, 1).map { String(cString: $0) }, source: "codex_session_metadata",
            recordedAt: timestamp > 0 && timestamp.isFinite ? Date(timeIntervalSince1970: timestamp > 1_000_000_000_000 ? timestamp / 1000 : timestamp) : nil)
        return value.model == nil && value.reasoningEffort == nil ? nil : value
    }

    private func checkpoint(path: String, home: String, id: UUID) -> SessionGroupModelSettings? {
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        guard file.path.hasPrefix(root + "/sessions/") || file.path.hasPrefix(root + "/archived_sessions/"),
              let identity = Identity(file.path) else { return nil }
        if let cached = lock.withLock({ checkpoints[file.path] }), cached.0 == id, cached.1 == identity { return cached.2 }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let first = try? CodexThreadLocation.readMetadataLine({ try handle.read(upToCount: $0) }),
              let header = try? JSONSerialization.jsonObject(with: first) as? JSONObject, header["type"] as? String == "session_meta",
              let payload = header["payload"] as? JSONObject, (payload["id"] as? String).flatMap(UUID.init(uuidString:)) == id else { return nil }
        let start = max(0, identity.size - 4_194_304)
        guard (try? handle.seek(toOffset: UInt64(start))) != nil, let data = try? handle.read(upToCount: 4_194_304),
              let end = data.lastIndex(of: 10) else { return nil }
        var lines = data[..<end].split(separator: 10)[...]
        if start > 0 { lines = lines.dropFirst() }
        let marker = Data("thread_settings_applied".utf8)
        var value: SessionGroupModelSettings?
        for line in lines.reversed() where line.range(of: marker) != nil {
            guard let row = try? JSONSerialization.jsonObject(with: line) as? JSONObject,
                  row["type"] as? String == "event_msg", let event = row["payload"] as? JSONObject,
                  event["type"] as? String == "thread_settings_applied", (event["thread_id"] as? String).flatMap(UUID.init(uuidString:)) == id,
                  let settings = event["thread_settings"] as? JSONObject else { continue }
            value = SessionGroupModelSettings(model: settings["model"] as? String, reasoningEffort: settings["reasoning_effort"] as? String,
                source: "codex_thread_settings", recordedAt: (row["timestamp"] as? String).flatMap(Self.date))
            value?.serviceTier = settings["service_tier"] as? String ?? "default"
            break
        }
        guard Identity(file.path) == identity else { return nil }
        lock.withLock {
            if checkpoints.count >= 256, checkpoints[file.path] == nil { checkpoints.removeAll(keepingCapacity: true) }
            checkpoints[file.path] = (id, identity, value)
        }
        return value
    }

    private static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
