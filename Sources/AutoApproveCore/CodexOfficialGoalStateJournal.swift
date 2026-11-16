import Foundation
import CSQLite
import Darwin

/// Private state-restoration receipt, not a confirmation of runtime continuation.
/// Parent instruction delivery must have a separate durable reservation.
struct CodexOfficialGoalStateReceipt:Codable,Equatable {
    enum Phase:String,Codable {case reserved,applied,review}
    let id:UUID,binding:String
    var phase:Phase
    var result:CodexOfficialGoalStateSnapshot?
}

/// Reserve in our own database before touching Codex's exact-schema database.
/// A previous reservation is read-only even if the process died before recording
/// its outcome. It can never become an implicit second SQL update or followup.
final class CodexOfficialGoalStateJournal {
    private var db:OpaquePointer?
    private let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    private var failure:AppError {.message("Goal 상태 복원 요청의 저장 기록을 확인하지 못했습니다.")}
    init(path:String)throws {
        let file=URL(fileURLWithPath:path)
        guard let parent=realpath(file.deletingLastPathComponent().path,nil) else{throw failure}
        defer{free(parent)}
        let physical=URL(fileURLWithPath:String(cString:parent)).appendingPathComponent(file.lastPathComponent).path
        guard sqlite3_open_v2(physical,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX|SQLITE_OPEN_NOFOLLOW,nil)==SQLITE_OK else{sqlite3_close(db);db=nil;throw failure}
        sqlite3_busy_timeout(db,250)
        do{try sql("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; CREATE TABLE IF NOT EXISTS official_goal_states(id TEXT PRIMARY KEY NOT NULL,json BLOB NOT NULL)")}
        catch{sqlite3_close(db);db=nil;throw error}
    }
    deinit{sqlite3_close(db)}
    private func sql(_ value:String)throws {guard sqlite3_exec(db,value,nil,nil,nil)==SQLITE_OK else{throw failure}}
    private func read(_ id:UUID)throws->CodexOfficialGoalStateReceipt? {
        var statement:OpaquePointer?;defer{sqlite3_finalize(statement)}
        guard sqlite3_prepare_v2(db,"SELECT json FROM official_goal_states WHERE id=?",-1,&statement,nil)==SQLITE_OK else{throw failure}
        sqlite3_bind_text(statement,1,id.uuidString,-1,transient)
        let step=sqlite3_step(statement)
        if step==SQLITE_DONE{return nil}
        guard step==SQLITE_ROW,sqlite3_column_type(statement,0)==SQLITE_BLOB,let bytes=sqlite3_column_blob(statement,0) else{throw failure}
        let size=Int(sqlite3_column_bytes(statement,0));guard size>0,size<=1_048_576 else{throw failure}
        let receipt=try JSONDecoder().decode(CodexOfficialGoalStateReceipt.self,from:Data(bytes:bytes,count:size))
        guard receipt.id==id,receipt.phase == .applied ? receipt.result != nil:receipt.result==nil else{throw failure}
        if let result=receipt.result{try result.validate();guard result.row.status=="active" else{throw failure}}
        return receipt
    }
    private func write(_ receipt:CodexOfficialGoalStateReceipt,insert:Bool)throws {
        let data=try JSONEncoder().encode(receipt);guard data.count<=1_048_576 else{throw failure}
        var statement:OpaquePointer?;defer{sqlite3_finalize(statement)}
        let sql=insert ? "INSERT INTO official_goal_states(json,id) VALUES (?,?)":"UPDATE official_goal_states SET json=? WHERE id=?"
        guard sqlite3_prepare_v2(db,sql,-1,&statement,nil)==SQLITE_OK else{throw failure}
        _=data.withUnsafeBytes{sqlite3_bind_blob(statement,1,$0.baseAddress,Int32(data.count),transient)}
        sqlite3_bind_text(statement,2,receipt.id.uuidString,-1,transient)
        guard sqlite3_step(statement)==SQLITE_DONE,sqlite3_changes(db)==1 else{throw failure}
    }
    func restore(id:UUID,expected:CodexOfficialGoalStateSnapshot,updatedAtMs:Int64,access:CodexOfficialGoalStateAccess,
                 afterReserve:()throws->Void={},afterApply:()throws->Void={})throws->CodexOfficialGoalStateReceipt {
        let binding=PromptDetector.fingerprint([expected.digest,String(updatedAtMs),"official-paused-goal-state-169"].joined(separator:"\0"))
        func existing()throws->CodexOfficialGoalStateReceipt? {
            guard var receipt=try read(id) else{return nil}
            guard receipt.binding==binding else{throw failure}
            if let result=receipt.result {
                guard result.home==expected.home,result.homeIdentity==expected.homeIdentity,
                      result.databaseIdentity==expected.databaseIdentity,result.schemaFingerprint==expected.schemaFingerprint,
                      !result.continuationDeferred,
                      result.row==CodexGoalTransferRow(threadID:expected.row.threadID,goalID:expected.row.goalID,
                        objective:expected.row.objective,status:"active",tokenBudget:expected.row.tokenBudget,
                        tokensUsed:expected.row.tokensUsed,timeUsedSeconds:expected.row.timeUsedSeconds,
                        createdAtMs:expected.row.createdAtMs,updatedAtMs:updatedAtMs) else{throw failure}
            }
            if receipt.phase == .reserved {receipt.phase = .review}
            return receipt
        }
        if let receipt=try existing(){return receipt}
        var receipt=CodexOfficialGoalStateReceipt(id:id,binding:binding,phase:.reserved,result:nil)
        do{try write(receipt,insert:true)}
        catch{if let winner=try existing(){return winner};throw error}
        try afterReserve()
        do{
            let result=try access.resume(expected,updatedAtMs:updatedAtMs)
            try afterApply()
            receipt.phase = .applied;receipt.result=result
        }catch{receipt.phase = .review}
        try write(receipt,insert:false);return receipt
    }
}
