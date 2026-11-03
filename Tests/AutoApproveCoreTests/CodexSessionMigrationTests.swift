#if DEBUG
import Foundation
import Darwin
@testable import AutoApproveCore

@MainActor private final class SessionMigrationFixture {
    let root=URL(fileURLWithPath:"/private/tmp/aa-session-migration-"+UUID().uuidString)
    let a="00000000-0000-4000-8000-000000000001",b="00000000-0000-4000-8000-000000000002"
    let c="00000000-0000-4000-8000-000000000003",d="00000000-0000-4000-8000-000000000004"
    var scene:CodexSessionMigrationObservation!
    var reads=0
    var mutate:((Int)->Void)?
    init() throws {
        for name in ["a","b"] {try FileManager.default.createDirectory(at:root.appendingPathComponent(name),withIntermediateDirectories:true)}
        let source=try endpoint("a"),destination=try endpoint("b")
        let selected=CodexMigrationClient(identity:.init(pid:41,started:"owned-41",tty:"/dev/ttys971"),home:source.home,threadIDs:[a,b])
        let other=CodexMigrationClient(identity:.init(pid:42,started:"owned-42",tty:"/dev/ttys972"),home:source.home,threadIDs:[d])
        let existing=CodexMigrationClient(identity:.init(pid:43,started:"owned-43",tty:"/dev/ttys973"),home:destination.home,threadIDs:[c])
        scene = .init(source:source,destination:destination,clients:[selected,other,existing],threads:[
            .init(id:a,home:source.home,parentID:nil,turnID:"turn-a",goalRevision:"goal-instance-a:active:budget100",configurationID:"settings-a",resumable:true,active:true,goalStatus:.active),
            .init(id:b,home:source.home,parentID:a,turnID:"turn-b",goalRevision:nil,configurationID:"settings-b",resumable:true,active:true),
            .init(id:c,home:destination.home,parentID:nil,turnID:nil,goalRevision:nil,configurationID:"settings-c",resumable:true),
            .init(id:d,home:source.home,parentID:nil,turnID:nil,goalRevision:nil,configurationID:"settings-d",resumable:true)],completeClients:true,completeThreads:true)
    }
    deinit{try? FileManager.default.removeItem(at:root)}
    func endpoint(_ name:String)throws->CodexMigrationEndpoint {
        let home=root.appendingPathComponent(name).path;var info=stat();try expectEqual(lstat(home,&info),0)
        return .init(home:home,physicalHomeID:"\(info.st_dev):\(info.st_ino)",serverID:"daemon-"+name,socketID:"socket-"+name,
                     credentialStoreID:"file-backend-"+name,cliIdentity:"owned-cli-"+name,cliVersion:"0.166.0",
                     account:.init(subjectID:"user-"+name,sessionID:"login-"+name,workspaceID:"workspace-"+name))
    }
    var request:CodexSessionMigrationRequest {.init(id:UUID().uuidString.lowercased(),source:scene.source,destination:scene.destination,clients:[scene.clients[0]],threads:Array(scene.threads.prefix(2)))}
    var services:CodexSessionMigrationServices {.init(observe:{[unowned self] _ in self.reads+=1;self.mutate?(self.reads);return self.scene})}
    func journal(_ name:String="audit")throws->CodexMigrationJournal {try .init(store:AuditStore(path:root.appendingPathComponent(name+".sqlite").path))}
}
extension ApprovalTests {
    @MainActor func testSessionMigrationPreparesExactCohortWithoutChangingOwnership() async throws {
        let f=try SessionMigrationFixture(),journal=try f.journal(),c=CodexSessionMigrationCoordinator(journal:journal,services:f.services),request=f.request
        var reservedStage:String?
        f.mutate={read in if read==2,let loaded=try? journal.load(id:request.id) {
            reservedStage=(try? JSONDecoder().decode(CodexSessionMigrationState.self,from:loaded.record.payload))?.stage.rawValue
        }}
        let state=try await c.prepare(request)
        try expectEqual(state.stage,.prepared);try expectEqual(f.reads,2)
        try expectEqual(reservedStage,"reserved","Durable reservation must not claim fresh membership was already rechecked")
        try expectEqual(state.currentOwners,[f.a:f.scene.source.home,f.b:f.scene.source.home],"Preparation must never claim the destination already owns a conversation")
        try expect(try journal.load(id:state.request.id)!.consistent)
        try expectEqual(try journal.load(id:state.request.id)!.record.revision,2,"Fresh preparation must be durably distinguished from the initial reservation")
        try expectEqual(try c.state(id:state.request.id),state)
        try c.cancel(id:state.request.id)
        try expectEqual(try c.state(id:state.request.id)?.stage,.cancelled)
        try expect(try journal.activeRecords().isEmpty)
    }
    @MainActor func testSessionMigrationRejectsSharedWritersAndIncompleteChildren() async throws {
        for scenario in ["source-writer","destination-writer","missing-child","unowned-child","incomplete-clients","incomplete-threads","duplicate-client","duplicate-thread","missing-selected","cyclic-family"] {
            let f=try SessionMigrationFixture(),journal=try f.journal()
            var request=f.request
            switch scenario {
            case "source-writer":f.scene.clients[1].threadIDs.append(f.a)
            case "destination-writer":f.scene.clients[2].threadIDs.append(f.b)
            case "missing-child":f.scene.threads.removeAll{$0.id==f.b}
            case "unowned-child":f.scene.threads.append(.init(id:UUID().uuidString.lowercased(),home:f.scene.source.home,parentID:f.a,turnID:nil,goalRevision:nil,configurationID:"new-child",resumable:true))
            case "incomplete-clients":f.scene.completeClients=false
            case "duplicate-client":f.scene.clients.append(f.scene.clients[0])
            case "duplicate-thread":f.scene.threads.append(f.scene.threads[0])
            case "missing-selected":f.scene.clients.removeFirst()
            case "cyclic-family":f.scene.threads[0].parentID=f.b
            default:f.scene.completeThreads=false
            }
            if scenario=="cyclic-family" {request=f.request}
            let c=CodexSessionMigrationCoordinator(journal:journal,services:f.services)
            var rejected=false;do{_ = try await c.prepare(request)}catch{rejected=true}
            try expect(rejected,"Unsafe cohort must reject before reservation: "+scenario)
            try expect(try journal.activeRecords().isEmpty)
        }
    }
    @MainActor func testSessionMigrationRejectsDraftQuestionQueueAndIndependentWork() async throws {
        for scenario in ["draft","question","queue","background","configuration","resumability"] {
            let f=try SessionMigrationFixture(),journal=try f.journal()
            switch scenario {
            case "draft":f.scene.clients[0].hasDraft=true
            case "question":f.scene.clients[0].hasQuestion=true
            case "queue":f.scene.clients[0].hasQueuedInput=true
            case "background":f.scene.clients[0].hasIndependentWork=true
            case "configuration":f.scene.threads[0].configurationID=""
            default:f.scene.threads[0].resumable=false
            }
            let request=f.request,c=CodexSessionMigrationCoordinator(journal:journal,services:f.services)
            var rejected=false;do{_ = try await c.prepare(request)}catch{rejected=true}
            try expect(rejected,"User input and unpreservable configuration must remain untouched: "+scenario)
            try expect(try journal.activeRecords().isEmpty)
        }
    }
    @MainActor func testSessionMigrationRejectsChangedIdentityAndSharedBackends() async throws {
        for scenario in ["daemon","socket","credentials","account","signed-out","version","home-id","client-id","goal"] {
            let f=try SessionMigrationFixture(),journal=try f.journal()
            var request=f.request
            switch scenario {
            case "daemon":f.scene.destination.serverID=f.scene.source.serverID
            case "socket":f.scene.destination.socketID=f.scene.source.socketID
            case "credentials":f.scene.destination.credentialStoreID=f.scene.source.credentialStoreID
            case "account":f.scene.destination.account.workspaceID="different-workspace"
            case "signed-out":f.scene.destination.account.sessionID=""
            case "version":f.scene.destination.cliVersion="0.167.0"
            case "home-id":f.scene.source.physicalHomeID="replaced-home"
            case "client-id":f.scene.clients[0].identity.started="reused-pid"
            default:f.scene.threads[0].goalRevision="replacement-goal-instance"
            }
            // Also reject when the caller itself proposes these invalid
            // backends; a mere request/observation equality check is insufficient.
            if ["daemon","socket","credentials","signed-out","version","home-id"].contains(scenario) {request=f.request}
            let c=CodexSessionMigrationCoordinator(journal:journal,services:f.services)
            var rejected=false;do{_ = try await c.prepare(request)}catch{rejected=true}
            try expect(rejected,"Identity changed before reservation: "+scenario)
            try expect(try journal.activeRecords().isEmpty)
        }
    }
    @MainActor func testSessionMigrationRechecksAfterDurableReservationAndReleasesOnChange() async throws {
        for scenario in ["draft","membership","goal","account"] {
            let f=try SessionMigrationFixture(),journal=try f.journal(),request=f.request
            let original=f.scene!
            f.mutate={read in if read==2 {
                switch scenario {
                case "draft":f.scene.clients[0].hasDraft=true
                case "membership":f.scene.clients[0].threadIDs.append(f.d)
                case "goal":f.scene.threads[0].goalRevision="replacement-goal"
                default:f.scene.destination.account.sessionID="replacement-login"
                }
            }}
            let c=CodexSessionMigrationCoordinator(journal:journal,services:f.services)
            var rejected=false;do{_ = try await c.prepare(request)}catch{rejected=true}
            try expect(rejected);try expectEqual(f.reads,2)
            try expectEqual(try c.state(id:request.id)?.stage,.cancelled)
            try expect(try journal.activeRecords().isEmpty)
            f.mutate=nil;f.scene=original
            _ = try await c.prepare(f.request)
        }
    }
    @MainActor func testSessionMigrationRestorationRetainsBothHomeReservations() async throws {
        let f=try SessionMigrationFixture(),request=f.request
        var original:CodexSessionMigrationCoordinator?=CodexSessionMigrationCoordinator(journal:try f.journal(),services:f.services)
        _ = try await original!.prepare(request);original=nil
        let restored=CodexSessionMigrationCoordinator(journal:try f.journal(),services:f.services)
        try expectEqual(try restored.state(id:request.id)?.stage,.prepared)
        var reversed=f.scene!;swap(&reversed.source,&reversed.destination)
        let reverseRequest=CodexSessionMigrationRequest(id:UUID().uuidString.lowercased(),source:reversed.source,destination:reversed.destination,clients:[reversed.clients[2]],threads:[reversed.threads[2]])
        let other=CodexSessionMigrationCoordinator(journal:try f.journal("foreign"),services:.init(observe:{_ in reversed}))
        var rejected=false;do{_ = try await other.prepare(reverseRequest)}catch{rejected=true}
        try expect(rejected,"A reversed request must not steal either home after coordinator restart")
        try restored.cancel(id:request.id)
        _ = try await other.prepare(reverseRequest)
    }
    @MainActor func testSessionMigrationCancellationDuringReadReleasesOnlyUntouchedReservation() async throws {
        for pauseAt in [1,2] {
            let f=try SessionMigrationFixture(),journal=try f.journal(),request=f.request
            var reads=0,waiting:CheckedContinuation<Void,Never>?
            let c=CodexSessionMigrationCoordinator(journal:journal,services:.init(observe:{_ in
                reads+=1
                if reads==pauseAt {await withCheckedContinuation{waiting=$0}}
                return f.scene
            }))
            let pending=Task{try await c.prepare(request)}
            defer{waiting?.resume();pending.cancel()}
            let deadline=Date().addingTimeInterval(3)
            while waiting==nil,Date()<deadline {try await Task.sleep(for:.milliseconds(10))}
            try expectNotNil(waiting)
            var duplicateRejected=false;do{_ = try await c.prepare(f.request)}catch{duplicateRejected=true}
            try expect(duplicateRejected);try expectEqual(reads,pauseAt,"A duplicate request must not start another read or reserve a second scope")
            try c.cancel(id:request.id)
            try expect(try journal.activeRecords().isEmpty,"Cancellation before any native effect must release the reservation immediately")
            let replacementJournal=try f.journal("replacement")
            let replacement=CodexSessionMigrationCoordinator(journal:replacementJournal,services:f.services)
            let newRequest=f.request
            _ = try await replacement.prepare(newRequest)
            let resume=waiting;waiting=nil;resume?.resume()
            var cancelled=false;do{_ = try await pending.value}catch{cancelled=true}
            try expect(cancelled,"A late cancellation-ignoring read must never publish preparation success")
            if pauseAt==2 {try expectEqual(try c.state(id:request.id)?.stage,.cancelled)}
            else{try expectNil(try c.state(id:request.id))}
            try expectEqual(try replacement.state(id:newRequest.id)?.stage,.prepared,"A late old read must not cancel a newer reservation on the same two homes")
            try expectEqual(try replacementJournal.activeRecords().map(\.id),[newRequest.id])
        }
    }
}
#endif
