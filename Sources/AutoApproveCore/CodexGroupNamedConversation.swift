import CSQLite
import Foundation

/// A tab title can identify a root conversation only in the home and working
/// directory of that TUI. Read names, never message text or picker previews.
enum CodexGroupNamedConversation {
    static func lookup(title: String, cwd: String, home: String) -> String? {
        guard let name = CodexProfileConversationBinding.terminalName(title, cwd: cwd),
              let db = try? CodexHistoryAccess.open(URL(fileURLWithPath: home).appendingPathComponent("state_5.sqlite").path,
                                                    subject: "대화 이름") else { return nil }
        defer { sqlite3_close_v2(db) }
        var statement: OpaquePointer?
        let sql = "SELECT id, name FROM threads WHERE cwd = ? AND archived = 0 AND name IS NOT NULL"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, cwd, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { return nil }
        var matches: [CodexQueueConversation] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 1), String(cString: raw) == name,
               let id = sqlite3_column_text(statement, 0) {
                matches.append(.init(id: String(cString: id), title: name, name: name))
                if matches.count > 1 { return nil }
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { return nil }
        return CodexProfileConversationBinding.match(title: title, cwd: cwd, conversations: matches)?.id
    }

    static func title(in frame: TerminalScreen, cwd: String) -> String? {
        guard !frame.contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !CodexStatusIdentity.isWelcomeReset(frame.contents),
              let title = frame.title, CodexProfileConversationBinding.terminalName(title, cwd: cwd) != nil else { return nil }
        return title
    }
}
