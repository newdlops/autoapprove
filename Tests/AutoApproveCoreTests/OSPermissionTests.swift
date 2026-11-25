import Foundation
import AutoApproveCore

private final class OSFixture:@unchecked Sendable {
    private let condition=NSCondition()
    let records=ProcessDiscovery.parse("100901 1 ttys901 100901 100901 Wed Oct 28 22:00:00 2026 /fixture/codex\n100902 1 ttys902 100902 100902 Wed Oct 28 22:01:00 2026 /fixture/claude")
    var target=OSPermissionTarget(name:"Permission QA",bundleID:"local.permission.qa",path:"/fixture/Permission QA.app",requirement:"identifier local.permission.qa and certificate leaf = H\"stable\"",pid:100990,started:"same app start")
    private var requests:[OSPermissionRequest]=[],values:[String]=[]
    private var held=false,readCount=0,live=true,typing=false
    private var replacement:[ProcessRecord]?
    var launcher:Int32?
    func ancestry(_ pid:Int32)->[ProcessRecord] {
        var app=records[0],root=records[0]
        root.pid=1;root.parent=0;root.executable="/sbin/launchd"
        app.pid=pid;app.parent=launcher ?? 1;app.started=target.started;app.executable=target.path
        return [app]+processes().filter {$0.pid==launcher}+[root]
    }
    var beforeApproval:(@MainActor ()->Void)?
    var result:OSPermissionDelivery = .sent
    func set(_ requests:[OSPermissionRequest]) {condition.lock();self.requests=requests;condition.unlock()}
    func hold() {condition.lock();held=true;condition.unlock()}
    func release() {condition.lock();held=false;condition.broadcast();condition.unlock()}
    func exited() {condition.lock();live=false;condition.unlock()}
    func typeNow() {condition.lock();typing=true;condition.unlock()}
    func idle()->TimeInterval {condition.lock();defer{condition.unlock()};return typing ? 0:.infinity}
    func processes()->[ProcessRecord] {condition.lock();defer{condition.unlock()};return live ? replacement ?? records:[]}
    func replace(_ records:[ProcessRecord]) {condition.lock();replacement=records;condition.unlock()}
    func scan()->OSPermissionMonitorStatus {
        condition.lock();defer{condition.unlock()};readCount+=1;while held {condition.wait()}
        return .init(available:true,detail:"Synthetic OS permission source; no system input",requests:requests)
    }
    var reads:Int {condition.lock();defer{condition.unlock()};return readCount}
    var presses:[String] {condition.lock();defer{condition.unlock()};return values}
    func pressed(_ id:String) {condition.lock();values.append(id);condition.unlock()}
    func request(_ suffix:String="one",kind:OSPermissionKind = .camera,action:OSPermissionRequest.Action = .allow,target:OSPermissionTarget?=nil)->OSPermissionRequest {
        .init(kind:kind,requester:target ?? self.target,ownerPID:77,ownerStarted:"OS same start",ownerBundleID:"com.apple.UserNotificationCenter",windowToken:suffix,content:"\"Permission QA\" would like to access the camera. "+suffix,action:action,actionToken:"allow-"+suffix,buttons:[.init(id:"allow-"+suffix,title:"Allow",kind:.allow),.init(id:"deny-"+suffix,title:"Don't Allow",kind:.deny)])
    }
}
@MainActor private func osEngine(_ fixture:OSFixture,root:URL,
    readCodex:(@Sendable (ProcessRecord) throws -> CodexThreadLocation?)? = nil,
    prepare:(@Sendable (OSPermissionRequest,OSPermissionTarget) throws -> OSPermissionServices.PreparedApproval?)? = nil) async throws -> (ApprovalEngine,[String]) {
    let service=OSPermissionServices(ancestry:{fixture.ancestry($0)},scan:{_ in fixture.scan()},approve:{request,authorized in
        fixture.beforeApproval?()
        guard authorized() else {return .unavailable("Synthetic authorization was revoked")};fixture.pressed(request.id);return fixture.result
    },prepareApproval:prepare,respond:{request,button,authorized in
        fixture.beforeApproval?()
        guard authorized() else {return .unavailable("Synthetic authorization was revoked")};fixture.pressed(request.id+":"+button.id);return fixture.result
    })
    let adapter=ScreenHostAdapter(screens:{targets in .init(screens:targets.map {.init(tty:$0.tty,contents:"• Working (12s • esc to interrupt)\n› Ask Codex to do anything")})},approve:{_,_,_ in fixture.pressed("TERMINAL_APPROVAL");return .sent},reveal:{_ in nil},input:{_,_,_,_ in fixture.pressed("TERMINAL_INPUT");return .sent})
    let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{fixture.processes()},screenAdapters:[.terminal:adapter],codexGroupReader:readCodex,nativeKeyboardActivity:.init(idleSeconds:{fixture.idle()},frontmostBundle:{"com.apple.Terminal"}),osPermissionServices:service)
    var sessions=ProcessDiscovery.sessions(fixture.records)
    sessions.sort {$0.agent.rawValue>$1.agent.rawValue}
    for index in sessions.indices {sessions[index].terminal = .terminal}
    engine.updateDiscovery(sessions,records:fixture.records)
    await engine.connectTerminal()
    for session in sessions {try engine.setAutomatic(session.id,enabled:true)}
    return (engine,sessions.map(\.id))
}
@MainActor private func osUntil(_ predicate:()->Bool) async throws {
    let end=Date().addingTimeInterval(3)
    while !predicate() {
        guard Date()<end else {throw AppError.message("OS permission fixture did not reach its gate")}
        try await Task.sleep(for:.milliseconds(10))
    }
}

extension ApprovalTests {
    func testOSPermissionManualResponseWithoutAutomaticPolicyAndDurableReplayGuard() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-os-manual-"+UUID().uuidString),fixture=OSFixture();defer{try? FileManager.default.removeItem(at:root)}
        let (engine,ids)=try await osEngine(fixture,root:root);let id=ids[0],request=fixture.request();fixture.set([request]);try engine.setAutomatic(id,enabled:false)
        await engine.refreshOSPermissions()
        func payload(_ session:String)->JSONObject {["action":"respondOSPermission","sessionID":session,"permissionID":request.id,"permissionToken":request.immutableToken,"buttonID":"deny-one","policyRevision":"initial"]}
        do {_ = try await engine.remoteAction(payload(id));throw AppError.message("Unbound request accepted")} catch let error as RemoteHTTPError {try expectEqual(error.status,409)}
        try engine.assignOSPermission(id,requestID:request.id,token:request.immutableToken,remember:false)
        do {_ = try await engine.remoteAction(payload(ids[1]));throw AppError.message("Another session responded")} catch let error as RemoteHTTPError {try expectEqual(error.status,409)}
        _ = try await engine.remoteAction(payload(id))
        try expectEqual(fixture.presses,[request.id+":deny-one"]);try expectEqual(engine.snapshot.osPermissions?.requests.first?.phase,.submitted)
        try expectEqual(engine.snapshot.sessions.first(where:{$0.id==id})?.automatic,false);try expectNil(engine.snapshot.sessions.first(where:{$0.id==id})?.osPermissionPolicy)
        do {_ = try await engine.remoteAction(payload(id));throw AppError.message("Duplicate response accepted")} catch let error as RemoteHTTPError {try expectEqual(error.status,409)}
        engine.stop();let (reopened,_)=try await osEngine(fixture,root:root);defer{reopened.stop()};await reopened.refreshOSPermissions()
        do {_ = try await reopened.remoteAction(payload(id));throw AppError.message("Restart replay accepted")} catch let error as RemoteHTTPError {try expectEqual(error.status,409)}
        try expectEqual(fixture.presses,[request.id+":deny-one"])
        // Old receipts must decode with no button field and preserve the exact replay key.
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(request)) as! JSONObject;object.removeValue(forKey:"buttons")
        let old=try JSONDecoder().decode(OSPermissionRequest.self,from:JSONSerialization.data(withJSONObject:object))
        try expectNil(old.buttons);try expectEqual(old.immutableToken,request.immutableToken)
    }
    func testOSPermissionManualResponseRejectsStaleProtectedPausedAndChangedSource() async throws {
        for mode in ["token","button","protected","setting","pause","process","last-moment","changed-button"] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-os-manual-race-"+UUID().uuidString),fixture=OSFixture();defer{try? FileManager.default.removeItem(at:root)}
            let (engine,ids)=try await osEngine(fixture,root:root);defer{engine.stop()};let id=ids[0]
            let request=fixture.request(action:mode=="protected" ? .manual:mode=="setting" ? .enableSetting:.allow);fixture.set([request]);await engine.refreshOSPermissions()
            try engine.assignOSPermission(id,requestID:request.id,token:request.immutableToken,remember:false)
            if mode=="pause" {try engine.setPaused(true)}
            if mode=="process" {fixture.exited()}
            if mode=="last-moment" {fixture.beforeApproval={fixture.exited()}}
            if mode=="changed-button" {var changed=request;changed.buttons=[.init(id:"new",title:"Cancel",kind:.deny)];fixture.set([changed]);await engine.refreshOSPermissions()}
            do {try engine.respondOSPermission(id,requestID:request.id,token:mode=="token" ? "stale":request.immutableToken,buttonID:mode=="button" ? "unknown":"deny-one");throw AppError.message(mode+" accepted")} catch let error as RemoteHTTPError {try expectEqual(error.status,409)}
            try expectEqual(fixture.presses,[],mode)
        }
    }
    func testOSPermissionManualUncertainResponseCannotBeRetriedOrAutoAllowed() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-os-manual-uncertain-"+UUID().uuidString),fixture=OSFixture();defer{try? FileManager.default.removeItem(at:root)}
        fixture.result = .uncertain("Synthetic lost reply");let (engine,ids)=try await osEngine(fixture,root:root);defer{engine.stop()};let id=ids[0],request=fixture.request();fixture.set([request]);await engine.refreshOSPermissions()
        try engine.assignOSPermission(id,requestID:request.id,token:request.immutableToken,remember:true)
        do {try engine.respondOSPermission(id,requestID:request.id,token:request.immutableToken,buttonID:"deny-one");throw AppError.message("Unknown delivery reported success")} catch let error as RemoteHTTPError {try expectEqual(error.status,409)}
        try engine.setOSPermissionPolicy(id,allowed:[.camera]);await engine.refreshOSPermissions();await engine.refreshOSPermissions()
        try expectEqual(engine.snapshot.osPermissions?.requests.first?.phase,.uncertain);try expectEqual(fixture.presses,[request.id+":deny-one"])
    }
    func testOSPermissionWebRevisionRejectsStalePolicyAndABARestore() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-os-web-revision-"+UUID().uuidString),fixture=OSFixture();defer{try? FileManager.default.removeItem(at:root)}
        let (engine,ids)=try await osEngine(fixture,root:root);defer{engine.stop()};let id=ids[0]
        _ = try await engine.remoteAction(["action":"osPermissionPolicy","sessionID":id,"allowed":["camera"],"policyRevision":"initial"])
        let revision=engine.snapshot.sessions.first(where:{$0.id==id})!.osPermissionPolicy!.revision!
        try engine.setOSPermissionPolicy(id,allowed:[])
        do {_ = try await engine.remoteAction(["action":"osPermissionPolicy","sessionID":id,"allowed":["camera","microphone"],"policyRevision":revision]);throw AppError.message("Stale policy restored a revoked grant")} catch let error as RemoteHTTPError {try expectEqual(error.status,409)}
        try engine.setOSPermissionPolicy(id,allowed:[.camera])
        do {_ = try await engine.remoteAction(["action":"osPermissionPolicy","sessionID":id,"allowed":["camera","microphone"],"policyRevision":revision]);throw AppError.message("ABA policy accepted")} catch let error as RemoteHTTPError {try expectEqual(error.status,409)}
        try expectEqual(engine.snapshot.sessions.first(where:{$0.id==id})?.osPermissionPolicy?.allowed,[.camera]);try expectEqual(fixture.presses,[])
        fixture.exited()
        let latest=engine.snapshot.sessions.first(where:{$0.id==id})!.osPermissionPolicy!.revision!
        do {_ = try await engine.remoteAction(["action":"osPermissionPolicy","sessionID":id,"allowed":["microphone"],"policyRevision":latest]);throw AppError.message("Exited source accepted")} catch let error as RemoteHTTPError {try expectEqual(error.status,409)}
    }
    func testOSPermissionPolicyIdentityAndPromptAttribution() throws {
        let fixture=OSFixture(),request=fixture.request(),policy=OSPermissionPolicy(allowed:[.camera],targets:[fixture.target])
        try expect(!OSPermissionPolicy().permits(request));try expect(policy.permits(request))
        var changed=request;changed.requester?.pid+=1;changed.requester?.started="new app run"
        try expect(policy.permits(changed),"Explicit app policy survives an app restart with the same signed identity")
        let other=OSPermissionTarget(name:fixture.target.name,bundleID:fixture.target.bundleID,path:"/elsewhere/Permission QA.app",requirement:fixture.target.requirement,pid:100991,started:"new")
        changed.requester=other;try expect(!policy.permits(changed),"A matching name cannot substitute another app path")
        changed=fixture.request("microphone",kind:.microphone);try expect(!policy.permits(changed))
        try expectEqual(OSPermissionPrompt.headline("\"Permission QA\" would like to access the camera.")?.kind,.camera)
        try expectEqual(OSPermissionPrompt.headline("“Permission QA”이(가) 다른 앱을 제어하려고 합니다.")?.kind,.automation)
        try expectEqual(OSPermissionPrompt.headline("\"Permission QA\" would like to access your contacts.")?.kind,.other)
        try expectNil(OSPermissionPrompt.headline("Build succeeded. Allow is in old output."))
        // A usage description cannot replace a different OS requester or resource headline.
        try expectNil(OSPermissionPrompt.headline("\"Untrusted App\" would like to access the camera.\n\"Permission QA\" would like to access the camera."))
        try expectNil(OSPermissionPrompt.headline("\"Permission QA\" would like to access the camera.\n\"Permission QA\" would like to access the microphone."))
        for kind in OSPermissionKind.automaticCases {try expect(!kind.title.isEmpty)}
        try expect(!OSPermissionKind.automaticCases.contains(.authentication))
    }
    func testOSPermissionDefaultsAndSessionIsolation() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-os-policy-"+UUID().uuidString),fixture=OSFixture();defer{try? FileManager.default.removeItem(at:root)}
        let (engine,ids)=try await osEngine(fixture,root:root);defer{engine.stop()};let request=fixture.request();fixture.set([request])
        await engine.refreshOSPermissions();try expectEqual(fixture.presses,[])
        try engine.setOSPermissionPolicy(ids[0],allowed:[.camera]);await engine.refreshOSPermissions();try expectEqual(fixture.presses,[],"Permission kind alone grants no app access")
        try engine.assignOSPermission(ids[0],requestID:request.id,token:request.immutableToken,remember:true)
        await engine.refreshOSPermissions();try expectEqual(fixture.presses,[request.id])
        await engine.refreshOSPermissions();try expectEqual(fixture.presses,[request.id],"A still-visible dialog is never pressed twice")
        try expectEqual(engine.snapshot.sessions.first(where:{$0.id==ids[1]})?.osPermissionPolicy,nil)
        let next=fixture.request("second");fixture.set([next]);await engine.refreshOSPermissions()
        try expectEqual(fixture.presses,[request.id,next.id]);try expectEqual(engine.snapshot.osPermissions?.requests.first(where:{$0.id==next.id})?.sessionID,ids[0])
        let other=fixture.request("not-permitted",kind:.microphone);fixture.set([other]);await engine.refreshOSPermissions();try expectEqual(fixture.presses.count,2)
        do {try engine.assignOSPermission(ids[1],requestID:other.id,token:other.immutableToken,remember:true);throw AppError.message("Other session stole a registered app")} catch let error as RemoteHTTPError {try expectEqual(error.status,409)}
    }
    func testOSPermissionLaunchedDiskRequestsStayWithOriginalSession() async throws {
        let fixture=OSFixture(),root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let (engine,ids)=try await osEngine(fixture,root:root)
        defer {engine.stop()}
        let owners=ids.map {id in engine.snapshot.sessions.first {$0.id==id}!}
        for owner in owners {try engine.setOSPermissionPolicy(owner.id,allowed:[.files])}
        fixture.launcher=owners[0].pid
        let first=fixture.request("folder",kind:.files)
        fixture.set([first]);await engine.refreshOSPermissions()
        try expectEqual(engine.snapshot.osPermissions?.requests.first?.sessionID,owners[0].id)
        try expectEqual(engine.snapshot.osPermissions?.requests.first?.needsAppConfirmation,true)
        try expectEqual(fixture.presses,[])
        try engine.assignOSPermission(owners[0].id,requestID:first.id,token:first.immutableToken,remember:true)
        await engine.refreshOSPermissions();try expectEqual(fixture.presses,[first.id])
        let next=fixture.request("other-session",kind:.files)
        fixture.launcher=owners[1].pid;fixture.set([next]);await engine.refreshOSPermissions()
        let observed=engine.snapshot.osPermissions?.requests.first {$0.id==next.id}
        try expectEqual(observed?.sessionID,owners[1].id);try expectEqual(observed?.needsAppConfirmation,true)
        try expectEqual(fixture.presses,[first.id])
        try engine.assignOSPermission(owners[1].id,requestID:next.id,token:next.immutableToken,remember:true)
        await engine.refreshOSPermissions();try expectEqual(fixture.presses,[first.id,next.id])
        let disk=fixture.request("full-disk",kind:.fullDiskAccess);fixture.set([disk])
        await engine.refreshOSPermissions();try expectEqual(fixture.presses,[first.id,next.id])
        let race=fixture.request("reparented",kind:.files);fixture.set([race])
        fixture.beforeApproval={fixture.launcher=nil}
        await engine.refreshOSPermissions();try expectEqual(fixture.presses,[first.id,next.id])
        let detached=fixture.request("detached",kind:.files);fixture.set([detached])
        await engine.refreshOSPermissions()
        try expectNil(engine.snapshot.osPermissions?.requests.first {$0.id==detached.id}?.sessionID)
        try expectEqual(fixture.presses,[first.id,next.id])
    }
    func testGroupPolicyEditsRespectSubmissionOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), fixture = OSFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ObservationReadGate(blocking: 1)
        let (engine, _) = try await osEngine(fixture, root: root, readCodex: { _ in _ = try gate.enter([]); return nil })
        defer { gate.release(0); engine.stop() }
        let live = ProcessDiscovery.sessions(fixture.records).map { original -> AgentSession in
            var session = original
            session.cwd = "/fixture/project"
            session.terminal = .terminal
            return session
        }
        engine.updateDiscovery(live, records: fixture.records, directories: Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0.cwd) }))
        let members = live.map { session -> SessionGroupMember in
            var member = SessionGroupMember(agent: session.agent, title: session.agent.title, cwd: session.cwd, conversationID: "")
            member.runtimeID = session.id
            return member
        }
        let group = SessionGroup(name: "Concurrent policies", members: members)
        try SessionGroupStore(directory: root).save([group])
        let older = Task { try await engine.applyGroupOSPermissions(group, kinds: [.files, .camera], allow: true) }
        try await gate.waitForReads(1)
        let latest = try await engine.applyGroupOSPermissions(group, kinds: [.camera], allow: false)
        try expect(latest.allSatisfy { $0.outcome == .alreadySet })
        try engine.setOSPermissionPolicy(live[0].id, allowed: [.microphone])
        gate.release(0)
        let rows = try await older.value
        try expectEqual(rows.map(\.outcome), [.skipped, .changed])
        func allowed(_ id: String) -> [OSPermissionKind]? {
            engine.snapshot.sessions.first { $0.id == id }?.osPermissionPolicy?.allowed
        }
        try expectEqual(allowed(live[0].id), [.microphone])
        try expectEqual(allowed(live[1].id), [.files])
    }

    func testGroupPolicyHasPriorityDuringDiscovery() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), fixture=OSFixture()
        defer {try? FileManager.default.removeItem(at:root)}
        let release=DispatchSemaphore(value:0), started=DispatchSemaphore(value:0)
        let (engine,_)=try await osEngine(fixture,root:root,readCodex:{ _ in
            started.signal()
            guard release.wait(timeout:.now()+5) == .success else {throw AppError.message("Discovery gate timed out")}
            return nil
        })
        defer {release.signal();engine.stop()}
        let live=fixture.records.map { AgentSession(id:$0.key,agent:$0.agent!,pid:$0.pid,started:$0.started,tty:"/dev/"+$0.tty,cwd:"/fixture/project",terminal:.terminal) }
        engine.updateDiscovery(live,records:fixture.records,directories:Dictionary(uniqueKeysWithValues:live.map {($0.id,$0.cwd)}))
        let session=live.first {$0.agent == .codex}!
        var member=SessionGroupMember(agent:session.agent,title:"Codex",cwd:session.cwd,conversationID:"")
        member.runtimeID=session.id
        let group=SessionGroup(name:"Priority",members:[member])
        try SessionGroupStore(directory:root).save([group])
        let request=fixture.request("group-priority",kind:.files)
        fixture.set([request]);await engine.refreshOSPermissions()
        try engine.assignOSPermission(session.id,requestID:request.id,token:request.immutableToken,remember:true)
        try engine.setOSPermissionPolicy(session.id,allowed:[.files])
        let edit=Task {try await engine.applyGroupOSPermissions(group,kinds:[.files],allow:false)}
        try await osUntil {started.wait(timeout:.now()) == .success}
        await engine.refreshOSPermissions()
        try expectEqual(fixture.presses,[])
        try expectEqual(engine.snapshot.osPermissions?.requests.first?.phase,.waiting)
        release.signal()
        let rows=try await edit.value
        try expectEqual(rows.map(\.outcome),[.changed])
        await engine.refreshOSPermissions();try expectEqual(fixture.presses,[])
        try engine.setOSPermissionPolicy(session.id,allowed:[.files])
        await engine.refreshOSPermissions();try expectEqual(fixture.presses,[request.id])
    }

    func testPolicyRevocationDuringAutomaticPreparationKeepsRequestPending() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), fixture=OSFixture()
        defer {try? FileManager.default.removeItem(at:root)}
        let started=DispatchSemaphore(value:0), release=DispatchSemaphore(value:0)
        let (engine,ids)=try await osEngine(fixture,root:root,prepare:{request,_ in
            started.signal()
            guard release.wait(timeout:.now()+5) == .success else {throw AppError.message("Preparation gate timed out")}
            return {authorized in
                guard authorized() else {return .unavailable("Policy changed")}
                fixture.pressed(request.id);return .sent
            }
        })
        defer {release.signal();engine.stop()}
        let id=ids[0],request=fixture.request("in-flight")
        fixture.set([request]);await engine.refreshOSPermissions()
        try engine.assignOSPermission(id,requestID:request.id,token:request.immutableToken,remember:true)
        try engine.setOSPermissionPolicy(id,allowed:[.camera])
        let pending=Task {await engine.refreshOSPermissions()}
        try await osUntil {started.wait(timeout:.now()) == .success}
        try engine.setOSPermissionPolicy(id,allowed:[])
        try engine.setOSPermissionPolicy(id,allowed:[.camera])
        release.signal();await pending.value
        try expectEqual(fixture.presses,[])
        try expectEqual(engine.snapshot.osPermissions?.requests.first?.phase,.waiting)
        release.signal();await engine.refreshOSPermissions()
        try expectEqual(fixture.presses,[request.id])
    }

    func testGroupOSPermissionEditsOnlySelectedKindsAndMembers() async throws {
        let fixture = OSFixture(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (engine, _) = try await osEngine(fixture, root: root)
        defer { engine.stop() }
        let others = ProcessDiscovery.parse("""
        100903 1 ttys903 100903 100903 Wed Oct 28 22:03:00 2026 /fixture/agy
        100904 1 ttys904 100904 100904 Wed Oct 28 22:04:00 2026 /fixture/codex
        """)
        let records = fixture.records + others
        fixture.replace(records)
        let live = records.map { AgentSession(id: $0.key, agent: $0.agent!, pid: $0.pid, started: $0.started,
                                             tty: "/dev/" + $0.tty, cwd: "/fixture/project", terminal: .terminal) }
        engine.updateDiscovery(live, records: records, directories: Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0.cwd) }))
        var members = live.prefix(3).map { session in
            var member = SessionGroupMember(agent: session.agent, title: session.agent.title, cwd: session.cwd, conversationID: "")
            member.runtimeID = session.id
            return member
        }
        members.append(.init(agent: .codex, title: "Offline", cwd: "/fixture/project", conversationID: UUID().uuidString.lowercased()))
        let group = SessionGroup(name: "Permissions", members: members)
        let store = SessionGroupStore(directory: root)
        try store.save([group])
        try engine.setOSPermissionPolicy(live[0].id, allowed: [.camera])
        try engine.setOSPermissionPolicy(live[1].id, allowed: [.files])
        let request = fixture.request()
        fixture.set([request]); await engine.refreshOSPermissions()
        try engine.assignOSPermission(live[0].id, requestID: request.id, token: request.immutableToken, remember: true)
        func policy(_ i: Int) -> OSPermissionPolicy? { engine.snapshot.sessions.first { $0.id == live[i].id }?.osPermissionPolicy }
        let first = try await engine.applyGroupOSPermissions(group, kinds: [.files], allow: true)
        try expectEqual(first.map(\.outcome), [.changed, .alreadySet, .changed, .skipped])
        try expectEqual(Set(policy(0)!.allowed), [.files, .camera]); try expectEqual(policy(0)?.targets, [fixture.target])
        try expectNil(policy(3)); try expectEqual(engine.snapshot.sessions.first { $0.id == live[2].id }?.automatic, false)
        let revision = policy(0)?.revision
        let retry = try await engine.applyGroupOSPermissions(group, kinds: [.files], allow: true)
        try expectEqual(retry.map(\.outcome), [.alreadySet, .alreadySet, .alreadySet, .skipped]); try expectEqual(policy(0)?.revision, revision)
        let revoke = try await engine.applyGroupOSPermissions(group, kinds: [.files], allow: false)
        try expectEqual(revoke.map(\.outcome), [.changed, .changed, .changed, .skipped])
        try expectEqual(policy(0)?.allowed, [.camera]); try expectEqual(policy(0)?.targets, [fixture.target])
        do {
            _ = try await engine.applyGroupOSPermissions(group, kinds: [.authentication], allow: true)
            try expect(false, "Authentication must be rejected")
        } catch let error as AppError { try expect(error.localizedDescription.contains("선택")) }
        var updated = group; updated.members.removeFirst()
        try store.save([updated], expected: [group])
        do {
            _ = try await engine.applyGroupOSPermissions(group, kinds: [.files], allow: true)
            try expect(false, "Stale membership must be rejected")
        } catch let error as AppError { try expect(error.localizedDescription.contains("그룹 구성")) }
        try expectEqual(policy(0)?.allowed, [.camera])
    }
    func testOSPermissionSharedControllersAreOneRequestOnly() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-os-shared-"+UUID().uuidString),fixture=OSFixture();defer{try? FileManager.default.removeItem(at:root)}
        fixture.target=OSPermissionTarget(name:"Terminal",bundleID:"com.apple.Terminal",path:"/System/Applications/Utilities/Terminal.app",requirement:"anchor apple and identifier com.apple.Terminal",pid:800,started:"same host")
        let (engine,ids)=try await osEngine(fixture,root:root);defer{engine.stop()};try engine.setOSPermissionPolicy(ids[0],allowed:[.camera])
        let request=fixture.request();fixture.set([request]);await engine.refreshOSPermissions()
        do {try engine.assignOSPermission(ids[0],requestID:request.id,token:request.immutableToken,remember:true);throw AppError.message("Shared host was enrolled permanently")} catch let error as RemoteHTTPError {try expectEqual(error.status,409)}
        try engine.assignOSPermission(ids[0],requestID:request.id,token:request.immutableToken,remember:false);await engine.refreshOSPermissions();try expectEqual(fixture.presses,[request.id])
        fixture.set([fixture.request("different-tab")]);await engine.refreshOSPermissions();try expectEqual(fixture.presses,[request.id])
    }
    func testOSPermissionManagerSetupIsManualAndIndependent() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-os-host-"+UUID().uuidString),fixture=OSFixture();defer{try? FileManager.default.removeItem(at:root)}
        let (engine,ids)=try await osEngine(fixture,root:root);defer{engine.stop()};let id=ids[0]
        let host=OSPermissionTarget(name:"AutoApprove",bundleID:"local.autoapprove.mac",path:"/fixture/AutoApprove.app",requirement:"Synthetic host identity",pid:ProcessInfo.processInfo.processIdentifier,started:"same host")
        let request=fixture.request("host-setup",kind:.localNetwork,target:host)
        fixture.set([request]);await engine.refreshOSPermissions();try engine.setOSPermissionPolicy(id,allowed:[.localNetwork,.camera])
        for remember in [false,true] {
            do {try engine.assignOSPermission(id,requestID:request.id,token:request.immutableToken,remember:remember);throw AppError.message("Manager setup was attached to a CLI")} catch let error as RemoteHTTPError {try expectEqual(error.status,409)}
        }
        try expect(!OSPermissionPolicy(allowed:[.localNetwork],targets:[host]).permits(request))
        try expectEqual(OSPermissionAutomation().approve(request,authorized:{true}),.unavailable("AutoApprove 자체의 권한은 Mac에서 직접 설정해주세요."))
        let observed=engine.snapshot.osPermissions?.requests.first
        try expectEqual(observed?.managementApp,true);try expectNil(observed?.sessionID);try expectEqual(fixture.presses,[])
        let raw="• Working (12s • esc to interrupt)\n› Ask Codex to do anything"
        engine.receiveScreen(sessionID:id,raw:raw,generation:"host-setup")
        try expect(engine.snapshot.sessions.first(where:{$0.id==id})?.codexProgressRecovery != nil,"Manager setup must not suppress the CLI progress clock")
        // A manual host request must not suppress another session's explicitly scoped permission.
        var manual=request;manual.action = .manual
        let app=fixture.request("separate-app");fixture.set([manual,app]);await engine.refreshOSPermissions()
        try engine.assignOSPermission(id,requestID:app.id,token:app.immutableToken,remember:true)
        await engine.refreshOSPermissions();try expectEqual(fixture.presses,[app.id])
    }
    func testOSPermissionPauseOffRevocationAndProcessChange() async throws {
        for mode in ["pause","automatic-off","policy-off","remove-app","process-exit","stop","typing"] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-os-race-"+UUID().uuidString),fixture=OSFixture();defer{fixture.release();try? FileManager.default.removeItem(at:root)}
            let (engine,ids)=try await osEngine(fixture,root:root);defer{engine.stop()};let id=ids[0],request=fixture.request()
            fixture.set([request]);await engine.refreshOSPermissions();try engine.setOSPermissionPolicy(id,allowed:[.camera]);try engine.assignOSPermission(id,requestID:request.id,token:request.immutableToken,remember:true)
            fixture.hold();let count=fixture.reads;let task=Task {await engine.refreshOSPermissions()};try await osUntil {fixture.reads>count}
            switch mode {
            case "pause":try engine.setPaused(true)
            case "automatic-off":try engine.setAutomatic(id,enabled:false)
            case "policy-off":try engine.setOSPermissionPolicy(id,allowed:[])
            case "remove-app":try engine.removeOSPermissionTarget(id,targetID:fixture.target.id)
            case "process-exit":fixture.exited()
            case "stop":engine.stop()
            default:fixture.typeNow()
            }
            fixture.release();await task.value;try expectEqual(fixture.presses,[],mode+" prevents an OS press")
        }
    }
    func testOSPermissionReceiptsSurviveRestartAndUncertainInput() async throws {
        for outcome in [OSPermissionDelivery.sent,.uncertain("Synthetic timeout")] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-os-receipt-"+UUID().uuidString),fixture=OSFixture();defer{try? FileManager.default.removeItem(at:root)}
            fixture.result=outcome;let (engine,ids)=try await osEngine(fixture,root:root);let request=fixture.request();fixture.set([request])
            await engine.refreshOSPermissions();try engine.setOSPermissionPolicy(ids[0],allowed:[.camera]);try engine.assignOSPermission(ids[0],requestID:request.id,token:request.immutableToken,remember:true)
            await engine.refreshOSPermissions();engine.stop();try expectEqual(fixture.presses,[request.id])
            let (reopened,newIDs)=try await osEngine(fixture,root:root);defer{reopened.stop()};try expectEqual(ids,newIDs)
            await reopened.refreshOSPermissions();await reopened.refreshOSPermissions();try expectEqual(fixture.presses,[request.id])
            try expectEqual(reopened.snapshot.osPermissions?.requests.first?.phase,.uncertain)
        }
    }
    func testOSPermissionSettingsTransitionAndManualAuthentication() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-os-settings-"+UUID().uuidString),fixture=OSFixture();defer{try? FileManager.default.removeItem(at:root)}
        let (engine,ids)=try await osEngine(fixture,root:root);defer{engine.stop()};let id=ids[0],open=fixture.request("settings",kind:.accessibility,action:.openSettings)
        fixture.set([open]);await engine.refreshOSPermissions();try engine.setOSPermissionPolicy(id,allowed:[.accessibility]);try engine.assignOSPermission(id,requestID:open.id,token:open.immutableToken,remember:true)
        await engine.refreshOSPermissions();try expectEqual(fixture.presses,[open.id])
        let toggle=fixture.request("app-toggle",kind:.accessibility,action:.enableSetting);fixture.set([toggle]);await engine.refreshOSPermissions();try expectEqual(fixture.presses,[open.id,toggle.id])
        try expectEqual(engine.snapshot.osPermissions?.requests.first(where:{$0.id==open.id})?.phase,.resolved)
        let auth=fixture.request("auth",kind:.authentication,action:.manual);fixture.set([auth]);await engine.refreshOSPermissions();try engine.assignOSPermission(id,requestID:auth.id,token:auth.immutableToken,remember:false)
        do {try engine.setOSPermissionPolicy(id,allowed:[.authentication]);throw AppError.message("Authentication became automatic")} catch let error as RemoteHTTPError {try expectEqual(error.status,400)}
        await engine.refreshOSPermissions();try expectEqual(fixture.presses.count,2);try expectEqual(engine.snapshot.sessions.first(where:{$0.id==id})?.osPermissionWaiting,true)
    }
    func testOSPermissionWaitingStopsProgressInterruptAndTerminalApproval() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-os-progress-"+UUID().uuidString),fixture=OSFixture();defer{try? FileManager.default.removeItem(at:root)}
        let (engine,ids)=try await osEngine(fixture,root:root);defer{engine.stop()};let id=ids[0];await engine.connectTerminal()
        engine.codexProgressTimeout=0.01;fixture.set([fixture.request()]);await engine.refreshOSPermissions()
        let raw="• Working (12s • esc to interrupt)\n› Ask Codex to do anything"
        engine.receiveScreen(sessionID:id,raw:raw,generation:"os-progress")
        try await Task.sleep(for:.milliseconds(30));engine.receiveScreen(sessionID:id,raw:raw,generation:"os-progress")
        do {try engine.requestCodexProgressCheck(id);throw AppError.message("OS wait was interrupted")} catch is RemoteHTTPError {}
        engine.receiveScreen(sessionID:id,raw:"Would you like to run the following command?\n$ echo fixture\n› 1. Yes, proceed (y)\n  2. No, and tell Codex what to do differently (esc)\nPress enter to confirm or esc to cancel",generation:"os-progress")
        try await Task.sleep(for:.milliseconds(250));try expectEqual(fixture.presses,[])
        fixture.set([]);await engine.refreshOSPermissions();engine.receiveScreen(sessionID:id,raw:raw,generation:"os-progress")
        try expectEqual(engine.snapshot.sessions.first(where:{$0.id==id})?.osPermissionWaiting,false)
        try expect(engine.snapshot.sessions.first(where:{$0.id==id})?.codexProgressRecovery?.lastProgressAt.timeIntervalSinceNow ?? -100 > -1,"The progress clock starts again after permission waiting")
    }
    func testOSPermissionLastMomentRevocationAndReusedSessionIdentity() async throws {
        for mode in ["policy-off","remove-app","new-cli-run"] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-os-final-gate-"+UUID().uuidString),fixture=OSFixture();defer{try? FileManager.default.removeItem(at:root)}
            let (engine,ids)=try await osEngine(fixture,root:root);defer{engine.stop()};let id=ids[0],request=fixture.request()
            fixture.set([request]);await engine.refreshOSPermissions();try engine.setOSPermissionPolicy(id,allowed:[.camera]);try engine.assignOSPermission(id,requestID:request.id,token:request.immutableToken,remember:true)
            if mode=="policy-off" {fixture.beforeApproval={try? engine.setOSPermissionPolicy(id,allowed:[])}}
            else if mode=="remove-app" {fixture.beforeApproval={try? engine.removeOSPermissionTarget(id,targetID:fixture.target.id)}}
            else {
                let records=ProcessDiscovery.parse("100903 1 ttys903 100903 100903 Wed Oct 28 23:00:00 2026 /fixture/codex")
                fixture.replace(records);var next=ProcessDiscovery.sessions(records)[0];next.id=id;next.terminal = .terminal
                engine.updateDiscovery([next],records:records)
            }
            await engine.refreshOSPermissions();try expectEqual(fixture.presses,[],mode+" cannot reach the OS button")
            if mode=="new-cli-run" {
                try engine.setOSPermissionPolicy(id,allowed:[.camera]);try expectEqual(engine.snapshot.sessions.first(where:{$0.id==id})?.osPermissionPolicy?.targets,[])
                await engine.refreshOSPermissions();try expectEqual(fixture.presses,[],"A reused session ID needs fresh app enrollment")
            }
        }
    }
    func testOSPermissionOneShotSettingsAndPolicyWithdrawal() async throws {
        for revoked in [false,true] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-os-one-setting-"+UUID().uuidString),fixture=OSFixture();defer{try? FileManager.default.removeItem(at:root)}
            fixture.target=OSPermissionTarget(name:"Terminal",bundleID:"com.apple.Terminal",path:"/System/Applications/Utilities/Terminal.app",requirement:"anchor apple",pid:800,started:"host start")
            let (engine,ids)=try await osEngine(fixture,root:root);defer{engine.stop()};let id=ids[0],open=fixture.request("open",kind:.accessibility,action:.openSettings)
            fixture.set([open]);await engine.refreshOSPermissions();try engine.setOSPermissionPolicy(id,allowed:[.accessibility]);try engine.assignOSPermission(id,requestID:open.id,token:open.immutableToken,remember:false)
            await engine.refreshOSPermissions();try expectEqual(fixture.presses,[open.id])
            if revoked {try engine.setOSPermissionPolicy(id,allowed:[])}
            let toggle=fixture.request("toggle",kind:.accessibility,action:.enableSetting);fixture.set([toggle]);await engine.refreshOSPermissions()
            try expectEqual(fixture.presses.count,revoked ? 1:2)
            if revoked {try engine.setOSPermissionPolicy(id,allowed:[.accessibility]);await engine.refreshOSPermissions();try expectEqual(fixture.presses,[open.id],"Re-enabling a policy cannot resurrect a withdrawn settings transition")}
        }
    }
}
