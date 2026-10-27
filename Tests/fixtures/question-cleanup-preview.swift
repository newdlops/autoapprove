// Real two-node HTTP with synthetic questions; no user process or provider IO.
import Foundation
import CSQLite
import AutoApproveCore

@main struct QuestionCleanupPreview {
    @MainActor static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),ownerPaths=AppPaths(directory:root.appendingPathComponent("owner"))
        let owner=try ApprovalEngine(paths:ownerPaths,processReader:{[]})
        let sessions=(0..<2).map {index -> AgentSession in
            var session=AgentSession(id:"cleanup-session-\(index)",agent:.codex,pid:987650+Int32(index),started:"synthetic",tty:"/dev/fixture-\(index)",cwd:"/fixture/cleanup-\(index)",terminal:.terminal)
            session.phase = .working;return session
        }
        owner.updateDiscovery(sessions,records:[])
        let stored=try AuditStore(path:ownerPaths.database)
        let uncertain=QuestionReply(phase:.uncertain,answer:"합성 미확인 답변",message:"전달 결과를 확인해주세요.")
        try stored.set("questionReply:uncertain",String(decoding:JSONEncoder().encode(uncertain),as:UTF8.self))
        func questions(_ index:Int,changed:Bool) -> [QueuedQuestion] {
            let old=(0..<(index==0 ? 67:83)).map {number -> QueuedQuestion in
                var q=QueuedQuestion(id:"old-\(index)-\(number)",threadID:"thread-\(index)",title:"지난 합성 질문 \(index)-\(number)"+(number==66 ? " · 긴 한글 질문과 e\u{301} 🙂 줄바꿈 검증".repeating(6):""),options:["개발","시험"])
                q.hasLaterUserMessage=true
                if changed && index==1 && number==0 {q.title="내용이 바뀐 합성 질문"}
                return q
            }
            var result=old+[QueuedQuestion(id:"current-\(index)",threadID:"thread-\(index)",title:"현재 응답이 필요한 질문 \(index)",options:["개발","시험"])]
            if index==0 {var q=QueuedQuestion(id:"uncertain",threadID:"thread-0",title:"결과 미확인 질문");q.hasLaterUserMessage=true;result.append(q)}
            return result
        }
        func refresh() {for index in 0..<2 {owner.updateCodexQuestions([CodexQuestionUpdate(sessionID:sessions[index].id,questions:questions(index,changed:FileManager.default.fileExists(atPath:root.appendingPathComponent("changed").path)))])}}
        refresh()
        try owner.setWebEnabled(true,port:0,bonjourEnabled:false,discoveryAddresses:{[]})
        while !owner.webStatus.ready {try await Task.sleep(for:.milliseconds(10))}
        let target=owner.webService!,ownerURL=owner.webStatus.loopbackURL!
        let gatewayPaths=AppPaths(directory:root.appendingPathComponent("gateway"));try gatewayPaths.prepare()
        try JSONSerialization.data(withJSONObject:[["id":target.nodeID,"name":"Question cleanup QA","address":ownerURL]]).write(to:gatewayPaths.directory.appendingPathComponent("web-peers.json"))
        let gateway=try ApprovalEngine(paths:gatewayPaths,processReader:{[]})
        try gateway.setWebEnabled(true,port:0,bonjourEnabled:false,discoveryAddresses:{[]})
        while !gateway.webStatus.ready {try await Task.sleep(for:.milliseconds(10))}
        let pin=try RemoteTunnelPIN.create("001234"),publicGateway=try RemoteTunnelGateway(pin:pin,handler:{await gateway.webService!.handle($0)})
        try await publicGateway.start(port:0);try publicGateway.setOrigin("https://cleanup.tunnel-qa.invalid")
        let ready:JSONObject=["base":gateway.webStatus.loopbackURL!,"gateway":publicGateway.localURL!,"owner":ownerURL,"node":target.nodeID,"sessions":sessions.map(\.id)]
        try JSONSerialization.data(withJSONObject:ready).write(to:root.appendingPathComponent("ready.json"))
        var fail=false
        while !FileManager.default.fileExists(atPath:root.appendingPathComponent("stop").path) {
            let next=FileManager.default.fileExists(atPath:root.appendingPathComponent("fail").path)
            if next != fail {
                var db:OpaquePointer?;guard sqlite3_open(ownerPaths.database,&db)==SQLITE_OK else {throw AppError.message("QA SQLite")}
                let sql=next ? "CREATE TRIGGER fail_cleanup BEFORE INSERT ON settings WHEN NEW.key = 'dismissedQuestion:old-1-0' BEGIN SELECT RAISE(ABORT, 'synthetic'); END":"DROP TRIGGER IF EXISTS fail_cleanup"
                guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else {sqlite3_close(db);throw AppError.message("QA trigger")};sqlite3_close(db);fail=next
            }
            refresh()
            try JSONSerialization.data(withJSONObject:["counts":owner.snapshot.sessions.map{$0.questions.count},"fail":fail]).write(to:root.appendingPathComponent("observed.json"))
            try await Task.sleep(for:.milliseconds(100))
        }
        publicGateway.stop();gateway.stop();owner.stop()
    }
}
private extension String {func repeating(_ count:Int) -> String {String(repeating:self,count:count)}}
