import Foundation
import Darwin
import TerminalInputSupport
import AutoApproveCore

private let progressWorking="• Working (12s • esc to interrupt)\n\n› Ask Codex to do anything\n\n? for shortcuts"
private let progressReady="Conversation interrupted\n\n› Ask Codex to do anything\n\n? for shortcuts"
private final class ProgressFixture:@unchecked Sendable {
    private let condition=NSCondition()
    private var raw=progressWorking
    private var values:[RemoteTerminalInput]=[]
    private var held=false,validations=0
    private var onEscape:(@Sendable ()->Void)?
    func afterEscape(_ action:@escaping @Sendable ()->Void){condition.lock();onEscape=action;condition.unlock()}
    var mode="normal"
    let records=ProcessDiscovery.parse("100801 1 ttys801 100801 100801 Wed Oct 28 22:00:00 2026 /fixture/codex")
    private var live=true
    private var typing=false
    func typeNow(){condition.lock();typing=true;condition.unlock()}
    func idleSeconds()->TimeInterval {condition.lock();defer{condition.unlock()};return typing ? 0:.infinity}
    func processes()->[ProcessRecord] {condition.lock();defer{condition.unlock()};return live ? records:[]}
    func replaceProcess(){condition.lock();live=false;condition.unlock()}
    func read()->String {condition.lock();defer{condition.unlock()};return raw}
    func validate()->String {condition.lock();defer{condition.unlock()};validations+=1;while held {condition.wait()};return raw}
    func hold(){condition.lock();held=true;condition.unlock()}
    func release(){condition.lock();held=false;condition.broadcast();condition.unlock()}
    func replace(_ text:String){condition.lock();raw=text;condition.unlock()}
    var reads:Int {condition.lock();defer{condition.unlock()};return validations}
    var inputs:[RemoteTerminalInput] {condition.lock();defer{condition.unlock()};return values}
    func input(_ expected:String,_ value:RemoteTerminalInput) throws -> TerminalDelivery {
        condition.lock();defer{condition.unlock()}
        guard raw==expected else {return .screenChanged}
        values.append(value)
        if value.kind == .escape {
            onEscape?()
            if mode=="draft" {raw=progressReady.replacingOccurrences(of:"Ask Codex to do anything",with:"UNSENT USER DRAFT")}
            else if mode != "hang" {raw=progressReady}
        }
        if value.kind == .submit {
            if mode=="uncertain" {throw AppError.message("Synthetic uncertain submission")}
            raw="New request\n"+progressWorking
        }
        return .sent
    }
    func identity()->TTYInputIdentity {
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.timeZone = .current;formatter.dateFormat="EEE MMM d HH:mm:ss yyyy"
        return .init(pid:records[0].pid,processGroup:records[0].processGroup,uid:getuid(),effectiveUID:geteuid(),device:42,startSeconds:UInt64(formatter.date(from:records[0].started)!.timeIntervalSince1970),startMicroseconds:70)
    }
}
@MainActor private func progressEngine(_ fixture:ProgressFixture,root:URL) async throws -> (ApprovalEngine,String) {
    let adapter=ScreenHostAdapter(screens:{targets in .init(screens:targets.map {.init(tty:$0.tty,contents:fixture.read())})},approve:{_,_,_ in .missingTarget},reveal:{_ in nil},input:{_,expected,_,input in try fixture.input(expected,input)},validationScreens:{targets in .init(screens:targets.map {.init(tty:$0.tty,contents:fixture.validate())})})
    let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{fixture.processes()},screenAdapters:[.terminal:adapter],terminalInputAvailable:{true},terminalInputIdentity:{_ in fixture.identity()},nativeKeyboardActivity:.init(idleSeconds:{fixture.idleSeconds()},frontmostBundle:{"com.apple.Terminal"}))
    var session=ProcessDiscovery.sessions(fixture.records)[0];session.terminal = .terminal
    engine.updateDiscovery([session],records:fixture.records);await engine.connectTerminal();try engine.setAutomatic(session.id,enabled:true)
    engine.receiveScreen(sessionID:session.id,raw:fixture.read(),generation:"progress-fixture")
    engine.codexProgressWaitSeconds=0.75
    return (engine,session.id)
}
@MainActor private func progressUntil(_ condition:()->Bool) async throws {
    let deadline=Date().addingTimeInterval(5)
    while !condition(),Date()<deadline {try await Task.sleep(for:.milliseconds(20))}
    guard condition() else {throw AppError.message("Progress fixture wait timed out")}
}

extension ApprovalTests {
    func testCodexProgressScreenIgnoresSpinnerAndTimerButKeepsDrafts() throws {
        let a=progressWorking.replacingOccurrences(of:"•",with:"⠋").replacingOccurrences(of:"12s",with:"1m 2s")
        let b=progressWorking.replacingOccurrences(of:"•",with:"⠙").replacingOccurrences(of:"12s",with:"7h 42m 10s")
        try expectEqual(CodexProgressScreen.workingFingerprint(a),CodexProgressScreen.workingFingerprint(b))
        try expect(CodexProgressScreen.workingFingerprint(progressWorking) != nil)
        try expectNil(CodexProgressScreen.workingFingerprint(progressWorking.replacingOccurrences(of:"Ask Codex to do anything",with:"UNSENT DRAFT")))
        try expectNil(CodexProgressScreen.workingFingerprint("Working\nesc to interrupt"))
        try expect(CodexProgressScreen.ready(progressReady));try expect(!CodexProgressScreen.ready(progressWorking))
        try expect(CodexProgressScreen.workingFingerprint("Tool output changed\n"+progressWorking) != CodexProgressScreen.workingFingerprint(progressWorking))
    }
    func testCodexProgressNeedsContinuousThirtyMinutesAndExactHistory() throws {
        let start=Date(timeIntervalSince1970:1793200000)
        var tracker=CodexProgressTracker(fingerprint:"same",generation:"one",at:start,historyToken:"thread:10")
        for second in 1...1800 {tracker.observe(fingerprint:"same",generation:"one",at:start.addingTimeInterval(Double(second)),historyToken:"thread:10");try expectEqual(tracker.isDue(at:start.addingTimeInterval(Double(second))),second==1800)}
        tracker.observe(fingerprint:"same",generation:"one",at:start.addingTimeInterval(1801),historyToken:"thread:11")
        try expect(!tracker.isDue(at:start.addingTimeInterval(1801)))
        tracker.observe(fingerprint:"same",generation:"one",at:start.addingTimeInterval(4000),historyToken:"thread:11")
        try expectEqual(tracker.status.lastProgressAt,start.addingTimeInterval(4000),"Sleep or a lost observation restarts the clock")
        tracker.observe(fingerprint:"same",generation:"new",at:start.addingTimeInterval(4001),historyToken:"thread:11")
        try expectEqual(tracker.status.lastProgressAt,start.addingTimeInterval(4001))
        tracker.set(.interrupting,detail:"synthetic",at:start.addingTimeInterval(4001))
        let restored=CodexProgressTracker(fingerprint:"same",generation:"new",at:start.addingTimeInterval(8000),previous:tracker.status)
        try expectEqual(restored.status.phase,.review);try expect(!restored.isDue(at:start.addingTimeInterval(8001)))
    }
    func testCodexProgressInterruptsOnceWaitsThenAsksAndContinues() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-progress-"+UUID().uuidString),fixture=ProgressFixture()
        defer{fixture.release();try? FileManager.default.removeItem(at:root)}
        let (engine,id)=try await progressEngine(fixture,root:root);defer{engine.stop()}
        fixture.afterEscape {Task {@MainActor in
            var update=CodexQuestionUpdate(sessionID:id,questions:[],turn:.init(threadID:"exact-root",turnID:"interrupted-turn",status:"interrupted"))
            update.progressToken="exact-root:12";engine.updateCodexQuestions([update])
        }}
        try engine.requestCodexProgressCheck(id)
        try expectThrows(try engine.requestCodexProgressCheck(id))
        try await progressUntil {engine.snapshot.sessions.first?.codexProgressRecovery?.phase == .requested}
        try expectEqual(fixture.inputs.map(\.kind),[.escape,.submit]);try expectEqual(fixture.inputs.last?.text,CodexProgressRecovery.prompt)
        try expectThrows(try engine.requestCodexProgressCheck(id));try expectEqual(fixture.inputs.count,2)
        try expectEqual(engine.snapshot.sessions.first?.phaseTitle,"진행 확인 요청됨")
    }
    func testCodexProgressAutomaticallyChecksAfterThreshold() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-progress-auto-"+UUID().uuidString),fixture=ProgressFixture()
        defer{fixture.release();try? FileManager.default.removeItem(at:root)}
        let (engine,id)=try await progressEngine(fixture,root:root);defer{engine.stop()}
        engine.codexProgressTimeout=0.02
        try await Task.sleep(for:.milliseconds(40))
        engine.receiveScreen(sessionID:id,raw:fixture.read(),generation:"progress-fixture")
        try await progressUntil {engine.snapshot.sessions.first?.codexProgressRecovery?.phase == .requested}
        try expectEqual(fixture.inputs.map(\.kind),[.escape,.submit])
    }
    func testCodexProgressNeverRestartsAFinishedRecordedTurn() async throws {
        for status in ["completed","failed","interrupted"] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-progress-finished-"+UUID().uuidString),fixture=ProgressFixture()
            defer{fixture.release();try? FileManager.default.removeItem(at:root)}
            let (engine,id)=try await progressEngine(fixture,root:root);defer{engine.stop()}
            var update=CodexQuestionUpdate(sessionID:id,questions:[],turn:.init(threadID:"exact-root",turnID:"last-turn",status:status,completedAt:Date()))
            update.progressToken="exact-root:10";engine.updateCodexQuestions([update])
            engine.receiveScreen(sessionID:id,raw:fixture.read(),generation:"progress-fixture")
            try expectThrows(try engine.requestCodexProgressCheck(id))
            try expectEqual(engine.snapshot.sessions.first?.codexProgressRecovery?.phase,.review)
            try expect(fixture.inputs.isEmpty)
        }
    }
    func testCodexProgressNeverTypesOverDraftOrUnconfirmedInterruption() async throws {
        for mode in ["draft","hang","uncertain"] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-progress-"+UUID().uuidString),fixture=ProgressFixture();fixture.mode=mode
            defer{fixture.release();try? FileManager.default.removeItem(at:root)}
            let (engine,id)=try await progressEngine(fixture,root:root);defer{engine.stop()}
            try engine.requestCodexProgressCheck(id)
            try await progressUntil {engine.snapshot.sessions.first?.codexProgressRecovery?.phase == .review}
            try expectEqual(fixture.inputs.map(\.kind),mode=="uncertain" ? [.escape,.submit]:[.escape])
            try expectThrows(try engine.requestCodexProgressCheck(id))
            if mode=="draft" {try expect(fixture.read().contains("UNSENT USER DRAFT"))}
        }
    }
    func testCodexProgressCancellationPauseOffAndProcessReplacementPreventInput() async throws {
        for mode in ["cancel","pause","off","replace","stop","new-output","keyboard"] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-progress-"+UUID().uuidString),fixture=ProgressFixture()
            defer{fixture.release();try? FileManager.default.removeItem(at:root)}
            let (engine,id)=try await progressEngine(fixture,root:root);defer{engine.stop()}
            let baseline=fixture.reads
            fixture.hold();try engine.requestCodexProgressCheck(id);try await progressUntil {fixture.reads>baseline}
            switch mode {
            case "cancel":engine.cancelCodexProgressCheck(id)
            case "pause":try engine.setPaused(true)
            case "off":try engine.setAutomatic(id,enabled:false)
            case "replace":fixture.replaceProcess()
            case "stop":engine.stop()
            case "keyboard":fixture.typeNow()
            default:fixture.replace("NEW PROGRESS\n"+progressWorking)
            }
            fixture.release();try await Task.sleep(for:.milliseconds(150))
            try expect(fixture.inputs.isEmpty,mode+" must preserve original input")
        }
    }
    func testCodexProgressGlobalOffPersistsAndOldSnapshotsRemainReadable() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-progress-"+UUID().uuidString),fixture=ProgressFixture()
        defer{fixture.release();try? FileManager.default.removeItem(at:root)}
        let (engine,id)=try await progressEngine(fixture,root:root)
        try engine.setCodexProgressRecoveryEnabled(false);try expectThrows(try engine.requestCodexProgressCheck(id));engine.stop()
        let restored=try ApprovalEngine(paths:.init(directory:root),processReader:{[]});defer{restored.stop()}
        try expectEqual(restored.snapshot.codexProgressRecoveryEnabled,false)
        var session=AgentSession(id:"legacy",agent:.codex,pid:1,started:"old",tty:"/dev/fixture",cwd:"/tmp",terminal:.terminal)
        let old=try JSONEncoder().encode(session);try expectNil(try JSONDecoder().decode(AgentSession.self,from:old).codexProgressRecovery)
        session.codexProgressRecovery = .init(phase:.review,lastProgressAt:Date(),detail:"synthetic")
        try expectEqual(session.phaseTitle,"진척 확인 필요")
    }
}
