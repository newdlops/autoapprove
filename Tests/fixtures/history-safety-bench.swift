import Foundation
import CSQLite
import Darwin
import AutoApproveCore

/// Synthetic files, a read-only history reader and command classification only.
/// Never opens a user history database, reads a user terminal or executes commands.
@main struct HistorySafetyBench {
    static func cpu() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func sql(_ connection: OpaquePointer?, _ text: String) throws {
        guard sqlite3_exec(connection, text, nil, nil, nil) == SQLITE_OK else { throw AppError.message("Synthetic SQL failed") }
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), day = root.appendingPathComponent("sessions/2026/10/15")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let rollout = day.appendingPathComponent("rollout-fixture.jsonl")
        var data = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": "fixture", "source": "cli"]])
        data.append(10); data.append(Data(repeating: 120, count: 2_097_152)); try data.write(to: rollout)
        let database = root.appendingPathComponent("thread_history_1.sqlite").path
        var db: OpaquePointer?; guard sqlite3_open(database, &db) == SQLITE_OK else { throw AppError.message("Synthetic database unavailable") }
        defer { sqlite3_close(db) }
        try sql(db, "CREATE TABLE thread_history_projection_state(thread_id TEXT PRIMARY KEY,next_rollout_ordinal INTEGER); CREATE TABLE thread_items(thread_id TEXT,item_id TEXT,rollout_ordinal INTEGER,item_type TEXT,updated_at_ordinal INTEGER,item_json TEXT); CREATE INDEX history_ord ON thread_items(thread_id,rollout_ordinal); INSERT INTO thread_history_projection_state VALUES('fixture',2002); BEGIN;")
        for ordinal in 1...2001 {
            let json: JSONObject = ordinal == 1
                ? ["type":"agentMessage","id":"question","delivery":"async","questions":[["title":"Which synthetic result?","options":["First","Second"]]]]
                : ["type":"userMessage","id":"message-\(ordinal)","content":[["type":"text","text":String(repeating:"Synthetic progress 한글 · ",count:12)]]]
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
            try sql(db, "INSERT INTO thread_items VALUES('fixture','item-\(ordinal)',\(ordinal),'\(ordinal == 1 ? "agentMessage" : "userMessage")',\(ordinal),'\(encoded)');")
        }
        try sql(db, "COMMIT;")
        let location = CodexThreadLocation(threadID: "fixture", database: database), reader = CodexHistoryReader()
        let questions = try reader.read(location)
        guard questions.count == 1, questions[0].hasLaterUserMessage == true else { throw AppError.message("Synthetic queue mismatch") }
        var reports: [[String: Any]] = []
        func measure(_ name: String, rounds: Int, _ body: () throws -> Int) rethrows {
            let start = Date(), beforeCPU = cpu(); var checksum = 0
            for _ in 0..<rounds { checksum += try body() }
            reports.append(["name":name,"rounds":rounds,"cpuSeconds":cpu()-beforeCPU,"wallSeconds":Date().timeIntervalSince(start),"checksum":checksum])
        }
        try measure("rollout-header", rounds: 100) { try CodexThreadLocation.locate(paths: [rollout.path]).threadID == "fixture" ? 1 : 0 }
        try measure("unchanged-history", rounds: 40) {
            let current = try reader.read(location)
            guard current == questions else { throw AppError.message("Unchanged history changed") }
            return current.count
        }
        let body = String(repeating: "synthetic ordinary report 한글 output ", count: 180)
        let commands = ["node tools/report.mjs --data '" + body + "'", "printf '" + body + "'",
            "python3 -c 'text=\"" + body + "\"'", "launchctl bootstrap gui/501 fixture.plist",
            "cp fixture ~/Library/LaunchA\ngents/com.fixture.plist", "defaults write com.fixture test 1"]
        try measure("system-risk", rounds: 30) {
            let kinds = commands.map { SystemCommandRisk.detect($0)?.kind }
            guard kinds == [nil,nil,nil,.persistence,.persistence,.settings] else { throw AppError.message("System guard changed") }
            return kinds.compactMap { $0 }.count
        }
        guard reports.map({ $0["checksum"] as! Int }) == [100,40,90] else { throw AppError.message("Synthetic checksum mismatch") }
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["workloads":reports], options: [.sortedKeys]), as: UTF8.self))
    }
}
