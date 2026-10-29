import Foundation
import CryptoKit
import CSQLite
import Darwin

public struct CodexGoal:Codable,Equatable,Sendable {
    public enum Status:String,Codable,Sendable {case active,paused,blocked,usageLimited,budgetLimited,complete}
    public var threadId:String
    public var objective:String
    public var status:Status
    public var createdAt:Int64
    public var updatedAt:Int64
    public var tokensUsed:Int64
    public var timeUsedSeconds:Int64
    public var tokenBudget:Int64?
    public var instanceID:String?
    public init(threadId:String,objective:String,status:Status,createdAt:Int64,updatedAt:Int64,tokensUsed:Int64=0,timeUsedSeconds:Int64=0,tokenBudget:Int64?=nil,instanceID:String?=nil) {
        self.threadId=threadId;self.objective=objective;self.status=status;self.createdAt=createdAt;self.updatedAt=updatedAt;self.tokensUsed=tokensUsed;self.timeUsedSeconds=timeUsedSeconds;self.tokenBudget=tokenBudget;self.instanceID=instanceID
    }
    /// Usage counters can change during a read. The command is bound to the
    /// goal instance, objective, lifecycle state and budget the user reviewed.
    public var revision:String {
        let values=[threadId,instanceID ?? "",objective,status.rawValue,String(createdAt),tokenBudget.map(String.init) ?? ""]
        return SHA256.hash(data:try! JSONEncoder().encode(values)).map {String(format:"%02x",$0)}.joined()
    }
    public var canResume:Bool {[.paused,.blocked,.usageLimited].contains(status)}
}

public enum CodexGoalAction:String,Sendable {case resume,cancel
    public var command:String {self == .resume ? "/goal resume":"/goal clear"}
}

struct ManualGoalHold:Codable {
    var goal:CodexGoal
    var action:String
    func belongs(to value:CodexGoal)->Bool {
        // A temporarily unavailable local UUID is not evidence of a new Goal.
        goal.threadId==value.threadId && (goal.instanceID==nil || value.instanceID==nil || goal.instanceID==value.instanceID) && goal.createdAt==value.createdAt && goal.objective==value.objective
    }
}

public enum CodexGoalScreen {
    /// A lifecycle footer does not make the composer user text. Keep the CLI's
    /// own idle hint mandatory and reject working, Vim and permission menus.
    public static func ready(_ raw:String)->Bool {
        let rows=CodexResumeCheck.rows(raw)
        guard !CodexResumeCheck.blocked(rows),let composer=rows.lastIndex(where:CodexResumeCheck.isComposer) else {return false}
        let known=#"^Goal (?:paused|hit usage limits|hit budget|achieved|abandoned)(?:\s*[·(]\s*/goal(?: resume)?\)?)?$"#
        let filtered=rows.enumerated().filter {index,line in index<=composer || line.range(of:known,options:.regularExpression)==nil}.map(\.element).joined(separator:"\n")
        return CodexProgressScreen.ready(filtered)
    }
}

public struct RemoteCodexGoal:Codable,Sendable {
    public var sessionID:String
    public var threadID:String
    public var goal:CodexGoal?
    public var revision:String?
    public var transport:String
    public var canResume:Bool
    public var canCancel:Bool
    public var detail:String
}

/// Uses only an already-running Codex server. Standalone CLI history is read
/// with SQLITE_OPEN_READONLY; mutations go through its verified original TTY.
public struct CodexGoalTransport:Sendable {
    public var read:@Sendable (CodexReplyTarget,String) async throws -> CodexGoal?
    public var change:@Sendable (CodexReplyTarget,String,CodexGoal,CodexGoalAction) async throws -> CodexGoal?
    public init(read:@escaping @Sendable (CodexReplyTarget,String) async throws -> CodexGoal?,change:@escaping @Sendable (CodexReplyTarget,String,CodexGoal,CodexGoalAction) async throws -> CodexGoal?) {self.read=read;self.change=change}
    public static let live=Self(read:{target,cwd in
        try await Task.detached(priority:.utility) {
            if !target.queueAvailable {return try readDatabase(home:target.home,threadID:target.threadID)}
            let connection=try CodexQueueConnection(home:target.home)
            try validate(connection,target:target,cwd:cwd)
            return try readControl(connection,target:target)
        }.value
    },change:{target,cwd,expected,action in
        try await Task.detached(priority:.utility) {
            let connection=try CodexQueueConnection(home:target.home)
            try validate(connection,target:target,cwd:cwd)
            let current=try readControl(connection,target:target)
            guard current?.revision==expected.revision else {throw RemoteHTTPError(409,"Goal이 바뀌었습니다. 현재 목표를 다시 확인해주세요.",diagnostics:["delivery":"not_started"])}
            try Task.checkCancellation()
            if action == .cancel {
                let result=try connection.request("thread/goal/clear",["threadId":target.threadID,"origin":"user"])
                guard result["cleared"] as? Bool == true else {throw RemoteHTTPError(409,"Goal이 이미 변경되었거나 해제되었습니다. 다시 확인해주세요.")}
                return nil
            }
            guard expected.canResume else {throw RemoteHTTPError(409,"이 Goal은 재개할 수 있는 상태가 아닙니다. 예산 제한은 원래 Codex에서 확인해주세요.",diagnostics:["delivery":"not_started"])}
            let goal=try decode(connection.request("thread/goal/set",["threadId":target.threadID,"status":"active","origin":"user"]),threadID:target.threadID)
            guard let goal,goal.status == .active,goal.objective==expected.objective,goal.createdAt==expected.createdAt,goal.tokenBudget==expected.tokenBudget else {throw AppError.message("Goal 재개 결과를 확인하지 못했습니다. 같은 명령을 다시 보내지 말고 상태를 확인해주세요.")}
            return goal
        }.value
    })
    private static func validate(_ connection:CodexQueueConnection,target:CodexReplyTarget,cwd:String) throws {
        guard UUID(uuidString:target.threadID) != nil else {throw RemoteHTTPError(400,"원래 Codex 대화를 지정해주세요.")}
        let value=try connection.request("thread/read",["threadId":target.threadID,"includeTurns":false])
        guard let row=value["thread"] as? JSONObject,row["id"] as? String==target.threadID,CodexQueueTransport.isLoadedRoot(row,cwd:cwd) else {throw RemoteHTTPError(409,"선택한 대화의 실행이나 폴더가 바뀌었습니다.",diagnostics:["delivery":"not_started"])}
    }
    private static func readControl(_ connection:CodexQueueConnection,target:CodexReplyTarget) throws -> CodexGoal? {
        var goal=try decode(connection.request("thread/goal/get",["threadId":target.threadID]),threadID:target.threadID)
        // The API omits the goal UUID. When available, the CLI's own read-only
        // record distinguishes delete/recreate within the same API timestamp.
        if let stored=try? readDatabase(home:target.home,threadID:target.threadID),let current=goal,
           stored.createdAt==current.createdAt,stored.objective==current.objective,stored.status==current.status,stored.tokenBudget==current.tokenBudget {
            goal?.instanceID=stored.instanceID
        }
        return goal
    }
    static func decode(_ result:JSONObject,threadID:String) throws -> CodexGoal? {
        // The official optional goal field may be omitted when no goal exists.
        guard let value=result["goal"] else {return nil}
        if value is NSNull {return nil}
        let goal=try JSONDecoder().decode(CodexGoal.self,from:JSONSerialization.data(withJSONObject:value))
        guard goal.threadId==threadID,goal.objective.utf8.count<=256_000,goal.tokensUsed>=0,goal.timeUsedSeconds>=0 else {throw AppError.message("원래 대화의 Goal 응답을 확인하지 못했습니다.")}
        return goal
    }
    public static func readDatabase(home:String,threadID:String) throws -> CodexGoal? {
        guard UUID(uuidString:threadID) != nil else {throw RemoteHTTPError(400,"원래 Codex 대화를 지정해주세요.")}
        let path=URL(fileURLWithPath:home).appendingPathComponent("goals_1.sqlite").path
        var info=stat()
        guard lstat(path,&info)==0,info.st_uid==getuid(),(info.st_mode&S_IFMT)==S_IFREG else {throw RemoteHTTPError(409,"이 Codex의 Goal 기록을 확인하지 못했습니다. Codex 버전과 원래 대화를 확인해주세요.")}
        let db=try CodexHistoryAccess.open(path,subject:"Goal");defer {sqlite3_close(db)}
        let sql="SELECT goal_id,objective,status,token_budget,tokens_used,time_used_seconds,created_at_ms,updated_at_ms FROM thread_goals WHERE thread_id=? LIMIT 1"
        var statement:OpaquePointer?
        let prepared=sqlite3_prepare_v2(db,sql,-1,&statement,nil)
        guard prepared==SQLITE_OK,let statement else {throw CodexHistoryAccess.failure(db,subject:"Goal",result:prepared)}
        defer {sqlite3_finalize(statement)}
        sqlite3_bind_text(statement,1,threadID,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self))
        let result=sqlite3_step(statement)
        if result==SQLITE_DONE {return nil}
        guard result==SQLITE_ROW else {throw CodexHistoryAccess.failure(db,subject:"Goal",result:result)}
        func text(_ column:Int32)->String {sqlite3_column_text(statement,column).map {String(cString:$0)} ?? ""}
        let raw=text(2),status=CodexGoal.Status(rawValue:raw=="usage_limited" ? "usageLimited":raw=="budget_limited" ? "budgetLimited":raw)
        guard let status,!text(0).isEmpty,sqlite3_column_bytes(statement,1)<=256_000 else {throw CodexHistoryReadError(.invalidData,subject:"Goal")}
        return CodexGoal(threadId:threadID,objective:text(1),status:status,createdAt:sqlite3_column_int64(statement,6)/1000,updatedAt:sqlite3_column_int64(statement,7)/1000,tokensUsed:sqlite3_column_int64(statement,4),timeUsedSeconds:sqlite3_column_int64(statement,5),tokenBudget:sqlite3_column_type(statement,3)==SQLITE_NULL ? nil:sqlite3_column_int64(statement,3),instanceID:text(0))
    }
}
