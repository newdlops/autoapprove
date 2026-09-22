import Foundation
import CSQLite

/// A query can fail while Codex updates its database; that is not a schema change.
public struct CodexHistoryReadError: LocalizedError {
    public enum Kind: Equatable { case temporary, notReady, unsupportedSchema, unavailable, invalidData, readFailure }
    public let kind: Kind
    public let sqliteCode: Int32?
    private let subject: String

    init(_ kind: Kind, subject: String, sqliteCode: Int32? = nil) {
        self.kind = kind; self.subject = subject; self.sqliteCode = sqliteCode
    }

    var isTemporary: Bool { kind == .temporary || kind == .notReady }

    public var errorDescription: String? {
        switch kind {
        case .temporary:
            return "Codex \(subject) 기록을 갱신 중입니다. 잠시 후 자동으로 다시 확인합니다."
        case .notReady:
            return "Codex가 \(subject) 기록을 준비 중입니다. 잠시 후 자동으로 다시 확인합니다."
        case .unsupportedSchema:
            return "Codex \(subject) 기록 형식을 지원하지 않습니다. Codex 버전을 확인해주세요."
        case .unavailable:
            return "Codex \(subject) 기록을 열지 못했습니다. 파일 접근과 Codex 연결을 확인해주세요."
        case .invalidData:
            return "Codex \(subject) 기록의 내용을 읽지 못했습니다. 다음 갱신에서 다시 확인합니다."
        case .readFailure:
            return "Codex \(subject) 기록을 읽지 못했습니다. 자동으로 다시 확인합니다. (SQLite \(sqliteCode ?? SQLITE_ERROR))"
        }
    }
}

enum CodexHistoryAccess {
    static func open(_ path: String, subject: String) throws -> OpaquePointer {
        var db: OpaquePointer?
        let result = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let connection = db else {
            let error = failure(db, subject: subject, result: result)
            sqlite3_close(db)
            throw error
        }
        sqlite3_busy_timeout(connection, 250)
        return connection
    }

    static func failure(_ db: OpaquePointer?, subject: String, result: Int32) -> CodexHistoryReadError {
        let code = db.map { sqlite3_extended_errcode($0) } ?? result
        let message = db.map { String(cString: sqlite3_errmsg($0)).lowercased() } ?? ""
        let kind: CodexHistoryReadError.Kind
        switch code & 0xff {
        case SQLITE_BUSY, SQLITE_LOCKED, SQLITE_SCHEMA: kind = .temporary
        case SQLITE_CANTOPEN, SQLITE_PERM, SQLITE_AUTH, SQLITE_READONLY: kind = .unavailable
        case SQLITE_ERROR where ["no such table:", "no such column:", "no such function:"].contains(where: message.contains):
            kind = .unsupportedSchema
        default: kind = .readFailure
        }
        return CodexHistoryReadError(kind, subject: subject, sqliteCode: code)
    }
}

/// Polling already retries every refresh. Brief contention stays quiet, while a
/// persistent problem becomes visible after three consecutive failed reads.
private struct CodexReadRecovery {
    private var failures = 0
    mutating func succeeded() { failures = 0 }
    mutating func failed(_ error: Error) -> String? {
        failures = min(failures + 1, 3)
        if let error = error as? CodexHistoryReadError, error.isTemporary, failures < 3 { return nil }
        return error.localizedDescription
    }
}

/// Independent question/completion reads preserve the last successful question
/// snapshot and never mistake a failed read for an empty queue or a completion.
public final class CodexSessionHistoryReader {
    private let questions = CodexHistoryReader()
    private var location: CodexThreadLocation?
    private var questionRecovery = CodexReadRecovery()
    private var completionRecovery = CodexReadRecovery()
    public init() {}

    public func read(sessionID: String, location: CodexThreadLocation) -> CodexQuestionUpdate {
        if self.location != location {
            questionRecovery = CodexReadRecovery(); completionRecovery = CodexReadRecovery()
            self.location = location
        }
        var update = CodexQuestionUpdate(sessionID: sessionID, questions: nil, threadID: location.threadID)
        do {
            update.questions = try questions.read(location)
            questionRecovery.succeeded()
        } catch { update.error = questionRecovery.failed(error) }
        do {
            update.turn = try CodexTurnReader.read(location)
            completionRecovery.succeeded()
        } catch {
            update.completionReadPending = true
            update.completionError = completionRecovery.failed(error)
        }
        return update
    }
}
