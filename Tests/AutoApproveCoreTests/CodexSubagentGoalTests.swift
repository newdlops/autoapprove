import Foundation
import AutoApproveCore

private final class ChildGoalFixture:@unchecked Sendable {
    let records=ProcessDiscovery.parse("101801 1 ttys801 101801 101801 Wed Nov 11 08:00:00 2026 /fixture/codex")
    let parent="00000000-0000-4000-8000-000000001801",child="00000000-0000-4000-8000-000000001802"
    private let lock=NSLock()
    private var alive=true,count=0,lost=false
    private var value:CodexSubagentGoal
    init() {
        value=CodexSubagentGoal(rootThreadID:parent,threadID:child,parentThreadID:parent,
            goal:CodexGoal(threadId:child,objective:"Keep the child Goal",status:.active,createdAt:10,updatedAt:20,tokensUsed:45,timeUsedSeconds:12,tokenBudget:1000,instanceID:"00000000-0000-4000-8000-000000001803"),executionState:"active",turnID:"observed-turn")
    }
    func read()->CodexSubagentGoal {lock.lock();defer{lock.unlock()};return value}
    func processes()->[ProcessRecord] {lock.lock();defer{lock.unlock()};return alive ? records:[]}
    func exit(){lock.lock();alive=false;lock.unlock()}
    func loseReply(){lock.lock();lost=true;lock.unlock()}
    var writes:Int {lock.lock();defer{lock.unlock()};return count}
    func check(_ expected:CodexSubagentGoal) throws {
        guard read().goal?.revision==expected.goal?.revision else {throw AppError.message("Stale child Goal")}
    }
    func change(_ action:CodexSubagentGoalAction) throws ->CodexSubagentGoal {
        lock.lock();defer{lock.unlock()};count+=1
        value.goal?.status=action == .pause ? .paused:.active
        value.executionState=action == .pause ? "idle":"active";value.turnID=action == .pause ? nil:"resumed-turn"
        if lost {throw AppError.message("Lost acknowledgement after mutation")};return value
    }
}

@MainActor private func childGoalEngine(_ fixture:ChildGoalFixture,_ directory:URL) throws ->ApprovalEngine {
    let paths=AppPaths(directory:directory);try paths.prepare()
    let store=try AuditStore(path:paths.database)
    try store.set("codexApprovalBinding:"+fixture.records[0].key,String(decoding:JSONEncoder().encode(CodexApprovalBinding(threadID:fixture.parent,title:"Owned parent")),as:UTF8.self))
    let target=CodexReplyTarget(executable:"/fixture/codex",home:directory.path,threadID:fixture.parent)
    let transport=CodexReplyTransport(prepare:{_,_ in target},send:{_,_ in "unused"},prepareMessage:{_ in target},prepareQueue:{_,_ in target})
    let goals=CodexSubagentGoalServices(read:{_,_,_ in fixture.read()},change:{_,_,expected,action,authorize in
        try fixture.check(expected);try await authorize();return try fixture.change(action)
    })
    let engine=try ApprovalEngine(paths:paths,questionTransport:transport,processReader:{fixture.processes()},codexSubagentGoals:goals)
    var session=ProcessDiscovery.sessions(fixture.records)[0];session.cwd=directory.path;session.terminal = .terminal
    engine.updateDiscovery([session],records:fixture.records)
    return engine
}

extension ApprovalTests {
    func testChildGoalActionsPreserveIdentityAndDeduplicate() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("aa-child-actions-"+UUID().uuidString),fixture=ChildGoalFixture()
        defer{try? FileManager.default.removeItem(at:directory)}
        let engine=try childGoalEngine(fixture,directory);defer{engine.stop()}
        let id=fixture.records[0].key,request=UUID(),before=try await engine.readCodexSubagentGoal(sessionID:id,childID:fixture.child)
        let paused=try await engine.changeCodexSubagentGoal(sessionID:id,expected:before,action:.pause,requestID:request)
        try expectEqual(paused.phase,.confirmed);try expectEqual(paused.result?.executionState,"idle")
        try expectEqual(paused.result?.goal?.instanceID,before.goal?.instanceID)
        try expectEqual(paused.result?.goal?.tokensUsed,45);try expectEqual(paused.result?.goal?.tokenBudget,1000)
        let duplicate=try await engine.changeCodexSubagentGoal(sessionID:id,expected:before,action:.pause,requestID:request)
        try expectEqual(duplicate.phase,.confirmed);try expectEqual(fixture.writes,1)
        let stale=try await engine.changeCodexSubagentGoal(sessionID:id,expected:before,action:.pause,requestID:UUID())
        try expectEqual(stale.phase,.notStarted);try expectEqual(fixture.writes,1)
        let resumed=try await engine.changeCodexSubagentGoal(sessionID:id,expected:paused.result!,action:.resume,requestID:UUID())
        try expectEqual(resumed.phase,.confirmed);try expectEqual(resumed.result?.goal?.status,.active);try expectEqual(fixture.writes,2)
        var rejected=false
        do {_ = try await engine.changeCodexSubagentGoal(sessionID:id,expected:paused.result!,action:.resume,requestID:request)}
        catch {rejected=true}
        try expect(rejected);try expectEqual(fixture.writes,2)
    }
    func testChildGoalUnknownSurvivesRestartAndStorageFailurePreventsDispatch() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("aa-child-unknown-"+UUID().uuidString),fixture=ChildGoalFixture()
        defer{try? FileManager.default.removeItem(at:directory)}
        let engine=try childGoalEngine(fixture,directory),id=fixture.records[0].key,request=UUID()
        let before=try await engine.readCodexSubagentGoal(sessionID:id,childID:fixture.child)
        fixture.loseReply()
        let unknown=try await engine.changeCodexSubagentGoal(sessionID:id,expected:before,action:.pause,requestID:request)
        try expectEqual(unknown.phase,.unknown);try expectEqual(fixture.writes,1);engine.stop()
        let restored=try childGoalEngine(fixture,directory);defer{restored.stop()}
        let duplicate=try await restored.changeCodexSubagentGoal(sessionID:id,expected:before,action:.pause,requestID:request)
        try expectEqual(duplicate.phase,.unknown);try expectEqual(fixture.writes,1)
        let other=directory.appendingPathComponent("broken"),clean=ChildGoalFixture(),broken=try childGoalEngine(clean,other);defer{broken.stop()}
        try FileManager.default.createDirectory(at:other.appendingPathComponent("subagent-goal-actions.sqlite"),withIntermediateDirectories:false)
        var rejected=false
        do {_ = try await broken.changeCodexSubagentGoal(sessionID:clean.records[0].key,expected:clean.read(),action:.pause,requestID:UUID())}
        catch {rejected=true}
        try expect(rejected);try expectEqual(clean.writes,0)
    }
    func testChildGoalRejectsExitedParentAndChangedBinding() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("aa-child-owner-"+UUID().uuidString),fixture=ChildGoalFixture()
        defer{try? FileManager.default.removeItem(at:directory)}
        let engine=try childGoalEngine(fixture,directory);defer{engine.stop()};let before=fixture.read(),id=fixture.records[0].key
        let foreign=CodexSubagentGoal(rootThreadID:fixture.child,threadID:fixture.parent,parentThreadID:fixture.child,goal:before.goal)
        var rejected=false
        do {_ = try await engine.changeCodexSubagentGoal(sessionID:id,expected:foreign,action:.pause,requestID:UUID())}
        catch {rejected=true}
        try expect(rejected);try expectEqual(fixture.writes,0)
        fixture.exit()
        rejected=false
        do {_ = try await engine.changeCodexSubagentGoal(sessionID:id,expected:before,action:.pause,requestID:UUID())}
        catch {rejected=true}
        try expect(rejected);try expectEqual(fixture.writes,0)
    }
}
