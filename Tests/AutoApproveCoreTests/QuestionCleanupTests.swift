import Foundation
import CSQLite
import AutoApproveCore

extension ApprovalTests {
    private func cleanupFixture() throws -> (URL,AppPaths,ApprovalEngine,AgentSession,[QueuedQuestion]) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-question-cleanup-"+UUID().uuidString),paths=AppPaths(directory:root)
        let engine=try ApprovalEngine(paths:paths,processReader:{[]})
        var session=AgentSession(id:"cleanup-original",agent:.codex,pid:987654,started:"synthetic",tty:"/dev/fixture",cwd:"/fixture",terminal:.terminal)
        session.phase = .working;engine.updateDiscovery([session],records:[])
        let questions=(0..<150).map {index -> QueuedQuestion in
            var question=QueuedQuestion(id:"old-\(index)",threadID:"thread",title:"지난 합성 질문 \(index)",options:["개발","시험"])
            question.hasLaterUserMessage=true;return question
        }+[QueuedQuestion(id:"current",threadID:"thread",title:"새 질문")]
        engine.updateCodexQuestions([CodexQuestionUpdate(sessionID:session.id,questions:questions)])
        return (root,paths,engine,session,questions)
    }
    private func cleanupBody(_ questions:[QueuedQuestion],sessionID:String,restore:Bool=false) -> JSONObject {
        ["action":restore ? "restorePastQuestions":"cleanPastQuestions","sessionID":sessionID,
         "questions":questions.map{["id":$0.id,"token":$0.cleanupIdentity(sessionID:sessionID)]}]
    }
    func testPastQuestionCleanupPersistsRestoresAndKeepsNewQuestions() async throws {
        let (root,paths,engine,session,questions)=try cleanupFixture();defer {engine.stop();try? FileManager.default.removeItem(at:root)}
        let old=Array(questions.dropLast()),result=try await engine.remoteAction(cleanupBody(old,sessionID:session.id))
        try expectEqual(result["count"] as? Int,150);try expectEqual(engine.snapshot.sessions[0].questions.map(\.id),["current"])
        engine.updateCodexQuestions([CodexQuestionUpdate(sessionID:session.id,questions:questions)])
        try expectEqual(engine.snapshot.sessions[0].questions.map(\.id),["current"],"A collector refresh must not resurrect the cleaned history")
        let reopened=try ApprovalEngine(paths:paths,processReader:{[]});defer{reopened.stop()}
        reopened.updateDiscovery([session],records:[]);reopened.updateCodexQuestions([CodexQuestionUpdate(sessionID:session.id,questions:questions)])
        try expectEqual(reopened.snapshot.sessions[0].questions.map(\.id),["current"],"Another process/browser sees the persisted cleanup")
        _ = try await reopened.remoteAction(cleanupBody([old[0]],sessionID:session.id,restore:true))
        reopened.updateCodexQuestions([CodexQuestionUpdate(sessionID:session.id,questions:questions)])
        try expectEqual(Set(reopened.snapshot.sessions[0].questions.map(\.id)),Set(["current",old[0].id]))
        try expect(reopened.snapshot.sessions[0].questions.first{$0.id==old[0].id}?.automation?.phase != .scheduled,"Undo must not restart an automatic answer")
        let store=try AuditStore(path:paths.database,readOnly:true)
        try expectEqual(store.value("questionAutomation:\(old[0].id)"),"editing")
        try expect(store.recent().isEmpty,"Metadata cleanup cannot send a reply or add an input audit")
    }
    func testPastQuestionCleanupRejectsNewChangedAndUncertainRequestsAtomically() async throws {
        let (root,paths,engine,session,questions)=try cleanupFixture();defer{engine.stop();try? FileManager.default.removeItem(at:root)}
        let store=try AuditStore(path:paths.database)
        for selected in [[questions[0],questions.last!],[questions[0],questions[0]]] {
            do {_ = try await engine.remoteAction(cleanupBody(selected,sessionID:session.id));throw AppError.message("Unsafe cleanup accepted")}
            catch let error as RemoteHTTPError {try expectEqual(error.status,409)}
            try expectNil(store.value("dismissedQuestion:\(questions[0].id)"))
        }
        var changed=questions;changed[1].title="같은 ID의 새로운 내용"
        engine.updateCodexQuestions([CodexQuestionUpdate(sessionID:session.id,questions:changed)])
        do {_ = try await engine.remoteAction(cleanupBody(Array(questions.prefix(2)),sessionID:session.id));throw AppError.message("Changed content accepted")}
        catch let error as RemoteHTTPError {try expectEqual(error.status,409)}
        try expectNil(store.value("dismissedQuestion:\(questions[0].id)"))
        let uncertain=QuestionReply(phase:.uncertain,answer:"합성 답변",message:"전달 미확인")
        try store.set("questionReply:uncertain",String(decoding:JSONEncoder().encode(uncertain),as:UTF8.self))
        var question=QueuedQuestion(id:"uncertain",threadID:"thread",title:"결과 미확인");question.hasLaterUserMessage=true
        engine.updateCodexQuestions([CodexQuestionUpdate(sessionID:session.id,questions:[question])])
        do {_ = try await engine.remoteAction(cleanupBody([question],sessionID:session.id));throw AppError.message("Uncertain input hidden")}
        catch let error as RemoteHTTPError {try expectEqual(error.status,409)}
        do {_ = try await engine.remoteAction(cleanupBody([questions[0]],sessionID:session.id,restore:true));throw AppError.message("Unknown cleanup restored")}
        catch let error as RemoteHTTPError {try expectEqual(error.status,409)}
        try expectEqual(engine.snapshot.sessions[0].questions.first?.reply?.phase,.uncertain)
    }
    func testPastQuestionCleanupRollsBackStorageFailure() async throws {
        let (root,paths,engine,session,questions)=try cleanupFixture();defer{engine.stop();try? FileManager.default.removeItem(at:root)}
        var db:OpaquePointer?;try expectEqual(sqlite3_open(paths.database,&db),SQLITE_OK);defer{sqlite3_close(db)}
        try expectEqual(sqlite3_exec(db,"CREATE TRIGGER reject_cleanup BEFORE INSERT ON settings WHEN NEW.key LIKE 'dismissedQuestion:%' BEGIN SELECT RAISE(ABORT, 'synthetic'); END",nil,nil,nil),SQLITE_OK)
        do {_ = try await engine.remoteAction(cleanupBody(Array(questions.prefix(3)),sessionID:session.id));throw AppError.message("Rejected storage was published")}
        catch is AppError {}
        try expectEqual(engine.snapshot.sessions[0].questions.count,151)
        let store=try AuditStore(path:paths.database,readOnly:true)
        for q in questions.prefix(3) {try expectNil(store.value("dismissedQuestion:\(q.id)"));try expectNil(store.value("cleanedQuestion:\(q.id)"));try expectNil(store.value("questionAutomation:\(q.id)"))}
    }
}
