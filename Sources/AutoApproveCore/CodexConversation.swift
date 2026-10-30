import Foundation

public struct CodexConversationMessage:Codable,Sendable {
    public var id:String,role:String,text:String
    public var phase:String?
    public var truncated:Bool
    public init(id:String,role:String,text:String,phase:String?=nil,truncated:Bool=false) {
        self.id=id;self.role=role;self.text=text;self.phase=phase;self.truncated=truncated
    }
}
public struct CodexConversationPage:Codable,Sendable {
    public var sessionID:String,threadID:String
    public var messages:[CodexConversationMessage]
    public var nextCursor:String?
    public init(sessionID:String="",threadID:String,messages:[CodexConversationMessage],nextCursor:String?=nil) {
        self.sessionID=sessionID;self.threadID=threadID;self.messages=messages;self.nextCursor=nextCursor
    }
}

/// Only persisted display messages; never terminal output, hooks or reasoning.
public enum CodexConversationProjection {
    public static func page(_ result:JSONObject,threadID:String) throws -> CodexConversationPage {
        guard let rows=result["data"] as? [JSONObject],rows.count<=32,
              result["nextCursor"]==nil || result["nextCursor"] is NSNull || result["nextCursor"] is String else {
            throw AppError.message("Codex 대화 기록의 형식을 확인하지 못했습니다.")
        }
        let cursor=result["nextCursor"] as? String
        guard cursor.map({!$0.isEmpty && $0.utf8.count<=8192}) ?? true else {throw AppError.message("Codex 기록의 다음 위치를 확인하지 못했습니다.")}
        var messages:[CodexConversationMessage]=[],seen=Set<String>()
        for row in rows.reversed() {
            guard let item=row["item"] as? JSONObject,let type=item["type"] as? String else {throw AppError.message("Codex 대화 항목을 읽지 못했습니다.")}
            guard ["userMessage","agentMessage"].contains(type) else {continue}
            guard let id=item["id"] as? String,!id.isEmpty,id.utf8.count<=512,seen.insert(id).inserted else {throw AppError.message("Codex 대화 항목을 구분하지 못했습니다.")}
            let text:String
            if type=="userMessage" {
                guard let content=item["content"] as? [JSONObject],content.count<=1024 else {throw AppError.message("사용자 메시지를 읽지 못했습니다.")}
                text=try content.map {part -> String in
                    guard let kind=part["type"] as? String else {throw AppError.message("사용자 메시지의 첨부 형식을 확인하지 못했습니다.")}
                    if kind=="text" {
                        guard let value=part["text"] as? String else {throw AppError.message("사용자 메시지 본문을 읽지 못했습니다.")}
                        return value
                    }
                    return ["image","localImage"].contains(kind) ? "[이미지 첨부]":"[첨부 항목]"
                }.joined(separator:"\n")
            } else {
                guard let value=item["text"] as? String else {throw AppError.message("Codex 답변 본문을 읽지 못했습니다.")}
                text=value
            }
            let displayed=String(text.prefix(65_536))
            messages.append(.init(id:id,role:type=="userMessage" ? "user":"assistant",text:displayed,
                phase:item["phase"] as? String,truncated:displayed.utf8.count != text.utf8.count))
        }
        return .init(threadID:threadID,messages:messages,nextCursor:cursor)
    }
}

public struct CodexConversationTransport:Sendable {
    public var read:@Sendable (CodexReplyTarget,String,String?) async throws -> CodexConversationPage
    public init(read:@escaping @Sendable (CodexReplyTarget,String,String?) async throws -> CodexConversationPage) {self.read=read}
    public static let live=Self {target,cwd,cursor in
        try await Task.detached(priority:.utility) {
            guard UUID(uuidString:target.threadID) != nil,target.queueAvailable else {throw RemoteHTTPError(409,"Codex 대화 기록 서버에 연결할 수 없습니다. Mac의 Codex 연결을 확인해주세요.")}
            let connection=try CodexQueueConnection(home:target.home)
            func validate() throws {
                let result=try connection.request("thread/read",["threadId":target.threadID,"includeTurns":false])
                guard let thread=result["thread"] as? JSONObject,thread["id"] as? String==target.threadID,
                      CodexQueueTransport.isLoadedRoot(thread,cwd:cwd) else {throw RemoteHTTPError(409,"대화가 종료됐거나 폴더가 바뀌었습니다. 대화를 다시 확인해주세요.")}
            }
            try validate()
            var next=cursor,seen=Set<String>(),page:CodexConversationPage?
            // Find display messages across at most 128 tool items per request.
            for _ in 0..<4 {
                try Task.checkCancellation()
                var params:JSONObject=["threadId":target.threadID,"limit":32,"sortDirection":"desc"]
                if let next {params["cursor"]=next}
                let result=try CodexConversationProjection.page(connection.request("thread/items/list",params),threadID:target.threadID)
                guard result.nextCursor==nil || result.nextCursor != next && seen.insert(result.nextCursor!).inserted else {throw AppError.message("Codex 대화 기록의 조회 위치가 반복됐습니다.")}
                page=result;next=result.nextCursor
                if !result.messages.isEmpty || next==nil {break}
            }
            try validate()
            guard let page else {throw AppError.message("Codex 대화 기록을 읽지 못했습니다.")}
            return page
        }.value
    }
}
