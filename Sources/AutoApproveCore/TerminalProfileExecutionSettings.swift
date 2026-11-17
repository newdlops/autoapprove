import Foundation
import CSQLite

public struct TerminalProfileExecutionSettings: Codable, Equatable, Sendable {
    public var model: String?
    public var reasoningEffort: String?
    /// nil inherits the CLI setting; default explicitly selects standard speed.
    public var serviceTier: String?
    public init(model: String? = nil, reasoningEffort: String? = nil, serviceTier: String? = nil) {
        self.model = model; self.reasoningEffort = reasoningEffort; self.serviceTier = serviceTier
    }
    public var isEmpty: Bool { model == nil && reasoningEffort == nil && serviceTier == nil }
    public func validated(agent: String) throws -> Self {
        guard model.map({ !$0.isEmpty && $0.first.map { $0.isLetter || $0.isNumber } == true && $0.count <= 256 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.:/+".contains($0)) } }) ?? true,
              reasoningEffort.map({ (agent == "codex" ? ["none","minimal","low","medium","high","xhigh","max","ultra"] : ["low","medium","high","xhigh","max"]).contains($0) }) ?? true,
              serviceTier.map({ agent == "codex" && ["default","priority","ultrafast","flex"].contains($0) }) ?? true else {
            throw AppError.message("모델·추론 수준·처리 속도 설정을 확인해주세요.")
        }
        return self
    }
    public var summary: String {
        [model, reasoningEffort.map { "추론 " + $0 }, serviceTier.map {
            switch $0 { case "priority": return "Fast"; case "ultrafast": return "Ultrafast"; case "default": return "Standard"; default: return $0.capitalized }
        }].compactMap { $0 }.joined(separator: " · ")
    }
    func arguments(agent: String) throws -> [String] {
        let value = try validated(agent: agent)
        var result: [String] = []
        if let model = value.model { result += ["--model", model] }
        if let effort = value.reasoningEffort {
            result += agent == "codex" ? ["-c", "model_reasoning_effort=\"" + effort + "\""] : ["--effort", effort]
        }
        if let tier = value.serviceTier { result += ["-c", "service_tier=\"" + tier + "\""] }
        return result
    }
}

/// Explicit profile capture only. Reads owned, conversation-bound settings
/// checkpoints; never infers a session's speed from a global default.
public enum TerminalProfileExecutionSettingsReader {
    public static func read(_ live: SessionGroupLiveSession) -> TerminalProfileExecutionSettings? {
        guard let id = live.conversationID.flatMap(UUID.init(uuidString:)), let home = live.providerHome else { return nil }
        let metadata = SessionGroupModelSettingsReader().read(live)
        let fallback = TerminalProfileExecutionSettings(model: metadata?.model, reasoningEffort: metadata?.reasoningEffort)
        guard live.session.agent == .codex else { return (try? fallback.validated(agent: live.session.agent.rawValue)).flatMap { $0.isEmpty ? nil : $0 } }
        guard let db = try? CodexHistoryAccess.open(URL(fileURLWithPath: home).appendingPathComponent("state_5.sqlite").path, subject: "프로필 설정") else { return fallback.isEmpty ? nil : fallback }
        defer { sqlite3_close_v2(db) }
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT rollout_path FROM threads WHERE id=? LIMIT 1", -1, &query, nil) == SQLITE_OK, let query else { return fallback.isEmpty ? nil : fallback }
        defer { sqlite3_finalize(query) }
        sqlite3_bind_text(query, 1, id.uuidString.lowercased(), -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(query) == SQLITE_ROW, let raw = sqlite3_column_text(query, 0) else { return fallback.isEmpty ? nil : fallback }
        let file = URL(fileURLWithPath: String(cString: raw)).resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        guard file.path.hasPrefix(root + "/sessions/") || file.path.hasPrefix(root + "/archived_sessions/"),
              let handle = try? FileHandle(forReadingFrom: file) else { return fallback.isEmpty ? nil : fallback }
        defer { try? handle.close() }
        guard let first = try? CodexThreadLocation.readMetadataLine({ try handle.read(upToCount: $0) }),
              let header = try? JSONSerialization.jsonObject(with: first) as? JSONObject,
              let payload = header["payload"] as? JSONObject, header["type"] as? String == "session_meta",
              (payload["id"] as? String).flatMap(UUID.init(uuidString:)) == id,
              let size = try? handle.seekToEnd() else { return fallback.isEmpty ? nil : fallback }
        let start = size > 4_194_304 ? size - 4_194_304 : 0
        guard (try? handle.seek(toOffset: start)) != nil, var data = try? handle.read(upToCount: 4_194_304) else { return fallback.isEmpty ? nil : fallback }
        if start > 0, let newline = data.firstIndex(of: 10) { data = Data(data[data.index(after: newline)...]) }
        guard data.last == 10 else { return fallback.isEmpty ? nil : fallback }
        for line in data.split(separator: 10).reversed() {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? JSONObject,
                  row["type"] as? String == "event_msg", let event = row["payload"] as? JSONObject,
                  event["type"] as? String == "thread_settings_applied",
                  (event["thread_id"] as? String).flatMap(UUID.init(uuidString:)) == id,
                  let settings = event["thread_settings"] as? JSONObject else { continue }
            let value = TerminalProfileExecutionSettings(model: settings["model"] as? String,
                reasoningEffort: settings["reasoning_effort"] as? String ?? "none",
                serviceTier: settings["service_tier"] as? String ?? "default")
            return try? value.validated(agent: "codex")
        }
        return (try? fallback.validated(agent: "codex")).flatMap { $0.isEmpty ? nil : $0 }
    }
}
