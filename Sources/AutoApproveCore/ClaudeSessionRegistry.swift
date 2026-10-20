import Foundation
import Darwin

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
    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init?(url: URL) {
            var value = stat()
            let status = url.path.withCString { fstatat(AT_FDCWD, $0, &value, 0) }
            guard status == 0, value.st_mode & S_IFMT == S_IFREG,
                  value.st_size >= 0, value.st_size <= 262_144 else { return nil }
            device = value.st_dev; inode = value.st_ino; size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }
    private struct CachedRead {
        let session: FileIdentity
        let state: FileIdentity?
        let registration: ClaudeSessionRegistration?
    }
    private static let cacheLock = NSLock()
    private static var cache: [String: CachedRead] = [:]

    public static func read(records: [ProcessRecord], directory: URL? = nil) -> [ClaudeSessionRegistration] {
        let directory = directory ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        let zone = ProcessInfo.processInfo.environment["TZ"].flatMap(TimeZone.init(identifier:)) ?? .current
        var dates = RegistryDates(zone:zone)
        return records.compactMap { process in
            guard process.agent == .claude else { return nil }
            // These leaves are files. Avoid Foundation's implicit directory
            // metadata probe; FileIdentity still checks the live target below.
            let file = directory.appendingPathComponent("sessions/\(process.pid).json", isDirectory: false)
            guard let identity = FileIdentity(url:file) else { return nil }
            let cacheKey = file.path + "\n" + process.key + "\n" + zone.identifier
            cacheLock.lock(); let cached = cache[cacheKey]; cacheLock.unlock()
            if let cached, cached.session == identity {
                let stateURL = cached.registration.flatMap { registration -> URL? in
                    guard registration.kind == "bg", let job = registration.jobID, let activity = registration.activity,
                          activity.status == "waiting", activity.waitingFor == "input needed" else { return nil }
                    return directory.appendingPathComponent("jobs/\(job)/state.json", isDirectory: false)
                }
                let currentState = stateURL.flatMap { FileIdentity(url:$0) }
                if currentState == cached.state { return cached.registration }
            }

            var registration = (try? Data(contentsOf:file)).flatMap { decode($0, process:process, dates:&dates) }
            var stateIdentity: FileIdentity?, cacheable = true
            if let value = registration, value.kind == "bg", let job = value.jobID, let activity = value.activity,
               activity.status == "waiting", activity.waitingFor == "input needed" {
                let state = directory.appendingPathComponent("jobs/\(job)/state.json", isDirectory: false)
                if let before = FileIdentity(url:state), let data = try? Data(contentsOf:state) {
                    registration?.activity?.questionSummary = questionSummary(data, jobID:job, activity:activity, dates:&dates)
                    let after = FileIdentity(url:state)
                    if before == after { stateIdentity = after } else { cacheable = false }
                }
            }
            let afterSession = FileIdentity(url:file)
            if cacheable, identity == afterSession {
                cacheLock.lock()
                if cache.count >= 1024, cache[cacheKey] == nil { cache.removeAll(keepingCapacity:true) }
                cache[cacheKey] = CachedRead(session:identity, state:stateIdentity, registration:registration)
                cacheLock.unlock()
            }
            return registration
        }
    }

    public static func decode(_ data: Data, process: ProcessRecord, processTimeZone: TimeZone) -> ClaudeSessionRegistration? {
        var dates = RegistryDates(zone:processTimeZone)
        return decode(data,process:process,dates:&dates)
    }
    private static func decode(_ data: Data, process: ProcessRecord, dates: inout RegistryDates) -> ClaudeSessionRegistration? {
        guard process.agent == .claude, data.count <= 262_144,
              let json = try? JSONSerialization.jsonObject(with: data) as? JSONObject,
              (json["pid"] as? NSNumber)?.int32Value == process.pid,
              json["pidDomain"] as? String == "darwin",
              let started = json["procStart"] as? String,
              let kind = json["kind"] as? String, ["interactive", "bg"].contains(kind) else { return nil }
        // Claude's procStart is UTC. ps lstart, and therefore persisted AutoApprove IDs,
        // use the host time zone. Do not change those IDs when joining the registry.
        guard let date = dates.start(utc:started,local:process.started) else { return nil }
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
        var dates = RegistryDates(zone:TimeZone(secondsFromGMT:0)!)
        return questionSummary(data,jobID:jobID,activity:activity,dates:&dates)
    }
    private static func questionSummary(_ data: Data, jobID: String, activity: ClaudeSessionActivity, dates: inout RegistryDates) -> String? {
        guard data.count <= 262_144, activity.status == "waiting", activity.waitingFor == "input needed",
              let json = try? JSONSerialization.jsonObject(with: data) as? JSONObject,
              json["daemonShort"] as? String == jobID, json["backend"] as? String == "daemon",
              json["state"] as? String == "working", json["tempo"] as? String == "blocked",
              (json["resumeSessionId"] as? String ?? json["sessionId"] as? String) == activity.providerID,
              let timestamp = json["updatedAt"] as? String,
              let updated = dates.question(timestamp),
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

    /// Formatting state only, scoped to one synchronous read. No process, file
    /// contents, parsed result or permission is reused across observations.
    private struct RegistryDates {
        let zone: TimeZone
        private var utc: DateFormatter?
        private var local: DateFormatter?
        private var fractional: ISO8601DateFormatter?
        private var basic: ISO8601DateFormatter?
        init(zone: TimeZone) { self.zone = zone }
        private static func formatter(_ zone: TimeZone) -> DateFormatter {
            let value = DateFormatter()
            value.locale = Locale(identifier:"en_US_POSIX")
            value.dateFormat = "EEE MMM d HH:mm:ss yyyy"; value.timeZone = zone
            return value
        }
        mutating func start(utc text: String, local expected: String) -> Date? {
            if utc == nil { utc = Self.formatter(TimeZone(secondsFromGMT:0)!) }
            guard let date = utc?.date(from:text) else { return nil }
            if local == nil { local = Self.formatter(zone) }
            guard let local, ClaudeSessionRegistry.normalize(local.string(from:date)) == ClaudeSessionRegistry.normalize(expected) else { return nil }
            return date
        }
        mutating func question(_ text: String) -> Date? {
            if fractional == nil {
                let value = ISO8601DateFormatter()
                value.formatOptions = [.withInternetDateTime,.withFractionalSeconds]; fractional = value
            }
            if let date = fractional?.date(from:text) { return date }
            if basic == nil { basic = ISO8601DateFormatter() }
            return basic?.date(from:text)
        }
    }

    public static func parents(sessions: [AgentSession], records: [ProcessRecord], registrations: [ClaudeSessionRegistration]) -> [String: String] {
        var live: [String: AgentSession] = [:]
        live.reserveCapacity(sessions.count)
        for session in sessions where session.agent == .claude && session.phase != .ended && live[session.id] == nil {
            live[session.id] = session
        }
        // The common case is only interactive Claude sessions. Avoid building
        // registration groups and full process indexes every discovery tick
        // when no live child can possibly be attached to a parent.
        guard live.values.contains(where: { $0.terminal == .claudeBackground }) ||
                registrations.contains(where: { $0.kind == "bg" && live[$0.processID] != nil }) else { return [:] }
        var registry: [String: [ClaudeSessionRegistration]] = [:]
        for registration in registrations where live[registration.processID] != nil {
            registry[registration.processID, default: []].append(registration)
        }
        var parkedByJob: [String: [ClaudeSessionRegistration]] = [:]
        for registration in registrations {
            if let job = registration.parkedJobID, live[registration.processID] != nil {
                parkedByJob[job, default: []].append(registration)
            }
        }
        // Build process indexes once. Background-session reconciliation runs
        // on each discovery snapshot; rebuilding this full table for every
        // child made the work quadratic as concurrent Claude sessions grew.
        var byPID: [Int32: ProcessRecord] = [:], byKey: [String: ProcessRecord] = [:]
        byPID.reserveCapacity(records.count); byKey.reserveCapacity(live.count)
        for record in records {
            if byPID[record.pid] == nil { byPID[record.pid] = record }
            if live[record.key] != nil, record.agent == .claude {
                let key = record.key
                if byKey[key] == nil { byKey[key] = record }
            }
        }
        var links: [String: String] = [:]
        for child in live.values {
            let entry = registry[child.id]?.count == 1 ? registry[child.id]?.first : nil
            guard child.terminal == .claudeBackground || entry?.kind == "bg" else { continue }
            var candidates = Set<String>()
            if let process = byKey[child.id],
               let parent = ProcessDiscovery.ancestors(of: process.parent, byPID: byPID).first(where: {
                   $0.tty != process.tty && live[$0.key] != nil
               }) { candidates.insert(parent.key) }
            if let job = entry?.jobID {
                for parent in parkedByJob[job] ?? [] where parent.processID != child.id && live[parent.processID] != nil {
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
            if !seen.contains(current), let root = live[current], [.terminal, .vscode, .iterm, .orca].contains(root.terminal) {
                result[child] = current
            }
        }
        return result
    }
}
