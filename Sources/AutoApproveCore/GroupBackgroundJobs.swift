import Foundation
import CryptoKit
import CSQLite

package struct GroupBackgroundJob: Codable {
    let group: UUID
    let member: UUID
    let session: String
    let conversation: String
    let server: String
    package let process: String
    let item: String
    let command: String
    let firstSeen: Date
    var status = "running"
    var startedAt: Date?
    var outputFileIdentity: String?
    var exitCode: Int?
    var taskID: UUID?
    var finishedAt: Date?

    package init(group:UUID,member:UUID,session:String,conversation:String,server:String,process:String,item:String,
                 command:String,firstSeen:Date = Date(),startedAt:Date? = nil) {
        self.group = group
        self.member = member
        self.session = session
        self.conversation = conversation.lowercased()
        self.server = server
        self.process = process
        self.item = item
        self.command = command
        self.firstSeen = firstSeen
        self.startedAt = startedAt
    }

    package var id: String {
        let parts = [group.uuidString,member.uuidString,session,conversation,server,process,item]
        let digest = SHA256.hash(data: (try? JSONEncoder().encode(parts)) ?? Data())
        return digest.map { String(format:"%02x",$0) }.joined()
    }

    var json: JSONObject {
        var row: JSONObject = ["jobID":id, "memberID":member.uuidString, "providerJobID":process, "command":command,
            "status":status, "canStop":status == "running", "firstObservedAt":ISO8601DateFormatter().string(from:firstSeen),
            "observedSeconds":max(0,Int((finishedAt ?? Date()).timeIntervalSince(firstSeen)))]
        if let startedAt {
            row["startedAt"] = ISO8601DateFormatter().string(from:startedAt)
            row["elapsedSeconds"] = max(0,Int((finishedAt ?? Date()).timeIntervalSince(startedAt)))
        }
        row["exitCode"] = exitCode
        row["taskID"] = taskID?.uuidString
        return row
    }
}

package struct GroupJobEvidence {
    package init(output:String? = nil,exitCode:Int? = nil,turn:String? = nil,failed:Bool = false,ended:Bool? = nil) {
        self.output = output
        self.exitCode = exitCode
        self.turn = turn
        self.failed = failed
        self.ended = ended
    }
    var output: String?
    var exitCode: Int?
    var turn: String?
    var failed = false
    var ended: Bool?
}

package struct GroupJobInventory {
    package init(server:String,jobs:[GroupBackgroundJob],complete:Bool = true) {
        self.server = server
        self.jobs = jobs
        self.complete = complete
    }
    var server: String
    var jobs: [GroupBackgroundJob]
    var complete = true
}

package struct GroupJobProvider {
    package init(inventory:@escaping (SessionGroupLiveSession,UUID,UUID) throws -> GroupJobInventory,
                 evidence:@escaping (SessionGroupLiveSession,GroupBackgroundJob) throws -> GroupJobEvidence,
                 stop:@escaping (SessionGroupLiveSession,GroupBackgroundJob,@escaping @Sendable () async throws -> Void) async throws -> Bool) {
        self.inventory = inventory
        self.evidence = evidence
        self.stop = stop
    }
    var inventory: (SessionGroupLiveSession,UUID,UUID) throws -> GroupJobInventory
    var evidence: (SessionGroupLiveSession,GroupBackgroundJob) throws -> GroupJobEvidence
    var stop: (SessionGroupLiveSession,GroupBackgroundJob,@escaping @Sendable () async throws -> Void) async throws -> Bool

    static let codex = Self(inventory: { live,group,member in
        let (connection, generation, thread) = try connection(live)
        return .init(server:generation, jobs:try list(connection,thread:thread).map {
            GroupBackgroundJob(group:group,member:member,session:live.id,conversation:thread,server:generation,
                process:$0.process,item:$0.item,command:$0.command,firstSeen:Date(),startedAt:$0.started)
        })
    }, evidence: { live,job in
        let (connection,generation,thread) = try connection(live)
        guard generation == job.server, thread == job.conversation else { throw stale() }
        var cursor: String?
        for _ in 0..<4 {
            var params: JSONObject = ["threadId":thread,"itemsView":"full","limit":2,"sortDirection":"desc"]
            params["cursor"] = cursor
            let page = try connection.request("thread/turns/list",params)
            for turn in page["data"] as? [JSONObject] ?? [] {
                for item in turn["items"] as? [JSONObject] ?? [] where item["type"] as? String == "commandExecution" && item["id"] as? String == job.item {
                    if let process = item["processId"] as? String, process != job.process { continue }
                    let code = item["exitCode"] as? Int
                    return .init(output:(item["aggregatedOutput"] as? String).map { String($0.suffix(1600)) },
                        exitCode:code,turn:(turn["id"] as? String).map { "codex:" + $0 },failed:item["status"] as? String == "failed" || code.map { $0 != 0 } == true)
                }
            }
            cursor = try CodexAccountTransitionLocal.nextCursor(page)
            if cursor == nil { break }
        }
        return .init()
    }, stop: { live,job,authorize in
        let (connection,generation,thread) = try connection(live)
        guard generation == job.server, thread == job.conversation, live.id == job.session,
              try list(connection,thread:thread).contains(where: { $0.process == job.process && $0.item == job.item }) else { throw stale() }
        try await authorize()
        let result = try connection.request("thread/backgroundTerminals/terminate",["threadId":thread,"processId":job.process])
        guard let accepted = result["terminated"] as? Bool else { throw RemoteHTTPError(409,"중단 요청의 결과를 확인하지 못했습니다. 목록을 다시 확인해주세요.") }
        return accepted
    })

    static func stale() -> RemoteHTTPError { RemoteHTTPError(409,"세션 또는 백그라운드 작업의 원래 연결을 확인하지 못했습니다.",diagnostics:["delivery":"not_started"]) }

    private static func connection(_ live: SessionGroupLiveSession) throws -> (CodexQueueConnection,String,String) {
        guard live.session.agent == .codex, let home = live.providerHome, let thread = live.conversationID,
              UUID(uuidString:thread) != nil else { throw stale() }
        let socket = try CodexQueueConnection(home:home)
        let peer = try socket.nativePeerIdentity().identity
        guard try ProcessDiscovery.read(pid:live.session.pid).contains(where: { $0.key == live.id && $0.agent == .codex && "/dev/" + $0.tty == live.session.tty }),
              CodexServerLocation.connectedHome(pid:live.session.pid,hints:[home],peerPID:Int32(peer.pid)) != nil else { throw stale() }
        return (socket,"\(peer.pid):\(peer.auditPidVersion)",thread.lowercased())
    }

    private static func list(_ connection: CodexQueueConnection, thread: String) throws -> [(process:String,item:String,command:String,started:Date?)] {
        var rows: [(process:String,item:String,command:String,started:Date?)] = []
        var cursors = Set<String>(), processes = Set<String>(), cursor: String?
        repeat {
            var params: JSONObject = ["threadId":thread,"limit":100]
            params["cursor"] = cursor
            let page = try connection.request("thread/backgroundTerminals/list",params)
            guard let data = page["data"] as? [JSONObject], data.count <= 100 else { throw stale() }
            for entry in data {
                guard let id = entry["processId"] as? String, (1...256).contains(id.utf8.count),
                      let item = entry["itemId"] as? String, (1...256).contains(item.utf8.count),
                      let command = entry["command"] as? String, processes.insert(id).inserted, rows.count < 1000 else { throw stale() }
                let started = (entry["osPid"] as? Int32).flatMap { pid in
                    (try? ProcessDiscovery.read(pid:pid))?.first.flatMap { ProcessEnvironment.startDate($0.started) }
                }
                rows.append((id,item,String(SessionGroupOrchestration.oneLine(command).prefix(160)),started))
            }
            cursor = try CodexAccountTransitionLocal.nextCursor(page)
            if let cursor, !cursors.insert(cursor).inserted || cursors.count >= 100 { throw stale() }
        } while cursor != nil
        return rows
    }
}

extension SessionGroupMailbox {
    func backgroundJobs(group: UUID, member: UUID, session: String, conversation: String, id:String? = nil) throws -> [GroupBackgroundJob] {
        let clause = id == nil ? "finished IS NULL" : "id=?"
        let args = [group.uuidString,member.uuidString,session,conversation.lowercased()] + (id.map { [$0] } ?? [])
        let q = try statement("SELECT body FROM background_jobs WHERE gid=? AND member=? AND session=? AND conversation=? AND " + clause + " ORDER BY rowid",args)
        defer { sqlite3_finalize(q) }
        var jobs: [GroupBackgroundJob] = []
        while true {
            switch sqlite3_step(q) {
            case SQLITE_DONE: return jobs
            case SQLITE_ROW:
                let value = String(cString:sqlite3_column_text(q,0))
                jobs.append(try JSONDecoder().decode(GroupBackgroundJob.self,from:Data(value.utf8)))
            default: throw AppError.message("작업 기록을 읽지 못했습니다.")
            }
        }
    }

    func saveBackgroundJob(_ job: GroupBackgroundJob, event: String? = nil) throws {
        let body = String(decoding:try JSONEncoder().encode(job),as:UTF8.self)
        try transaction {
            try update("INSERT INTO background_jobs(id,gid,member,session,conversation,body,finished) VALUES(?,?,?,?,?,?,NULLIF(?,'')) ON CONFLICT(id) DO UPDATE SET body=excluded.body,finished=excluded.finished",
                [job.id,job.group.uuidString,job.member.uuidString,job.session,job.conversation,body,job.finishedAt.map { String($0.timeIntervalSince1970) } ?? ""])
            if let event {
                try update("INSERT OR IGNORE INTO group_events(gid,member,ref,kind,at,age) VALUES(?,?,?,?,?,?)",
                    [job.group.uuidString,job.member.uuidString,job.id,event,String(Date().timeIntervalSince1970),
                     String(max(0,Int(Date().timeIntervalSince(job.firstSeen))))])
            }
        }
    }

    func backgroundAssignment(turn:String, candidates:[SessionGroupAssignment]) throws -> UUID? {
        let q = try statement("SELECT message_id FROM group_observed_turns WHERE turn=?", [turn])
        defer { sqlite3_finalize(q) }
        var found = Set<UUID>()
        while sqlite3_step(q) == SQLITE_ROW {
            if let id = UUID(uuidString:String(cString:sqlite3_column_text(q,0))), candidates.contains(where: { $0.id == id }) { found.insert(id) }
        }
        return found.count == 1 ? found.first : nil
    }
}
