import Foundation
import CSQLite
import AutoApproveCore

private final class HistoryReadFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-history-read-" + UUID().uuidString)
    var db: OpaquePointer?
    var path: String { root.appendingPathComponent("history.sqlite").path }
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw AppError.message("Fixture database unavailable") }
        try sql("CREATE TABLE thread_history_projection_state(thread_id TEXT PRIMARY KEY,next_rollout_ordinal INTEGER); CREATE TABLE thread_items(thread_id TEXT,item_id TEXT,rollout_ordinal INTEGER,item_type TEXT,updated_at_ordinal INTEGER,item_json TEXT); INSERT INTO thread_history_projection_state VALUES('root',2),('other',2);")
    }
    deinit { sqlite3_close(db); try? FileManager.default.removeItem(at: root) }
    func sql(_ sql: String) throws { try expectEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK) }
    func question(_ title: String, thread: String = "root", ordinal: Int = 1) throws {
        let json: JSONObject = ["type":"agentMessage","id":"q-\(ordinal)","delivery":"async","questions":[["title":title,"options":["First","Second"]]]]
        let value = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
        try sql("INSERT INTO thread_items VALUES('\(thread)','q-\(ordinal)',\(ordinal),'agentMessage',\(ordinal),'\(value)');")
    }
}

extension ApprovalTests {
    func testRolloutHeaderStopsAtFirstLineAndKeepsByteLimit() throws {
        let header = Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"fixture\",\"source\":\"cli\"}}".utf8)
        let bytes = header + Data([10]) + Data(repeating: 120, count: 2_097_152)
        var offset = 0, calls = 0
        let actual = try CodexThreadLocation.readMetadataLine { count in
            calls += 1; let end = min(offset + count, bytes.count)
            defer { offset = end }; return bytes.subdata(in: offset..<end)
        }
        try expectEqual(actual, header); try expectEqual(calls, 1); try expectEqual(offset, 4096)
        let unicode = Data((String(repeating: "한글😀", count: 900) + "\r\nignored").utf8)
        var position = 0
        let long = try CodexThreadLocation.readMetadataLine { count in
            let end = min(position + count, unicode.count)
            defer { position = end }; return unicode.subdata(in: position..<end)
        }
        try expectEqual(long, Data(unicode.prefix { $0 != 10 }), "A split UTF-8 character and CR are retained byte-for-byte")
        let limit = 1_048_576
        for newline in [limit - 1, limit] {
            let source = Data(repeating: 120, count: newline) + Data([10])
            var consumed = 0
            let line = try CodexThreadLocation.readMetadataLine { count in
                try expect(consumed + count <= limit)
                let end = min(consumed + count, source.count)
                defer { consumed = end }; return source.subdata(in: consumed..<end)
            }
            try expectEqual(line?.count, newline == limit - 1 ? limit - 1 : nil)
            try expectEqual(consumed, limit)
        }
        try expectNil(try CodexThreadLocation.readMetadataLine { _ in nil })
        try expectNil(try CodexThreadLocation.readMetadataLine { _ in Data() })
        try expectNil(try CodexThreadLocation.readMetadataLine { count in Data(repeating: 120, count: count + 1) })
        try expectThrows(try CodexThreadLocation.readMetadataLine { _ in throw AppError.message("fixture read failure") })
    }

    func testRolloutBindingReadsFreshLongMetadataAndRejectsIncompleteHeaders() throws {
        let fixture = try HistoryReadFixture(), day = fixture.root.appendingPathComponent("sessions/2026/10/15")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("rollout-fixture.jsonl")
        func write(_ id: String, newline: Bool = true) throws {
            var data = try JSONSerialization.data(withJSONObject: ["type":"session_meta","payload":["id":id,"source":"cli","extra":String(repeating:"한글",count:1500)]])
            if newline { data.append(10); data.append(Data(repeating: 120, count: 1_048_576)) }
            try data.write(to: file)
        }
        try write("first"); try expectEqual(try CodexThreadLocation.locate(paths: [file.path]).threadID, "first")
        try write("second"); try expectEqual(try CodexThreadLocation.locate(paths: [file.path]).threadID, "second", "Never reuse a previous thread identity")
        try write("incomplete", newline: false); try expectThrows(try CodexThreadLocation.locate(paths: [file.path]))
        try Data([0xff, 10]).write(to: file); try expectThrows(try CodexThreadLocation.locate(paths: [file.path]))
    }

    func testUnchangedHistoryStillChecksUpdatesResetsAndFailures() throws {
        let fixture = try HistoryReadFixture(), reader = CodexHistoryReader()
        let root = CodexThreadLocation(threadID: "root", database: fixture.path), other = CodexThreadLocation(threadID: "other", database: fixture.path)
        try fixture.question("First question"); try fixture.question("Other thread", thread: "other")
        var copy = try reader.read(root); copy[0].title = "Caller edit"
        for _ in 0..<3 { try expectEqual(try reader.read(root).first?.title, "First question") }
        try fixture.sql("UPDATE thread_items SET item_json=replace(item_json,'First question','Updated question'),updated_at_ordinal=2 WHERE thread_id='root'; UPDATE thread_history_projection_state SET next_rollout_ordinal=3 WHERE thread_id='root';")
        try expectEqual(try reader.read(root).first?.title, "Updated question", "An old row's update invalidates the projection")
        try fixture.sql("INSERT INTO thread_items VALUES('root','answer',3,'userMessage',3,'{\"type\":\"userMessage\",\"content\":[{\"type\":\"text\",\"text\":\"> Updated question\\nFirst\"}]}'); UPDATE thread_history_projection_state SET next_rollout_ordinal=4 WHERE thread_id='root';")
        try expect(try reader.read(root).isEmpty)
        try expectEqual(try reader.read(other).first?.title, "Other thread")
        try expect(try reader.read(root).isEmpty, "A thread switch cannot reuse the other thread's questions")
        try fixture.sql("INSERT INTO thread_items VALUES('root','q-4',4,'agentMessage',4,'invalid JSON'); UPDATE thread_history_projection_state SET next_rollout_ordinal=5 WHERE thread_id='root';")
        try expectThrows(try reader.read(root))
        try fixture.sql("DELETE FROM thread_items WHERE item_id='q-4';")
        try fixture.question("After recovery", ordinal: 4)
        try expectEqual(try reader.read(root).first?.title, "After recovery", "A failed delta must not advance the cursor or cached result")
        try fixture.sql("DELETE FROM thread_items WHERE thread_id='root'; UPDATE thread_history_projection_state SET next_rollout_ordinal=1 WHERE thread_id='root';")
        try fixture.question("After reset", ordinal: 0)
        try expectEqual(try reader.read(root).first?.title, "After reset")
        try fixture.sql("DROP TABLE thread_items;")
        try expectThrows(try reader.read(root))
    }

    func testSystemRiskLazyVariantsRetainWhitespaceUnicodeAndFreshSource() throws {
        for separator in ["", "\n", "\n  ", "\r\n", "\t", "\u{00a0}", "\u{2007}"] {
            let text = "cp fixture ~/Library/Lau" + separator + "nchAgents/com.fixture.plist"
            try expectEqual(SystemCommandRisk.detect(text)?.kind, .persistence, text)
        }
        for text in ["cp fixture ~/Library/LaunchAgents/a.plist", "cp fixture ~/ Library / LaunchAgents /a.plist",
            "python3 -c 'Path.home().joinpath(\"Library/LaunchAgents/a.plist\").write_text(payload)'",
            "cp fixture /Users/한글/Library/LaunchAgents/a.plist"] {
            try expectEqual(SystemCommandRisk.detect(text)?.kind, .persistence)
        }
        try expectNil(SystemCommandRisk.detect("cat ~/Library/LaunchAgents/a.plist"))
        try expectNil(SystemCommandRisk.detect("node tools/report.mjs --text '" + String(repeating: "한글 ordinary output ", count: 200) + "'"))
        let fixture = try HistoryReadFixture(), file = fixture.root.appendingPathComponent("install_fixture.py")
        let command = "python3 install_fixture.py --install"
        try "print('synthetic safe source')".write(to: file, atomically: true, encoding: .utf8)
        try expectNil(SystemCommandRisk.detect(command, cwd: fixture.root.path))
        try "Path.home().joinpath('Library/LaunchAgents/com.fixture.plist').write_text(payload)".write(to: file, atomically: true, encoding: .utf8)
        try expectEqual(SystemCommandRisk.detect(command, cwd: fixture.root.path)?.kind, .persistence)
        try "print('synthetic safe source')".write(to: file, atomically: true, encoding: .utf8)
        try expectNil(SystemCommandRisk.detect(command, cwd: fixture.root.path))
    }
}
