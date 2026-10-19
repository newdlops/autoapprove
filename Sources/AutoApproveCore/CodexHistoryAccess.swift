import Foundation
import Darwin
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

    static func fileIdentity(_ path: String, subject: String) throws -> String {
        var value = stat()
        let result = path.withCString { fstatat(AT_FDCWD, $0, &value, 0) }
        guard result == 0 else { throw CodexHistoryReadError(.unavailable, subject: subject) }
        return "\(UInt64(value.st_dev)):\(UInt64(value.st_ino))"
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

/// Reuse a few read-only history connections across polling ticks. The bounded
/// SQLite page cache avoids reparsing hot index pages while keeping retained
/// memory predictable. Callers serialize access to this cache.
final class CodexHistoryConnectionCache {
    private struct Entry {
        let database: OpaquePointer
        let identity: String
        var lastUsed: UInt64
        var dataVersionStatement: OpaquePointer?
    }

    private let capacity: Int
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0

    init(capacity: Int = 4) { self.capacity = max(1, capacity) }

    deinit { closeAll() }

    func open(_ path: String, subject: String) throws -> OpaquePointer {
        let identity: String
        do { identity = try CodexHistoryAccess.fileIdentity(path, subject: subject) }
        catch {
            if let stale = entries.removeValue(forKey: path) { close(stale) }
            // Metadata access is only an optimization prerequisite. Preserve
            // the original open behavior when a filesystem hides file IDs.
            return try CodexHistoryAccess.open(path, subject: subject)
        }
        clock &+= 1
        if var entry = entries[path], entry.identity == identity {
            entry.lastUsed = clock
            entries[path] = entry
            return entry.database
        }
        if let old = entries.removeValue(forKey: path) { close(old) }

        let database = try CodexHistoryAccess.open(path, subject: subject)
        // This is connection-local and does not modify Codex's database file.
        sqlite3_exec(database, "PRAGMA cache_size=-1024", nil, nil, nil)
        entries[path] = Entry(database: database, identity: identity, lastUsed: clock, dataVersionStatement: nil)
        if entries.count > capacity,
           let leastRecentlyUsed = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key,
           let removed = entries.removeValue(forKey: leastRecentlyUsed) {
            close(removed)
        }
        return database
    }

    func identity(for path: String) -> String? { entries[path]?.identity }

    /// One scalar per database batch tells every session reader whether the
    /// shared Codex history changed since its last successful projection.
    func dataVersion(_ database: OpaquePointer) throws -> Int64 {
        guard let path = entries.first(where: { $0.value.database == database })?.key,
              var entry = entries[path] else {
            throw CodexHistoryReadError(.unavailable, subject: "질문")
        }
        if entry.dataVersionStatement == nil {
            var statement: OpaquePointer?
            let result = sqlite3_prepare_v2(database, "PRAGMA data_version", -1, &statement, nil)
            guard result == SQLITE_OK, let statement else {
                throw CodexHistoryAccess.failure(database, subject: "질문", result: result)
            }
            entry.dataVersionStatement = statement
            entries[path] = entry
        }
        guard let statement = entry.dataVersionStatement else {
            throw CodexHistoryReadError(.invalidData, subject: "질문")
        }
        sqlite3_reset(statement)
        let result = sqlite3_step(statement)
        defer { sqlite3_reset(statement) }
        guard result == SQLITE_ROW else { throw CodexHistoryAccess.failure(database, subject: "질문", result: result) }
        return sqlite3_column_int64(statement, 0)
    }

    private func close(_ entry: Entry) {
        if let statement = entry.dataVersionStatement { sqlite3_finalize(statement) }
        sqlite3_close_v2(entry.database)
    }

    func closeAll() {
        for entry in entries.values { close(entry) }
        entries.removeAll(keepingCapacity: false)
    }

    func retain(paths: Set<String>) {
        for path in Array(entries.keys) where !paths.contains(path) {
            if let removed = entries.removeValue(forKey: path) { close(removed) }
        }
    }

    var connectionCount: Int { entries.count }
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
    private let turnStatements = CodexTurnStatementCache()
    private var location: CodexThreadLocation?
    private var turnState: CodexTurnState?
    private var observedDatabase: OpaquePointer?
    private var observedDatabaseIdentity: String?
    private var lastDataVersion: Int64?
    private var lastSuccessfulUpdate: CodexQuestionUpdate?
    private var questionRecovery = CodexReadRecovery()
    private var completionRecovery = CodexReadRecovery()
#if DEBUG
    private(set) var debugDataVersionSkipCount = 0
#endif
    public init() {}

    func releaseConnection(unlessRetained paths: Set<String>) {
        guard let location, !paths.contains(location.database) else { return }
        questions.invalidatePreparedStatements()
        turnStatements.invalidate()
        observedDatabase = nil
        observedDatabaseIdentity = nil
        turnState = nil
        lastDataVersion = nil
        lastSuccessfulUpdate = nil
    }

    public func read(sessionID: String, location: CodexThreadLocation) -> CodexQuestionUpdate {
        if self.location != location {
            questionRecovery = CodexReadRecovery(); completionRecovery = CodexReadRecovery()
            turnState = nil
            observedDatabaseIdentity = nil
            lastDataVersion = nil; lastSuccessfulUpdate = nil
            self.location = location
        }
        lastDataVersion = nil; lastSuccessfulUpdate = nil
        var update = CodexQuestionUpdate(sessionID: sessionID, questions: nil, threadID: location.threadID)
        // Both projections use the same read-only database. Open it once per
        // refresh instead of paying two SQLite connection setup/teardown cycles
        // for every active Codex session.
        let db: OpaquePointer
        do { db = try CodexHistoryAccess.open(location.database, subject: "질문") }
        catch {
            update.error = questionRecovery.failed(error)
            // Keep question and completion failures independent even when the
            // shared connection itself could not be opened.
            do {
                let turnDB = try CodexHistoryAccess.open(location.database, subject: "작업 완료")
                defer { sqlite3_close_v2(turnDB) }
                update.turn = try CodexTurnReader.read(location, database: turnDB, previous: turnState, statements: turnStatements)
                turnState = update.turn
                completionRecovery.succeeded()
            } catch {
                update.completionReadPending = true
                update.completionError = completionRecovery.failed(error)
            }
            return update
        }
        defer { sqlite3_close_v2(db) }
        return read(sessionID: sessionID, location: location, database: db)
    }

    /// The collector can share one read-only SQLite connection across every
    /// Codex session backed by the same history database in this batch.
    func read(sessionID: String, location: CodexThreadLocation, database db: OpaquePointer,
              dataVersion: Int64? = nil, databaseIdentity: String? = nil) -> CodexQuestionUpdate {
        if self.location != location {
            questionRecovery = CodexReadRecovery(); completionRecovery = CodexReadRecovery()
            turnState = nil
            observedDatabaseIdentity = nil
            lastDataVersion = nil; lastSuccessfulUpdate = nil
            self.location = location
        }
        if let databaseIdentity, observedDatabaseIdentity != databaseIdentity {
            if observedDatabaseIdentity != nil || observedDatabase != nil {
                questions.resetProjection()
                turnStatements.invalidate()
                turnState = nil
            }
            observedDatabaseIdentity = databaseIdentity
            lastDataVersion = nil
            lastSuccessfulUpdate = nil
        }
        if observedDatabase != db {
            observedDatabase = db
            lastDataVersion = nil; lastSuccessfulUpdate = nil
        }
        if let dataVersion, lastDataVersion == dataVersion,
           let lastSuccessfulUpdate, lastSuccessfulUpdate.sessionID == sessionID {
#if DEBUG
            debugDataVersionSkipCount += 1
#endif
            return lastSuccessfulUpdate
        }
        if dataVersion == nil { lastDataVersion = nil; lastSuccessfulUpdate = nil }
        var update = CodexQuestionUpdate(sessionID: sessionID, questions: nil, threadID: location.threadID)
        do {
            update.questions = try questions.read(location, database: db)
            questionRecovery.succeeded()
        } catch { update.error = questionRecovery.failed(error) }
        do {
            update.turn = try CodexTurnReader.read(location, database: db, previous: turnState, statements: turnStatements)
            turnState = update.turn
            completionRecovery.succeeded()
        } catch {
            update.completionReadPending = true
            update.completionError = completionRecovery.failed(error)
        }
        if let dataVersion, update.questions != nil, update.error == nil, update.turn != nil,
           update.completionError == nil, !update.completionReadPending {
            lastDataVersion = dataVersion
            lastSuccessfulUpdate = update
        } else {
            lastDataVersion = nil
            lastSuccessfulUpdate = nil
        }
        return update
    }
}
