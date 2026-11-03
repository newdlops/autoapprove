import Foundation
import CryptoKit
import CSQLite
import Darwin

// Owned feasibility only. No IPC/UI binding exists. The future coordinator must
// prove source writer quiescence and bind the exact CLI/server identities before
// calling this store; a SQLite snapshot alone is not a migration authorization.
struct CodexGoalTransferRow:Codable,Equatable,Sendable {
    let threadID:String,goalID:String,objective:String,status:String
    let tokenBudget:Int64?
    let tokensUsed:Int64,timeUsedSeconds:Int64,createdAtMs:Int64,updatedAtMs:Int64
}
struct CodexGoalTransferSnapshot:Codable,Equatable,Sendable {
    let formatVersion:Int
    let sourceHome:String,homeIdentity:String,databaseIdentity:String,schemaFingerprint:String
    let row:CodexGoalTransferRow
    let continuationDeferred:Bool
    let digest:String
    fileprivate struct Payload:Codable {
        let formatVersion:Int
        let sourceHome:String,homeIdentity:String,databaseIdentity:String,schemaFingerprint:String
        let row:CodexGoalTransferRow
        let continuationDeferred:Bool
    }
    fileprivate var payload:Payload {.init(formatVersion:formatVersion,sourceHome:sourceHome,homeIdentity:homeIdentity,databaseIdentity:databaseIdentity,schemaFingerprint:schemaFingerprint,row:row,continuationDeferred:continuationDeferred)}
    fileprivate static func hash<T:Encodable>(_ value:T) throws ->String {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        return SHA256.hash(data:try encoder.encode(value)).map{String(format:"%02x",$0)}.joined()
    }
    fileprivate init(home:String,homeIdentity:String,identity:String,schema:String,row:CodexGoalTransferRow,deferred:Bool) throws {
        formatVersion=2;sourceHome=home;self.homeIdentity=homeIdentity;databaseIdentity=identity;schemaFingerprint=schema
        self.row=row;continuationDeferred=deferred
        digest=try Self.hash(Payload(formatVersion:2,sourceHome:home,homeIdentity:homeIdentity,databaseIdentity:identity,schemaFingerprint:schema,row:row,continuationDeferred:deferred))
    }
}

// An absent Goal is a witnessed state, not a missing observation. This record
// is suitable for a future retired-owner receipt, but grants no overwrite or
// native migration authority by itself.
struct CodexGoalTransferSlot:Codable,Equatable,Sendable {
    let formatVersion:Int
    let sourceHome:String,homeIdentity:String,databaseIdentity:String,schemaFingerprint:String,threadID:String
    let row:CodexGoalTransferRow?
    let continuationDeferred:Bool
    let digest:String
    private struct Payload:Codable {
        let formatVersion:Int
        let sourceHome:String,homeIdentity:String,databaseIdentity:String,schemaFingerprint:String,threadID:String
        let row:CodexGoalTransferRow?
        let continuationDeferred:Bool
    }
    private var payload:Payload {.init(formatVersion:formatVersion,sourceHome:sourceHome,homeIdentity:homeIdentity,databaseIdentity:databaseIdentity,schemaFingerprint:schemaFingerprint,threadID:threadID,row:row,continuationDeferred:continuationDeferred)}
    fileprivate init(home:String,homeIdentity:String,identity:String,schema:String,threadID:String,row:CodexGoalTransferRow?,deferred:Bool)throws {
        formatVersion=1;sourceHome=home;self.homeIdentity=homeIdentity;databaseIdentity=identity;schemaFingerprint=schema
        self.threadID=threadID;self.row=row;continuationDeferred=deferred
        digest=try CodexGoalTransferSnapshot.hash(Payload(formatVersion:1,sourceHome:home,homeIdentity:homeIdentity,databaseIdentity:identity,schemaFingerprint:schema,threadID:threadID,row:row,continuationDeferred:deferred))
    }
    fileprivate func validate()throws {
        guard formatVersion==1,UUID(uuidString:threadID)?.uuidString.lowercased()==threadID,
              row.map({$0.threadID==threadID}) ?? !continuationDeferred,
              digest == (try CodexGoalTransferSnapshot.hash(payload)) else{
            throw AppError.message("Goal 이관의 존재·부재 기록을 확인하지 못했습니다. 원본을 유지했습니다.")
        }
    }
}

enum CodexGoalTransferStore {
    private enum Cell:Equatable {case text(String),integer(Int64),null}
    private static var failure:AppError {.message("Goal 이관 기록의 신원·형식·상태가 바뀌었습니다. 기존 기록을 유지하고 다시 확인해주세요.")}
    private static let columns="thread_id,goal_id,objective,status,token_budget,tokens_used,time_used_seconds,created_at_ms,updated_at_ms"
    private static let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    private static func normalized(_ sql:String)->String {sql.split(whereSeparator:{$0.isWhitespace}).joined(separator:" ")}
    // Exact schema observed from owned installed Codex 0.166.0. Unknown schema
    // objects or migration versions are rejected, including added triggers.
    private static let definitions:[String:String]=[
        "_sqlx_migrations":"CREATE TABLE _sqlx_migrations ( version BIGINT PRIMARY KEY, description TEXT NOT NULL, installed_on TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, success BOOLEAN NOT NULL, checksum BLOB NOT NULL, execution_time BIGINT NOT NULL )",
        "thread_goals":"CREATE TABLE thread_goals ( thread_id TEXT PRIMARY KEY NOT NULL, goal_id TEXT NOT NULL, objective TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN ( 'active', 'paused', 'blocked', 'usage_limited', 'budget_limited', 'complete' )), token_budget INTEGER, tokens_used INTEGER NOT NULL DEFAULT 0, time_used_seconds INTEGER NOT NULL DEFAULT 0, created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL )",
        "thread_goal_continuation_deferrals":"CREATE TABLE thread_goal_continuation_deferrals ( thread_id TEXT PRIMARY KEY NOT NULL REFERENCES thread_goals(thread_id) ON DELETE CASCADE )"
    ]
    private static let migrations:[String]=[
        "1","thread goals","1","8CE6280244A0B4B39C7C37C7F67AFF1670EC963D2401CDF2ABCFEA9904102DB6CD99B7BEDF366267791A45EB12F17713",
        "2","thread goal continuation deferrals","1","F3FF7DE2FD89914820BEF371081E885FD17DF18A6FBDC432399A83255A8A01AA32FB7EEA5E4DE21A17BDA3DA16C49584"
    ]
    private final class Connection {
        let db:OpaquePointer,path:String,identity:String
        private var closed=false
        init(home:String,writable:Bool) throws {
            path=home+"/goals_1.sqlite";identity=try CodexGoalTransferStore.identity(path)
            var pointer:OpaquePointer?
            let flags=(writable ? SQLITE_OPEN_READWRITE:SQLITE_OPEN_READONLY)|SQLITE_OPEN_FULLMUTEX|SQLITE_OPEN_NOFOLLOW
            let opened=sqlite3_open_v2(path,&pointer,flags,nil)
            guard opened==SQLITE_OK,let pointer else {sqlite3_close(pointer);throw AppError.message("Goal transfer: SQLite open \(opened)")}
            db=pointer;sqlite3_busy_timeout(db,250);sqlite3_limit(db,SQLITE_LIMIT_LENGTH,524288)
            do{
                try check();try exec("PRAGMA trusted_schema=OFF");try exec("PRAGMA foreign_keys=ON")
                if writable {
                    try exec("PRAGMA synchronous=FULL");try exec("PRAGMA fullfsync=ON")
                    guard try rows("PRAGMA synchronous")==[[.integer(2)]],try rows("PRAGMA fullfsync")==[[.integer(1)]] else{throw failure}
                }
            }
            catch{close();throw error}
        }
        deinit{close()}
        private func close(){if !closed{closed=true;sqlite3_close(db)}}
        func check() throws {guard try CodexGoalTransferStore.identity(path)==identity else{throw failure}}
        func statement(_ sql:String,_ cells:[Cell]) throws ->OpaquePointer {
            var statement:OpaquePointer?
            guard sqlite3_prepare_v2(db,sql,-1,&statement,nil)==SQLITE_OK,let statement else {sqlite3_finalize(statement);throw failure}
            do {
                for (index,value) in cells.enumerated() {
                    let result:Int32
                    switch value {
                    case .null:result=sqlite3_bind_null(statement,Int32(index+1))
                    case .integer(let number):result=sqlite3_bind_int64(statement,Int32(index+1),number)
                    case .text(let text):result=text.withCString{sqlite3_bind_text(statement,Int32(index+1),$0,Int32(text.utf8.count),transient)}
                    }
                    guard result==SQLITE_OK else{throw failure}
                }
                return statement
            }catch{sqlite3_finalize(statement);throw error}
        }
        func exec(_ sql:String,_ cells:[Cell]=[]) throws {
            let statement=try statement(sql,cells);defer{sqlite3_finalize(statement)}
            let step=sqlite3_step(statement)
            guard step==SQLITE_DONE else{throw AppError.message("Goal transfer: SQLite command \(step)")}
        }
        func rows(_ sql:String,_ cells:[Cell]=[]) throws ->[[Cell]] {
            let statement=try statement(sql,cells);defer{sqlite3_finalize(statement)}
            var rows:[[Cell]]=[]
            while true {
                let step=sqlite3_step(statement);if step==SQLITE_DONE{return rows}
                guard step==SQLITE_ROW,rows.count<16 else{throw failure}
                var row:[Cell]=[]
                for column in 0..<sqlite3_column_count(statement) {
                    switch sqlite3_column_type(statement,column) {
                    case SQLITE_NULL:row.append(.null)
                    case SQLITE_INTEGER:row.append(.integer(sqlite3_column_int64(statement,column)))
                    case SQLITE_TEXT:
                        let count=Int(sqlite3_column_bytes(statement,column))
                        guard count<=256000,let pointer=sqlite3_column_text(statement,column),
                              let text=String(data:Data(bytes:pointer,count:count),encoding:.utf8) else{throw failure}
                        row.append(.text(text))
                    default:throw failure
                    }
                }
                rows.append(row)
            }
        }
    }
    private static func identity(_ path:String) throws ->String {
        var info=stat()
        guard lstat(path,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),info.st_mode&0o022==0 else{throw AppError.message("Goal transfer: database file identity or permissions")}
        return "\(info.st_dev):\(info.st_ino)"
    }
    private static func physicalHome(_ value:String) throws ->String {
        let validated=try CodexAccountTransitionTarget.canonicalHome(value)
        guard let pointer=realpath(validated,nil) else{throw failure}
        defer{free(pointer)}
        let home=String(cString:pointer)
        var info=stat()
        guard lstat(home,&info)==0,info.st_mode&S_IFMT==S_IFDIR,info.st_uid==getuid() else{throw failure}
        return home
    }
    private static func homeIdentity(_ home:String)throws->String {
        var info=stat()
        guard lstat(home,&info)==0,info.st_mode&S_IFMT==S_IFDIR,info.st_uid==getuid() else{throw failure}
        return "\(info.st_dev):\(info.st_ino)"
    }
    private static func text(_ value:Cell) throws ->String {guard case .text(let text)=value else{throw failure};return text}
    private static func integer(_ value:Cell) throws ->Int64 {guard case .integer(let number)=value else{throw failure};return number}
    private static func schema(_ connection:Connection) throws ->String {
        guard try connection.rows("PRAGMA user_version")==[[.integer(0)]],
              try connection.rows("PRAGMA application_id")==[[.integer(0)]] else{throw AppError.message("Goal transfer: schema version mismatch")}
        let rows=try connection.rows("SELECT type,name,tbl_name,sql FROM sqlite_master WHERE substr(name,1,7) != 'sqlite_' ORDER BY name")
        guard rows.count==definitions.count else{throw AppError.message("Goal transfer: schema object count mismatch")}
        var normalizedRows:[String]=[]
        for row in rows {
            guard row.count==4,try text(row[0])=="table" else{throw failure}
            let name=try text(row[1]),sql=try normalized(text(row[3]))
            guard try text(row[2])==name,definitions[name]==sql else{throw AppError.message("Goal transfer: schema definition mismatch")}
            normalizedRows.append(contentsOf:[name,sql])
        }
        let versions=try connection.rows("SELECT CAST(version AS TEXT),description,CAST(success AS TEXT),hex(checksum) FROM _sqlx_migrations ORDER BY version")
        let actual=try versions.flatMap{try $0.map(text)}
        guard actual==migrations else{throw AppError.message("Goal transfer: schema migration mismatch")}
        return try CodexGoalTransferSnapshot.hash(normalizedRows+actual)
    }
    private static func row(_ connection:Connection,_ threadID:String) throws ->(CodexGoalTransferRow?,Bool) {
        let rows=try connection.rows("SELECT \(columns) FROM thread_goals WHERE thread_id=? LIMIT 2",[.text(threadID)])
        let deferred=try connection.rows("SELECT thread_id FROM thread_goal_continuation_deferrals WHERE thread_id=? LIMIT 2",[.text(threadID)])
        guard rows.count<=1,deferred.count<=1 else{throw failure}
        guard let values=rows.first else{guard deferred.isEmpty else{throw failure};return(nil,false)}
        guard values.count==9 else{throw failure}
        let budget:Int64?=values[4] == .null ? nil:try integer(values[4])
        let value=try CodexGoalTransferRow(threadID:text(values[0]),goalID:text(values[1]),objective:text(values[2]),status:text(values[3]),tokenBudget:budget,tokensUsed:integer(values[5]),timeUsedSeconds:integer(values[6]),createdAtMs:integer(values[7]),updatedAtMs:integer(values[8]))
        guard value.threadID==threadID,!value.goalID.isEmpty,value.goalID.utf8.count<=256,
              ["paused","blocked","usage_limited","budget_limited","complete"].contains(value.status),
              value.tokensUsed>=0,value.timeUsedSeconds>=0,value.tokenBudget.map({$0>=0}) ?? true,
              value.createdAtMs>=0,value.updatedAtMs>=value.createdAtMs else{throw failure}
        return(value,!deferred.isEmpty)
    }
    static func capture(home:String,threadID:String) throws ->CodexGoalTransferSnapshot? {
        let slot=try captureSlot(home:home,threadID:threadID)
        return try slot.row.map{try .init(home:slot.sourceHome,homeIdentity:slot.homeIdentity,identity:slot.databaseIdentity,schema:slot.schemaFingerprint,row:$0,deferred:slot.continuationDeferred)}
    }
    static func captureSlot(home:String,threadID:String)throws->CodexGoalTransferSlot {
        try Task.checkCancellation()
        guard let uuid=UUID(uuidString:threadID) else{throw failure}
        let home=try physicalHome(home),id=uuid.uuidString.lowercased()
        let homeID=try homeIdentity(home)
        let connection=try Connection(home:home,writable:false)
        try connection.exec("BEGIN");var committed=false;defer{if !committed{try? connection.exec("ROLLBACK")}}
        let fingerprint=try schema(connection),entry=try row(connection,id)
        guard try homeIdentity(home)==homeID else{throw failure}
        try connection.check();try Task.checkCancellation()
        try connection.exec("COMMIT");committed=true;try connection.check()
        guard try homeIdentity(home)==homeID else{throw failure}
        return try .init(home:home,homeIdentity:homeID,identity:connection.identity,schema:fingerprint,threadID:id,row:entry.0,deferred:entry.1)
    }
    static func verifyCurrent(_ slot:CodexGoalTransferSlot)throws {
        try slot.validate()
        guard try captureSlot(home:slot.sourceHome,threadID:slot.threadID)==slot else{throw failure}
    }
    static func restore(_ snapshot:CodexGoalTransferSnapshot,toHome:String,expectedSchema:String) throws {
        try Task.checkCancellation()
        let home=try physicalHome(toHome)
        guard home != snapshot.sourceHome,snapshot.formatVersion==2,expectedSchema==snapshot.schemaFingerprint,
              snapshot.digest == (try CodexGoalTransferSnapshot.hash(snapshot.payload)),
              try capture(home:snapshot.sourceHome,threadID:snapshot.row.threadID)==snapshot else{throw failure}
        let connection=try Connection(home:home,writable:true)
        try connection.exec("BEGIN IMMEDIATE");var committed=false;defer{if !committed{try? connection.exec("ROLLBACK")}}
        guard try schema(connection)==expectedSchema,try row(connection,snapshot.row.threadID).0==nil else{throw failure}
        let v=snapshot.row
        try connection.exec("INSERT INTO thread_goals (\(columns)) VALUES (?,?,?,?,?,?,?,?,?)",[.text(v.threadID),.text(v.goalID),.text(v.objective),.text(v.status),v.tokenBudget.map(Cell.integer) ?? .null,.integer(v.tokensUsed),.integer(v.timeUsedSeconds),.integer(v.createdAtMs),.integer(v.updatedAtMs)])
        if snapshot.continuationDeferred{try connection.exec("INSERT INTO thread_goal_continuation_deferrals(thread_id) VALUES (?)",[.text(v.threadID)])}
        let inserted=try row(connection,v.threadID)
        guard inserted.0==v,inserted.1==snapshot.continuationDeferred,
              try capture(home:snapshot.sourceHome,threadID:v.threadID)==snapshot else{throw failure}
        try Task.checkCancellation();try connection.check();try connection.exec("COMMIT");committed=true
    }
    // The return coordinator must durably reserve/attempt the exact backed-up
    // retirement before calling this. BEGIN IMMEDIATE protects the exact-row
    // comparison and replacement as one transaction; arbitrary upsert is absent.
    static func replaceRetired(_ source:CodexGoalTransferSlot,expected:CodexGoalTransferSlot,verifyAuthority:()throws->Void)throws {
        try source.validate();try expected.validate();try verifyAuthority()
        guard source.threadID==expected.threadID,source.sourceHome != expected.sourceHome,
              source.schemaFingerprint==expected.schemaFingerprint,
              try physicalHome(expected.sourceHome)==expected.sourceHome,
              try homeIdentity(expected.sourceHome)==expected.homeIdentity else{throw failure}
        try verifyCurrent(source)
        let connection=try Connection(home:expected.sourceHome,writable:true)
        guard connection.identity==expected.databaseIdentity else{throw failure}
        try connection.exec("BEGIN IMMEDIATE");var committed=false;defer{if !committed{try? connection.exec("ROLLBACK")}}
        let current=try row(connection,source.threadID)
        guard try schema(connection)==expected.schemaFingerprint,current.0==expected.row,current.1==expected.continuationDeferred else{throw failure}
        try connection.exec("DELETE FROM thread_goal_continuation_deferrals WHERE thread_id=?",[.text(source.threadID)])
        try connection.exec("DELETE FROM thread_goals WHERE thread_id=?",[.text(source.threadID)])
        if let v=source.row {
            try connection.exec("INSERT INTO thread_goals (\(columns)) VALUES (?,?,?,?,?,?,?,?,?)",[.text(v.threadID),.text(v.goalID),.text(v.objective),.text(v.status),v.tokenBudget.map(Cell.integer) ?? .null,.integer(v.tokensUsed),.integer(v.timeUsedSeconds),.integer(v.createdAtMs),.integer(v.updatedAtMs)])
            if source.continuationDeferred{try connection.exec("INSERT INTO thread_goal_continuation_deferrals(thread_id) VALUES (?)",[.text(source.threadID)])}
        }
        let changed=try row(connection,source.threadID)
        guard changed.0==source.row,changed.1==source.continuationDeferred else{throw failure}
        try verifyAuthority();try verifyCurrent(source);try connection.check()
        guard try homeIdentity(expected.sourceHome)==expected.homeIdentity else{throw failure}
        try Task.checkCancellation();try connection.exec("COMMIT");committed=true
    }
}
