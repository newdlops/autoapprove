import Foundation
import Combine
import Darwin
import AutoApproveCore

/// Production polling and parsing with synthetic frames; no Apple event is sent.
@main struct ScreenMatchEngineCheck {
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw AppError.message(message) }
    }
    final class Frames: @unchecked Sendable {
        let cocoa: Bool
        private let lock = NSLock()
        private var values: [TerminalScreen] = []
        private(set) var foreignReads = 0
        init(cocoa: Bool) { self.cocoa = cocoa }
        func replace(_ values: [TerminalScreen]) { lock.lock(); defer { lock.unlock() }; self.values = values }
        func read(_ targets: [ScreenTarget]) -> TerminalSnapshot {
            lock.lock(); defer { lock.unlock() }
            return TerminalSnapshot(screens: targets.compactMap { target in
                guard let original = values.first(where: { $0.tty == target.tty }) else { return nil }
                let contents = cocoa ? NSAppleEventDescriptor(string: original.contents).stringValue! : original.contents
                if !contents.isContiguousUTF8 { foreignReads += 1 }
                return TerminalScreen(tty: original.tty, contents: contents, title: original.title)
            })
        }
    }
    static let history = String(repeating: "Synthetic output 한글 👩🏽‍💻 e\u{301} checked local source and retained the original session.\n", count: 768)
    static func screen(_ index: Int, variant: Int) -> TerminalScreen {
        let codex = index.isMultiple(of: 2), glyph = codex ? "›" : "❯"
        let bodyChange = CommandLine.arguments.contains("--body-change")
        let footerVariant = bodyChange ? 0 : variant
        let tail: String
        switch index / 4 {
        case 0: tail = "Checking synthetic result \(footerVariant)\n• Working (esc to interrupt)"
        case 1: tail = "\(glyph)\n? for shortcuts"
        case 2: tail = "\(codex ? "Would you like to run the following command?" : "Do you want to proceed?")\n$ fixture-test-\(footerVariant)\n\(glyph) 1. Yes\n  2. No\nEsc to cancel"
        default: tail = "Which synthetic result \(footerVariant)?\n\(glyph) 1. First\n  2. Second\nEnter to select"
        }
        let body = bodyChange ? history + String(format: "Synthetic body result %04d\n", variant)
            + String(repeating: "Unchanged footer context\n", count: 16) : history + "\n"
        return TerminalScreen(tty: "/dev/fixture-match-\(index)", contents: body + tail)
    }
    static func cpu() -> Double {
        var value = rusage(); getrusage(RUSAGE_SELF, &value)
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
            + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
    }
    static func changedFields(_ previous: EngineSnapshot, _ current: EngineSnapshot) -> [String] {
        let encoder = JSONEncoder()
        let left = try! JSONSerialization.jsonObject(with: encoder.encode(previous)) as! [String: Any]
        let right = try! JSONSerialization.jsonObject(with: encoder.encode(current)) as! [String: Any]
        func keys(_ a: [String: Any], _ b: [String: Any]) -> [String] {
            Set(a.keys).union(b.keys).filter { (a[$0] as? NSObject)?.isEqual(b[$0]) != true }.sorted()
        }
        var fields = keys(left, right).map { "snapshot." + $0 }
        let oldRows = Dictionary(uniqueKeysWithValues: (left["sessions"] as! [[String: Any]]).map { ($0["id"] as! String, $0) })
        for row in right["sessions"] as! [[String: Any]] {
            let id = row["id"] as! String
            fields += keys(oldRows[id] ?? [:], row).map { id + "." + $0 }
        }
        return fields
    }
    static func noticeCount(_ snapshot: EngineSnapshot) -> Int {
        snapshot.sessions.reduce(0) { $0 + ($1.notices?.count ?? 0) }
    }
    @MainActor static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), rounds = 24
        // Build the same inputs before timing both storage representations.
        let variants = (0...rounds).map { variant in (0..<16).map { screen($0, variant: variant) } }
        var workloads: [[String: Any]] = []
        for cocoa in [false, true] {
            let frames = Frames(cocoa: cocoa)
            let adapter = ScreenHostAdapter(screens: { frames.read($0) }, approve: { _, _, _ in fatalError("Benchmark must never send input") }, reveal: { _ in nil })
            let engine = try ApprovalEngine(paths: AppPaths(directory: root.appendingPathComponent(cocoa ? "cocoa" : "native")),
                claudeRegistryReader: { _ in [] }, processReader: { [] }, screenAdapters: [.terminal: adapter])
            defer { engine.stop() }
            let sessions = (0..<16).map { index in
                AgentSession(id: "process:\(900_000 + index):match", agent: index.isMultiple(of: 2) ? .codex : .claude,
                    pid: Int32(900_000 + index), started: "match", tty: "/dev/fixture-match-\(index)", cwd: root.path, terminal: .terminal)
            }
            engine.updateDiscovery(sessions, records: [])
            frames.replace(variants[0]); await engine.connectScreenHost(.terminal)
            // Settle the real 0.8-second notices and two-second idle confirmation
            // outside timing, so both binaries perform exactly the same work.
            try await Task.sleep(nanoseconds: 2_100_000_000)
            await engine.refreshScreenHost(.terminal)
            try check(engine.snapshot.idleCount == 4 && noticeCount(engine.snapshot) == 8, "Initial time-based state did not settle")
            var publications = 0, idlePublications: [Int] = [], noticePublications: [Int] = [], diagnostics: [[String]] = []
            var changing = false, previousSnapshot = engine.snapshot
            let subscription = engine.$snapshot.dropFirst().sink { snapshot in
                publications += 1
                idlePublications.append(snapshot.idleCount)
                noticePublications.append(noticeCount(snapshot))
                if !changing && snapshot.idleCount + noticeCount(snapshot) <= previousSnapshot.idleCount + noticeCount(previousSnapshot) {
                    diagnostics.append(changedFields(previousSnapshot, snapshot))
                }
                previousSnapshot = snapshot
            }
            defer { subscription.cancel() }
            for changed in [false, true] {
                publications = 0; idlePublications = []; noticePublications = []; diagnostics = []; changing = changed
                let initialIdleCount = engine.snapshot.sessions.filter { $0.phase == .idle }.count
                let initialNoticeCount = noticeCount(engine.snapshot)
                let startCPU = cpu(), startWall = ProcessInfo.processInfo.systemUptime
                for round in 0..<rounds {
                    if changed { frames.replace(variants[round + 1]) }
                    await engine.refreshScreenHost(.terminal)
                }
                workloads.append(["storage": cocoa ? "cocoa" : "native", "changed": changed,
                    "rounds": rounds, "sessions": 16, "bytesPerScreen": variants[0][0].contents.utf8.count,
                    "cpuSeconds": cpu() - startCPU, "wallSeconds": ProcessInfo.processInfo.systemUptime - startWall,
                    "publications": publications, "initialIdleCount": initialIdleCount, "initialNoticeCount": initialNoticeCount,
                    "idlePublications": idlePublications, "noticePublications": noticePublications])
                let phases = Dictionary(grouping: engine.snapshot.sessions, by: { $0.phase.rawValue }).mapValues(\.count)
                try check(phases["working"] == 4 && phases["approval"] == 4 && phases["input"] == 4, "Incorrect phases: \(phases)")
                try check(engine.snapshot.sessions.count == 16 && engine.snapshot.sessions.allSatisfy { !$0.automatic }, "Original sessions or policy changed")
                try check(engine.snapshot.events.isEmpty, "Polling sent input or generated audit events")
                if changed { try check(publications <= rounds, "Changing polls published more than once per round") }
                else {
                    try check(publications == 0,
                        "Settled unchanged polls published: initial \(initialIdleCount)/\(initialNoticeCount), idle \(idlePublications), notices \(noticePublications), fields \(diagnostics)")
                }
            }
            // Cached parsing must still honor a fresh generation and elapsed time.
            let now = Date()
            for index in 4..<8 {
                for seconds in [0.0, 1.0, 2.0] {
                    engine.receiveScreen(sessionID: sessions[index].id, raw: variants[0][index].contents,
                        generation: "fresh:" + sessions[index].id, at: now.addingTimeInterval(seconds))
                    let current = engine.snapshot.sessions.first { $0.id == sessions[index].id }
                    try check(current?.phase == (seconds < 2 ? .unknown : .idle), "Cached text bypassed the new generation's idle confirmation")
                }
            }
            try check(engine.snapshot.sessions.filter { $0.phase == .idle }.count == 4, "Unchanged frames lost time-based idle confirmation")
            try check(cocoa ? frames.foreignReads == (rounds * 2 + 2) * 16 : frames.foreignReads == 0, "Incorrect storage representation")
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = ["workloads": workloads, "peakResidentBytes": usage.ru_maxrss,
            "bodyChange": CommandLine.arguments.contains("--body-change"),
            "preserved": ["16 exact sessions", "working, approval and question phases", "idle confirmation", "no input", "no audit events", "bounded publications", "actual foreign Cocoa strings"],
            "scope": "Actual production Core engine with isolated synthetic screen source; not whole-app or LAN latency."]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: .sortedKeys), as: UTF8.self))
    }
}
