import Foundation

/// Read-only session metadata. Never reads peer keys, terminal output, or transcripts.
public struct ClaudeSessionRegistration: Equatable {
    public var processID: String
    public var kind: String
    public var jobID: String?
    public var parkedJobID: String?
    public var activity: ClaudeSessionActivity?

    public init(processID: String, kind: String, jobID: String? = nil, parkedJobID: String? = nil, activity: ClaudeSessionActivity? = nil) {
        self.processID = processID; self.kind = kind
        self.jobID = jobID; self.parkedJobID = parkedJobID
        self.activity = activity
    }
}

public struct ClaudeSessionActivity: Equatable {
    public var providerID: String
    public var status: String
    public var waitingFor: String?
    public var changedAt: Date
    public var questionSummary: String?

    public init(providerID: String, status: String, waitingFor: String? = nil, changedAt: Date, questionSummary: String? = nil) {
        self.providerID = providerID; self.status = status; self.waitingFor = waitingFor
        self.changedAt = changedAt; self.questionSummary = questionSummary
    }

    public var requestID: String {
        "claude-state:\(providerID):\(changedAt.timeIntervalSince1970):\(waitingFor ?? status)"
    }
}

public enum ClaudeSessionRegistry {
    public static func read(records: [ProcessRecord], directory: URL? = nil) -> [ClaudeSessionRegistration] {
        let directory = directory ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let zone = ProcessInfo.processInfo.environment["TZ"].flatMap(TimeZone.init(identifier:)) ?? .current
        return records.filter { $0.agent == .claude }.compactMap { process in
            let file = directory.appendingPathComponent("sessions/\(process.pid).json")
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 262_144,
                  let data = try? Data(contentsOf: file) else { return nil }
            guard var registration = decode(data, process: process, processTimeZone: zone) else { return nil }
            if registration.kind == "bg", let job = registration.jobID, let activity = registration.activity,
               activity.status == "waiting", activity.waitingFor == "input needed" {
                let state = directory.appendingPathComponent("jobs/\(job)/state.json")
                if let size = try? state.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 262_144,
                   let data = try? Data(contentsOf: state) {
                    registration.activity?.questionSummary = questionSummary(data, jobID: job, activity: activity)
                }
            }
            return registration
        }
    }

    public static func decode(_ data: Data, process: ProcessRecord, processTimeZone: TimeZone) -> ClaudeSessionRegistration? {
        guard process.agent == .claude, data.count <= 262_144,
              let json = try? JSONSerialization.jsonObject(with: data) as? JSONObject,
              (json["pid"] as? NSNumber)?.int32Value == process.pid,
              json["pidDomain"] as? String == "darwin",
              let started = json["procStart"] as? String,
              let kind = json["kind"] as? String, ["interactive", "bg"].contains(kind) else { return nil }
        // Claude's procStart is UTC. ps lstart, and therefore persisted AutoApprove IDs,
        // use the host time zone. Do not change those IDs when joining the registry.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = formatter.date(from: started) else { return nil }
        formatter.timeZone = processTimeZone
        guard normalize(formatter.string(from: date)) == normalize(process.started) else { return nil }
        func identifier(_ key: String) -> String? {
            guard let value = json[key] as? String, !value.isEmpty, value.count <= 128,
                  value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
            return value
        }
        var activity: ClaudeSessionActivity?
        if let provider = identifier("sessionId"), let status = json["status"] as? String,
           ["busy", "waiting", "idle"].contains(status),
           let milliseconds = (json["statusUpdatedAt"] as? NSNumber)?.doubleValue,
           milliseconds.isFinite, milliseconds / 1000 >= date.timeIntervalSince1970,
           milliseconds / 1000 <= Date().addingTimeInterval(60).timeIntervalSince1970 {
            activity = .init(providerID: provider, status: status, waitingFor: json["waitingFor"] as? String,
                changedAt: Date(timeIntervalSince1970: milliseconds / 1000))
        }
        return .init(processID: process.key, kind: kind, jobID: identifier("jobId"), parkedJobID: identifier("parkedJobId"), activity: activity)
    }

    /// Jobs are not a stable Claude API. Use their optional structured question only
    /// after matching the live registry's job and conversation; never use it to reply.
    public static func questionSummary(_ data: Data, jobID: String, activity: ClaudeSessionActivity) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard data.count <= 262_144, activity.status == "waiting", activity.waitingFor == "input needed",
              let json = try? JSONSerialization.jsonObject(with: data) as? JSONObject,
              json["daemonShort"] as? String == jobID, json["backend"] as? String == "daemon",
              json["state"] as? String == "working", json["tempo"] as? String == "blocked",
              (json["resumeSessionId"] as? String ?? json["sessionId"] as? String) == activity.providerID,
              let timestamp = json["updatedAt"] as? String,
              let updated = formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp),
              updated >= activity.changedAt, updated <= Date().addingTimeInterval(60),
              let block = json["block"] as? JSONObject, let questions = block["questions"] as? [JSONObject],
              !questions.isEmpty, questions.count <= 16,
              questions.allSatisfy({ question in
                  guard let title = question["question"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        let options = question["options"] as? [JSONObject], !options.isEmpty, options.count <= 32 else { return false }
                  return options.allSatisfy { ($0["label"] as? String)?.isEmpty == false }
              }) else { return nil }
        return QuestionDetector.hookSummary(tool: "AskUserQuestion", input: ["questions": questions])
    }

    private static func normalize(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    public static func parents(sessions: [AgentSession], records: [ProcessRecord], registrations: [ClaudeSessionRegistration]) -> [String: String] {
        let live = Dictionary(sessions.filter { $0.agent == .claude && $0.phase != .ended }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let registry = Dictionary(grouping: registrations.filter { live[$0.processID] != nil }, by: \.processID)
        var links: [String: String] = [:]
        for child in live.values {
            let entry = registry[child.id]?.count == 1 ? registry[child.id]?.first : nil
            guard child.terminal == .claudeBackground || entry?.kind == "bg" else { continue }
            var candidates = Set<String>()
            if let process = records.first(where: { $0.key == child.id }),
               let parent = ProcessDiscovery.ancestors(of: process.parent, records: records).first(where: {
                   $0.tty != process.tty && live[$0.key] != nil
               }) { candidates.insert(parent.key) }
            if let job = entry?.jobID {
                for parent in registrations where parent.parkedJobID == job && parent.processID != child.id && live[parent.processID] != nil {
                    candidates.insert(parent.processID)
                }
            }
            if candidates.count == 1 { links[child.id] = candidates.first! }
        }
        // Flatten only chains ending in a real terminal. Cycles and missing parents stay separate.
        var result: [String: String] = [:]
        for child in links.keys {
            var current = child, seen = Set<String>()
            while let parent = links[current], seen.insert(current).inserted { current = parent }
            if !seen.contains(current), let root = live[current], root.terminal == .terminal || root.terminal == .vscode {
                result[child] = current
            }
        }
        return result
    }
}
