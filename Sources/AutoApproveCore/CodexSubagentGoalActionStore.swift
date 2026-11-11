import Foundation
import CSQLite
import Darwin

public struct CodexSubagentGoalReceipt:Codable,Sendable {
    public enum Phase:String,Codable,Sendable {case reserved,confirmed,unknown,notStarted}
    public let requestID:UUID
    public let binding:String
    public var phase:Phase
    public var result:CodexSubagentGoal?
    public var detail:String
    public init(requestID:UUID,binding:String,phase:Phase,result:CodexSubagentGoal?=nil,detail:String) {
        self.requestID=requestID;self.binding=binding;self.phase=phase;self.result=result;self.detail=detail
    }
}

/// A durable request ID is reserved before dispatch. A repeated ID is read-only,
/// including after a crash or a lost acknowledgement; it never dispatches again.
final class CodexSubagentGoalActionStore {
    private var db:OpaquePointer?
    private let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    private var failure:AppError {.message("서브에이전트 Goal 요청 기록을 저장하거나 확인하지 못했습니다.")}
    init(path:String) throws {
        // macOS exposes its temporary directory through /var -> /private/var.
        // Resolve the parent only; the ledger itself must never be a symlink.
        let file=URL(fileURLWithPath:path)
        guard let parent=realpath(file.deletingLastPathComponent().path,nil) else {throw failure}
        defer {free(parent)}
        let physical=URL(fileURLWithPath:String(cString:parent)).appendingPathComponent(file.lastPathComponent).path
        guard sqlite3_open_v2(physical,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX|SQLITE_OPEN_NOFOLLOW,nil)==SQLITE_OK else {sqlite3_close(db);db=nil;throw failure}
        sqlite3_busy_timeout(db,250)
        do {try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; CREATE TABLE IF NOT EXISTS goal_actions(id TEXT PRIMARY KEY NOT NULL,json BLOB NOT NULL)")}
        catch {sqlite3_close(db);db=nil;throw error}
    }
    deinit {sqlite3_close(db)}
    private func execute(_ sql:String) throws {guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else {throw failure}}
    func read(_ id:UUID) throws ->CodexSubagentGoalReceipt? {
        var statement:OpaquePointer?;defer{sqlite3_finalize(statement)}
        guard sqlite3_prepare_v2(db,"SELECT json FROM goal_actions WHERE id=?",-1,&statement,nil)==SQLITE_OK else {throw failure}
        sqlite3_bind_text(statement,1,id.uuidString,-1,transient)
        let step=sqlite3_step(statement)
        if step==SQLITE_DONE {return nil}
        guard step==SQLITE_ROW,sqlite3_column_type(statement,0)==SQLITE_BLOB,
              let bytes=sqlite3_column_blob(statement,0) else {throw failure}
        let size=Int(sqlite3_column_bytes(statement,0));guard size>0,size<=1_048_576 else {throw failure}
        let receipt=try JSONDecoder().decode(CodexSubagentGoalReceipt.self,from:Data(bytes:bytes,count:size))
        guard receipt.requestID==id else {throw failure};return receipt
    }
    func reserve(_ receipt:CodexSubagentGoalReceipt) throws {try write(receipt,insert:true)}
    func finish(_ receipt:CodexSubagentGoalReceipt) throws {try write(receipt,insert:false)}
    private func write(_ receipt:CodexSubagentGoalReceipt,insert:Bool) throws {
        guard insert ? receipt.phase == .reserved:receipt.phase != .reserved else {throw failure}
        let data=try JSONEncoder().encode(receipt);guard data.count<=1_048_576 else {throw failure}
        var statement:OpaquePointer?;defer{sqlite3_finalize(statement)}
        let sql=insert ? "INSERT INTO goal_actions(json,id) VALUES (?,?)":"UPDATE goal_actions SET json=? WHERE id=?"
        guard sqlite3_prepare_v2(db,sql,-1,&statement,nil)==SQLITE_OK else {throw failure}
        _=data.withUnsafeBytes{sqlite3_bind_blob(statement,1,$0.baseAddress,Int32(data.count),transient)}
        sqlite3_bind_text(statement,2,receipt.requestID.uuidString,-1,transient)
        guard sqlite3_step(statement)==SQLITE_DONE,sqlite3_changes(db)==1 else {throw failure}
    }
}
