import Foundation
import CSQLite
import AutoApproveCore

private final class GoalFixture:@unchecked Sendable {
    let records=ProcessDiscovery.parse("100701 1 ttys701 100701 100701 Wed Oct 28 22:00:00 2026 /fixture/codex")
    let thread="00000000-0000-4000-8000-000000000701"
    private let lock=NSLock()
    private var value:CodexGoal?=CodexGoal(threadId:"00000000-0000-4000-8000-000000000701",objective:"Keep this exact conversation",status:.blocked,createdAt:100,updatedAt:110,instanceID:"original-goal")
    private var actions:[CodexGoalAction]=[]
    private var alive=true
    private var raw="Ready\n\n› Ask Codex to do anything\n\n? for shortcuts\nGoal stalled (/goal resume)"
    private var inputs:[String]=[]
    var uncertain=false
    func read()->CodexGoal? {lock.lock();defer{lock.unlock()};return value}
    func replace(_ goal:CodexGoal?) {lock.lock();value=goal;lock.unlock()}
    func processes()->[ProcessRecord] {lock.lock();defer{lock.unlock()};return alive ? records:[]}
    func exit(){lock.lock();alive=false;lock.unlock()}
    func screen()->String {lock.lock();defer{lock.unlock()};return raw}
    func draft(){lock.lock();raw="Ready\n\n› MY UNSENT DRAFT\n\nGoal stalled (/goal resume)";lock.unlock()}
    func change(_ expected:CodexGoal,_ action:CodexGoalAction) throws -> CodexGoal? {
        lock.lock();defer{lock.unlock()}
        guard value?.revision==expected.revision else {throw RemoteHTTPError(409,"Synthetic stale Goal",diagnostics:["delivery":"not_started"])}
        actions.append(action)
        if action == .resume {value?.status = .active} else {value=nil}
        if uncertain {throw AppError.message("Synthetic lost reply")}
        return value
    }
    func input(_ expected:String,_ input:RemoteTerminalInput) throws -> TerminalDelivery {
        lock.lock();defer{lock.unlock()}
        guard raw==expected else {return .screenChanged}
        inputs.append(input.text)
        if input.text=="/goal resume" {value?.status = .active;raw="• Working (1s • esc to interrupt)\n\n› Ask Codex to do anything"}
        else if input.text=="/goal clear" {value=nil;raw="Ready\n\n› Ask Codex to do anything\n\n? for shortcuts"}
        if uncertain {throw AppError.message("Synthetic lost native reply")}
        return .sent
    }
    var writes:Int {lock.lock();defer{lock.unlock()};return actions.count+inputs.count}
}
@MainActor private func goalEngine(_ fixture:GoalFixture,root:URL,native:Bool=false) async throws -> (ApprovalEngine,String) {
    let target=CodexReplyTarget(executable:"/fixture/codex",home:root.path,threadID:fixture.thread,queueAvailable:!native)
    let transport=CodexReplyTransport(prepare:{_,_ in target},send:{_,_ in throw AppError.message("No queued slash commands")},prepareMessage:{_ in target})
    let goal=CodexGoalTransport(read:{_,_ in fixture.read()},change:{_,_,expected,action in try fixture.change(expected,action)})
    let adapter=ScreenHostAdapter(screens:{targets in .init(screens:targets.map {.init(tty:$0.tty,contents:fixture.screen())})},approve:{_,_,_ in .missingTarget},reveal:{_ in nil},input:{_,expected,_,input in try fixture.input(expected,input)})
    let engine=try ApprovalEngine(paths:.init(directory:root),questionTransport:transport,processReader:{fixture.processes()},screenAdapters:[.terminal:adapter],terminalInputAvailable:{false},codexGoals:goal)
    var session=ProcessDiscovery.sessions(fixture.records)[0];session.terminal = .terminal;session.cwd=root.path
    engine.updateDiscovery([session],records:fixture.records)
    if native {await engine.connectTerminal()}
    return (engine,session.id)
}
extension ApprovalTests {
    func testCodexGoalLifecycleUsesExactRevisionAndPreservesOriginal() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-goal-"+UUID().uuidString),fixture=GoalFixture();defer{try? FileManager.default.removeItem(at:root)}
        let (engine,id)=try await goalEngine(fixture,root:root);defer{engine.stop()}
        let first=try await engine.remoteCodexGoal(sessionID:id);try expect(first.canResume);try expect(first.canCancel)
        _ = try await engine.remoteAction(["action":"resumeGoal","sessionID":id,"threadID":fixture.thread,"goalRevision":first.revision!])
        try expectEqual(fixture.read()?.status,.active);try expectEqual(fixture.writes,1)
        do {_ = try await engine.remoteAction(["action":"cancelGoal","sessionID":id,"threadID":fixture.thread,"goalRevision":first.revision!]);throw AppError.message("Stale state accepted")} catch let e as RemoteHTTPError {try expectEqual(e.status,409)}
        let current=try await engine.remoteCodexGoal(sessionID:id);try expect(!current.canResume)
        _ = try await engine.remoteAction(["action":"cancelGoal","sessionID":id,"threadID":fixture.thread,"goalRevision":current.revision!])
        try expectNil(fixture.read());try expectEqual(fixture.writes,2)
        try expectEqual(engine.snapshot.sessions.first?.id,id);try expect(engine.managedPTY.inventory.isEmpty)
        try expect(engine.snapshot.events.contains {$0.outcome=="Goal 취소 확인"})
        await engine.connectTerminal();try engine.setAutomatic(id,enabled:true)
        let now=Date();engine.receiveScreen(sessionID:id,raw:fixture.screen(),generation:"goal-hold",at:now)
        engine.receiveScreen(sessionID:id,raw:fixture.screen(),generation:"goal-hold",at:now.addingTimeInterval(3))
        try expectNil(engine.snapshot.sessions.first?.capacityResume)
        var same=first.goal!;same.instanceID=nil;fixture.replace(same)
        _ = try await engine.remoteCodexGoal(sessionID:id)
        engine.receiveScreen(sessionID:id,raw:fixture.screen(),generation:"goal-hold",at:now.addingTimeInterval(4))
        try expectNil(engine.snapshot.sessions.first?.capacityResume)
        fixture.replace(CodexGoal(threadId:fixture.thread,objective:"A new Goal",status:.blocked,createdAt:200,updatedAt:200))
        do {_ = try await engine.remoteAction(["action":"cancelGoal","sessionID":id,"threadID":fixture.thread,"goalRevision":current.revision!]);throw AppError.message("Replacement Goal accepted")} catch let e as RemoteHTTPError {try expectEqual(e.status,409)}
        fixture.exit()
        do {_ = try await engine.remoteCodexGoal(sessionID:id);throw AppError.message("Exited CLI accepted")} catch let e as RemoteHTTPError {try expectEqual(e.status,409)}
        try expectEqual(fixture.writes,2)
    }
    func testCodexGoalNativeFallbackPreservesDraftAndNeverReplaysUnknown() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-goal-native-"+UUID().uuidString),fixture=GoalFixture();defer{try? FileManager.default.removeItem(at:root)}
        let (engine,id)=try await goalEngine(fixture,root:root,native:true);defer{engine.stop()}
        let first=try await engine.remoteCodexGoal(sessionID:id);try expectEqual(first.transport,"terminal");try expect(first.canResume)
        _ = try await engine.remoteAction(["action":"resumeGoal","sessionID":id,"threadID":fixture.thread,"goalRevision":first.revision!])
        try expectEqual(fixture.writes,1);try expectEqual(fixture.read()?.status,.active)
        fixture.draft()
        let revision=fixture.read()!.revision
        do {_ = try await engine.remoteAction(["action":"cancelGoal","sessionID":id,"threadID":fixture.thread,"goalRevision":revision]);throw AppError.message("Draft overwritten")} catch let e as RemoteHTTPError {try expectEqual(e.status,409)}
        try expectEqual(fixture.writes,1);try expect(fixture.screen().contains("MY UNSENT DRAFT"))
        let uncertain=GoalFixture();uncertain.uncertain=true
        let (second,secondID)=try await goalEngine(uncertain,root:root.appendingPathComponent("unknown"));defer{second.stop()}
        let before=try await second.remoteCodexGoal(sessionID:secondID)
        do {_ = try await second.remoteAction(["action":"cancelGoal","sessionID":secondID,"threadID":uncertain.thread,"goalRevision":before.revision!]);throw AppError.message("Unknown result ignored")} catch let e as RemoteHTTPError {try expectEqual(e.diagnostics?["delivery"],"unknown")}
        try expectEqual(uncertain.writes,1);try expectNil(try await second.remoteCodexGoal(sessionID:secondID).goal)
        try await Task.sleep(for:.milliseconds(250));try expectEqual(uncertain.writes,1)
    }
    func testCodexGoalReadOnlyDatabaseAndUsageRevision() throws {
        for footer in ["Goal paused (/goal resume)","Goal hit usage limits","Goal hit budget","Goal achieved"] {
            let raw="Ready\n\n› Ask Codex to do anything\n\n? for shortcuts\n"+footer
            try expect(CodexGoalScreen.ready(raw));try expect(!CodexGoalScreen.ready(raw.replacingOccurrences(of:"Ask Codex to do anything",with:"UNSENT DRAFT")))
            try expect(!CodexGoalScreen.ready(raw+"\nVim: Normal"));try expect(!CodexGoalScreen.ready(raw+"\nesc to interrupt"))
        }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-goal-db-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let path=root.appendingPathComponent("goals_1.sqlite"),thread="00000000-0000-4000-8000-000000000701"
        var db:OpaquePointer?;try expectEqual(sqlite3_open(path.path,&db),SQLITE_OK)
        let sql="CREATE TABLE thread_goals(thread_id TEXT PRIMARY KEY,goal_id TEXT,objective TEXT,status TEXT,token_budget INTEGER,tokens_used INTEGER,time_used_seconds INTEGER,created_at_ms INTEGER,updated_at_ms INTEGER); INSERT INTO thread_goals VALUES('\(thread)','exact-goal','Keep this Goal','usage_limited',NULL,42,30,100000,110000);"
        try expectEqual(sqlite3_exec(db,sql,nil,nil,nil),SQLITE_OK);sqlite3_close(db)
        let before=try Data(contentsOf:path),goal=try CodexGoalTransport.readDatabase(home:root.path,threadID:thread)
        try expectEqual(goal?.status,.usageLimited);try expectEqual(goal?.instanceID,"exact-goal");try expectEqual(goal?.tokensUsed,42)
        try expectNil(try CodexGoalTransport.readDatabase(home:root.path,threadID:UUID().uuidString));try expectEqual(try Data(contentsOf:path),before)
        var changed=goal!;changed.tokensUsed+=100;changed.updatedAt+=10;try expectEqual(changed.revision,goal?.revision)
        changed.instanceID="replacement";try expect(changed.revision != goal?.revision)
    }
}
