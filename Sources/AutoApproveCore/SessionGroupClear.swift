import Foundation

public struct SessionGroupClearTarget: Codable, Equatable, Sendable {
    public var memberID: UUID
    public var runtimeID: String
    public var pid: Int32
    public var started: String
    public var tty: String
    public var cwd: String
    public var agent: String
    public var providerHome: String?
    public var beforeID: String
    public var savedID: String
    public var afterID: String?
    public var verifiedAt: Date?
    public var phase: String = "waiting"
    public var detail: String?
    public var identityAttempts = 0
    public var terminal: Bool { ["completed", "failed", "needs_review"].contains(phase) }
    public init(member: SessionGroupMember, live: SessionGroupLiveSession?) {
        memberID = member.id; runtimeID = live?.id ?? member.runtimeID ?? ""
        pid = live?.session.pid ?? 0; started = live?.session.started ?? ""; tty = live?.session.tty ?? ""
        cwd = live?.session.cwd ?? member.cwd; agent = member.agent.rawValue; providerHome = live?.providerHome ?? member.providerHome
        beforeID = member.conversationID; savedID = member.conversationID
        if live == nil { phase = "failed"; detail = "원래 터미널 연결을 확인하지 못했습니다." }
    }
    public var json: JSONObject {
        ["memberID": memberID.uuidString, "agent": agent, "phase": phase,
         "beforeConversationID": beforeID, "conversationID": afterID as Any? ?? NSNull(),
         "detail": detail as Any? ?? NSNull()]
    }
}

public struct SessionGroupClearOperation: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var groupID: UUID
    public var callerMemberID: UUID
    public var createdAt: Date
    public var targets: [SessionGroupClearTarget]
    public var done: Bool { targets.allSatisfy(\.terminal) }
    public init(id: UUID, groupID: UUID, callerMemberID: UUID, targets: [SessionGroupClearTarget]) {
        self.id = id; self.groupID = groupID; self.callerMemberID = callerMemberID; createdAt = Date(); self.targets = targets
    }
    public var json: JSONObject {
        ["requestID": id.uuidString, "groupID": groupID.uuidString, "done": done,
         "status": !done ? "running" : targets.allSatisfy({ $0.phase == "completed" }) ? "completed" : "needs_review",
         "updated": targets.filter { $0.phase == "completed" }.count, "total": targets.count,
         "members": targets.map(\.json), "transport": "local_terminal", "networkRequired": false]
    }
}
