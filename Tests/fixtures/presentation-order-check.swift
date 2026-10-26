import Foundation
import Combine
import AutoApproveCore

@main enum OrderReuseAPIWorker {
    typealias Base = ScreenSessionCompareWorker
    static func require(_ value: Bool, _ message: String) throws { try Base.require(value, message) }
    static func exact(_ left: String, _ right: String) -> Bool {
        left.utf8.elementsEqual(right.utf8) && left.utf16.elementsEqual(right.utf16)
    }
    static func path(_ index: Int, _ style: String) -> String {
        let prefix = "/fixture/" + String(repeating: "a", count: 104) + "/"
        switch style {
        case "shared": return prefix + "shared"
        case "numeric-ties": return prefix + ["project1", "project01", "project001", "project2"][index % 4]
        case "case-width": return prefix + ["alpha", "Alpha", "Ａlpha", "ALPHA"][index % 4]
        case "canonical": return prefix + ["é", "e\u{301}", "한글🙂", "한글🧪"][index % 4]
        case "foreign": return Base.foreign(prefix + "한글 e\u{301}🙂 \(index)")
        case "long": return prefix + String(repeating: "e\u{301}한글🙂", count: 64) + "\(index)"
        default: return prefix + "project\(index)"
        }
    }
    @MainActor final class EngineValue {
        let root: URL, engine: ApprovalEngine, records: [ProcessRecord], seeds: [AgentSession]
        let counter: Base.Counter, subscription: AnyCancellable
        let directoriesA: [String: String], directoriesB: [String: String]
        var nextA = true
        init(_ count: Int, style: String = "unique", partial: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-order-api-" + UUID().uuidString)
            records = ProcessDiscovery.parse((0..<count).map {
                "\(990001+$0) 1 ttys\(900+$0) \(990001+$0) \(990001+$0) Mon Oct 12 09:00:00 2026 /fixture/codex"
            }.joined(separator: "\n"))
            seeds = records.enumerated().map { index, record in
                var row = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started,
                    tty: "/dev/" + record.tty, cwd: path(index, style), terminal: .iterm)
                row.channel = .itermScreen; row.lastActivity = Base.now
                return row
            }
            let paths = AppPaths(directory: root)
            if partial {
                try paths.prepare()
                let store = try AuditStore(path: paths.database)
                try store.set("sessionOrder", String(decoding: try JSONEncoder().encode(seeds.enumerated()
                    .filter { $0.offset.isMultiple(of: 2) }.map { $0.element.id }.reversed() + ["missing-original"]), as: UTF8.self))
            }
            let saved = records
            engine = try ApprovalEngine(paths: paths,
                terminalReader: { _ in throw Base.Failure.invalid("Forbidden original terminal read") },
                claudeRegistryReader: { _ in [] }, processReader: { saved }, powerControl: Base.power,
                terminalInputAvailable: { false }, terminalInputIdentity: { _ in nil })
            engine.updateDiscovery(seeds, records: records)
            for row in seeds {
                engine.receiveScreen(sessionID: row.id,
                    raw: "Synthetic fixture output\n• Working (esc to interrupt)\n›\n? for shortcuts",
                    generation: "fixture", at: Base.now)
            }
            directoriesA = seeds.first.map { [$0.id: "/fixture/aaa"] } ?? [:]
            directoriesB = seeds.first.map { [$0.id: "/fixture/zzz"] } ?? [:]
            counter = Base.Counter(); let countUpdates = counter
            subscription = engine.$snapshot.sink { _ in countUpdates.value += 1 }; counter.value = 0
            try require(engine.snapshot.sessions.count == count && engine.snapshot.events.isEmpty && engine.managedPTY.inventory.isEmpty,
                "Unexpected fake engine state")
        }
        func changeDirectory() {
            engine.updateDiscovery(seeds, records: records, directories: nextA ? directoriesA : directoriesB)
            nextA.toggle()
        }
        func close() { subscription.cancel(); engine.stop(); try? FileManager.default.removeItem(at: root) }
    }
    @MainActor static func verifyOriginalPolicy(_ engine: ApprovalEngine) throws {
        let fields = Mirror(reflecting: engine).children
        let sessions = fields.first { $0.label == "sessions" }!.value as! [String: AgentSession]
        let parents = fields.first { $0.label == "claudeParents" }!.value as! [String: String]
        try require(parents.isEmpty, "Raw-row policy oracle cannot stand in for grouped projection")
        let order = fields.first { $0.label == "sessionOrder" }!.value as! [String]
        var ranks: [String: Int] = [:]
        for (rank, id) in order.enumerated() { ranks[id] = rank }
        let rows = Array(sessions.values)
        var projects: [String: String] = [:]
        for row in rows where ranks[row.id] == nil { projects[row.id] = row.project }
        let expected = BoundOriginalOrder.apply(rows: rows, ranks: ranks, projects: projects)
        let actual = engine.snapshot.sessions, encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try require(actual == expected, "Actual Core rows differ from current original sorting policy")
        try require(try encoder.encode(actual) == encoder.encode(expected), "Full current payload bytes differ from original policy")
        for (a, b) in zip(actual, expected) {
            try require(exact(a.id, b.id) && exact(a.cwd, b.cwd) && exact(a.project, b.project)
                && exact(a.detail, b.detail) && exact(a.pendingSummary ?? "", b.pendingSummary ?? ""),
                "Current row raw UTF-8/UTF-16 changed")
        }
        try require(actual.allSatisfy { !$0.automatic } && engine.snapshot.events.isEmpty && engine.managedPTY.inventory.isEmpty,
            "Unexpected original input, automation or PTY activity")
    }
    static func append(_ value: Data, to output: inout Data) {
        var length = UInt32(value.count).littleEndian
        withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }; output.append(value)
    }
    @MainActor static func cases(_ file: String) throws {
        var output = Data("AOR1".utf8), policyChecks = 0, quietChecks = 0, payloadChecks = 0
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        func record(_ value: EngineValue, fullReceipt: Bool = true) throws {
            try verifyOriginalPolicy(value.engine); policyChecks += 1
            if fullReceipt {
                // Different processes have different dictionary tie-input orders.
                // Exact product order is checked ABOVE against that process's
                // original raw-input policy. Only the cross-process receipt is
                // normalized by unique ID; the product is never reordered here.
                var copy = value.engine.snapshot; copy.sessions.sort { $0.id < $1.id }
                append(try encoder.encode(copy), to: &output); payloadChecks += 1
            }
        }
        for count in [0, 1, 19, 32, 96] {
            for style in ["unique", "shared", "numeric-ties", "case-width", "canonical", "foreign", "long"] {
                for partial in [false, true] {
                    let value = try EngineValue(count, style: style, partial: partial); defer { value.close() }
                    try record(value)
                    for _ in 0..<8 { value.engine.refreshNotices(); try record(value) }
                    try require(value.counter.value == 0, "Repeated stable publication changed the snapshot")
                    quietChecks += 1
                    if count == 0 { continue }
                    let id = value.seeds[0].id, updated = "/fixture/새 경로 e\u{301}🙂"
                    value.engine.updateDiscovery(value.seeds, records: value.records, directories: [id: updated])
                    try require(value.engine.snapshot.sessions.first { $0.id == id }.map { exact($0.cwd, updated) } == true,
                        "Actual API cwd update did not happen")
                    try record(value)
                    try value.engine.setCustomization(id, value: SessionCustomization(title: "새 제목 e\u{301}🙂", note: "새 메모\n한글", color: .blue))
                    try require(value.engine.snapshot.sessions.first { $0.id == id }?.customization?.title == "새 제목 e\u{301}🙂",
                        "Fresh customization was lost")
                    try record(value)
                    value.engine.receiveScreen(sessionID: id,
                        raw: "Which environment?\n› 1. Development\n  2. Production\nEnter to submit · Esc to cancel",
                        generation: "fixture", at: Base.now)
                    try record(value)
                    value.engine.receiveScreen(sessionID: id,
                        raw: "Would you like to proceed?\n› 1. Yes, proceed (y)\n  2. No, and tell Codex what to do differently (esc)\nPress enter to confirm or esc to cancel",
                        generation: "fixture", at: Base.now)
                    try require(value.engine.snapshot.sessions.first { $0.id == id }?.pendingSummary != nil,
                        "Synthetic pending approval must actually be present")
                    try record(value)
                    value.engine.receiveScreen(sessionID: id,
                        raw: "Selected model is at capacity. Please try a different model.\n›\n? for shortcuts",
                        generation: "fixture", at: Base.now)
                    try record(value)
                    if count > 1 {
                        let ids = value.engine.snapshot.sessions.map(\.id)
                        try value.engine.moveSessions(fromOffsets: IndexSet(integer: 0), toOffset: ids.count, visibleIDs: ids)
                        try record(value)
                        let subset = value.engine.snapshot.sessions.enumerated().filter { $0.offset.isMultiple(of: 2) }.map { $0.element.id }
                        if subset.count > 1 {
                            try value.engine.moveSessions(fromOffsets: IndexSet(integer: 0), toOffset: subset.count, visibleIDs: subset)
                            try record(value)
                        }
                        do {
                            try value.engine.moveSessions(fromOffsets: IndexSet(integer: 0), toOffset: 2, visibleIDs: [ids[0], ids[0]])
                            throw Base.Failure.invalid("Duplicate visible IDs accepted")
                        } catch is AppError { }
                        try record(value)
                    }
                    // Ending uses the real current clock in the unchanged API.
                    // Its exact fresh values/order are checked in-process, rather
                    // than pretending different processes share a timestamp.
                    let before = Date()
                    value.engine.updateDiscovery([], records: [])
                    try require(value.engine.snapshot.sessions.allSatisfy { $0.phase == .ended && $0.lastActivity >= before },
                        "Ending did not produce fresh ended rows")
                    try record(value, fullReceipt: false)
                    value.engine.updateDiscovery(value.seeds, records: value.records)
                    for row in value.seeds {
                        value.engine.receiveScreen(sessionID: row.id, raw: "Synthetic fixture output\n• Working (esc to interrupt)\n›\n? for shortcuts",
                            generation: "fixture", at: Base.now)
                    }
                    try verifyOriginalPolicy(value.engine); policyChecks += 1
                    let replacementRecords = ProcessDiscovery.parse("999999 1 ttys999 999999 999999 Mon Oct 12 10:00:00 2026 /fixture/codex")
                    let replacementRecord = replacementRecords[0]
                    var replacement = AgentSession(id: replacementRecord.key, agent: .codex, pid: replacementRecord.pid, started: replacementRecord.started,
                        tty: "/dev/" + replacementRecord.tty, cwd: "/fixture/replacement", terminal: .iterm)
                    replacement.channel = .itermScreen; replacement.lastActivity = Base.now
                    value.engine.updateDiscovery([replacement], records: replacementRecords)
                    try require(value.engine.snapshot.sessions.contains { $0.id == replacement.id && $0.phase != .ended },
                        "New current identity was lost")
                    try record(value, fullReceipt: false)
                }
            }
        }
        try groupedCases()
        try output.write(to: URL(fileURLWithPath: file), options: .atomic)
        try Base.emit(["passed": true, "actualCompiledCore": true, "exactPerProcessOriginalPolicy": true,
            "fullCurrentPayloadsCompared": true, "rawUTF8AndUTF16": true, "policyChecks": policyChecks,
            "quietCases": quietChecks, "crossProcessFullPayloadReceipts": payloadChecks,
            "crossProcessReceiptOrderOnlyNormalized": true, "actualCWDUpdateAsserted": true,
            "freshPromptsCustomizationEndedAndIdentities": true, "groupedProjectionCases": 4,
            "outputBytes": output.count, "originalTerminalActions": 0, "realPowerCommands": 0])
    }
    @MainActor static func groupedCases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-order-group-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(directory: root); try paths.prepare()
        var rows = (0..<8).map { index -> AgentSession in
            var row = AgentSession(id: "process:\(910000+index):projection", agent: .claude, pid: Int32(910000+index),
                started: "projection", tty: "/dev/fixture-\(index)", cwd: "/fixture/Project \(8-index)", terminal: .claudeBackground)
            row.channel = .hook; row.setPhase(index == 2 ? .input : index == 1 ? .approval : .working, detail: "Synthetic projection")
            row.lastActivity = Base.now; return row
        }
        let ids = rows.map(\.id), parents = [ids[1]: ids[0], ids[2]: ids[1], ids[3]: "missing", ids[4]: ids[5], ids[5]: ids[4]]
        let store = try AuditStore(path: paths.database)
        try store.set("claudeParents", String(decoding: try JSONEncoder().encode(parents), as: UTF8.self))
        let engine = try ApprovalEngine(paths: paths,
            terminalReader: { _ in throw Base.Failure.invalid("Forbidden original read") },
            claudeRegistryReader: { _ in [] }, processReader: { [] }, powerControl: Base.power,
            terminalInputAvailable: { false }, terminalInputIdentity: { _ in nil })
        defer { engine.stop() }
        for change in 0..<4 {
            if change > 0 { rows[0].cwd = "/fixture/\(change)" }
            engine.updateDiscovery(rows, records: [], directories: change > 0 ? [ids[0]: rows[0].cwd] : [:], claudeRegistrations: [])
            let parent = engine.snapshot.sessions.first { $0.id == ids[0] }!
            try require(parent.phase == .input && parent.ownPhase == .working
                && Set(parent.backgroundChildren.map(\.id)) == Set([ids[1], ids[2]]), "Grouped current projection was lost")
            try require(parent.cwd == rows[0].cwd, "Grouped parent retained a stale cwd")
            let old = engine.snapshot.sessions
            engine.refreshNotices()
            try require(engine.snapshot.sessions == old, "Grouped repeated projection changed")
            try require(engine.snapshot.events.isEmpty && engine.managedPTY.inventory.isEmpty, "Unexpected grouped effects")
        }
    }
    @MainActor struct Workload { let engines: [EngineValue], changing: Bool }
    @MainActor static func workloads() throws -> [String: Workload] {
        var values: [String: Workload] = [:]
        for (mode, count, style, changing) in [
            ("steady19-unique",19,"unique",false), ("steady32-unique",32,"unique",false),
            ("steady96-unique",96,"unique",false), ("steady19-shared",19,"shared",false),
            ("steady32-shared",32,"shared",false), ("changed-cwd19",19,"unique",true),
            ("empty",0,"unique",false), ("single",1,"unique",false)
        ] {
            values[mode] = Workload(engines: try (0..<16).map { _ in try EngineValue(count, style: style) }, changing: changing)
        }
        return values
    }
    @MainActor @inline(never) static func measure(_ value: Workload, _ iterations: Int) throws -> UInt64 {
        for index in 0..<iterations {
            let context = value.engines[index % value.engines.count]
            if value.changing { context.changeDirectory() } else { context.engine.refreshNotices() }
        }
        for context in value.engines {
            if !value.changing { try require(context.counter.value == 0, "Steady API publication was noisy") }
            else if let row = context.seeds.first {
                let wanted = context.nextA ? context.directoriesB[row.id]! : context.directoriesA[row.id]!
                try require(context.engine.snapshot.sessions.first { $0.id == row.id }?.cwd == wanted,
                    "Changing workload did not actually change cwd")
            }
        }
        var checksum: UInt64 = UInt64(iterations)
        for row in value.engines[0].engine.snapshot.sessions {
            checksum = checksum &* 1099511628211 ^ UInt64(row.pid)
            for byte in row.project.utf8 { checksum = checksum &* 1099511628211 ^ UInt64(byte) }
        }
        return checksum
    }
    @MainActor static func bench() throws {
        let values = try autoreleasepool { try workloads() }
        defer { for value in values.values { for context in value.engines { context.close() } } }
        for value in values.values { _ = try autoreleasepool { try measure(value, 32) } }
        try Base.emit(["ready": true, "actualCompiledCore": true, "allRepeatedSnapshotsQuiet": true,
            "engineEnsemblePerMode": 16, "originalTerminalActions": 0, "realPowerCommands": 0,
            "engineStarted": false, "listenerStarted": false])
        while let line = readLine() {
            let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            if request["command"] as? String == "stop" { break }
            let mode = request["mode"] as! String, iterations = request["iterations"] as! Int
            guard let value = values[mode], iterations > 0 else { throw Base.Failure.invalid("Invalid API workload") }
            let before = try Base.metrics(), start = ProcessInfo.processInfo.systemUptime
            let digest = try autoreleasepool { try measure(value, iterations) }
            let wall = ProcessInfo.processInfo.systemUptime-start, after = try Base.metrics()
            try Base.emit(["id": request["id"]!, "mode": mode, "iterations": iterations, "checksum": String(digest),
                "wall": wall, "before": before, "after": after])
        }
    }
    @MainActor static func main() throws {
        switch CommandLine.arguments[1] {
        case "cases": try cases(CommandLine.arguments[2])
        case "bench": try bench()
        default: throw Base.Failure.invalid("Invalid order API command")
        }
    }
}
