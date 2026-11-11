#if DEBUG
import Foundation
@testable import AutoApproveCore

extension ApprovalTests {
    func testNativeSelectedRetirementRejectsChangedRequestScopeAndRevision()throws {
        let requestID=UUID().uuidString.lowercased(),id=UUID().uuidString.lowercased(),home="16777234:12345"
        func check(_ changes:[String:Any]=[:],phase:String="retired")throws {
            var value:[String:Any]=["requestId":requestID,"threadIds":[id],"phase":"retired","ownershipRevision":7,
                "homeIdentity":home,"writersStopped":true,"membershipComplete":false,"migrationAuthorized":false]
            value.merge(changes,uniquingKeysWith:{$1})
            let receipt=try JSONDecoder().decode(CodexNativeRetirementReceipt.self,from:JSONSerialization.data(withJSONObject:value))
            try receipt.validate(requestID:requestID,threadIDs:[id],phase:phase,revision:7,homeIdentity:home)
        }
        try check()
        try check(["phase":"writers-held","homeIdentity":NSNull()],phase:"writers-held")
        for changes in [["requestId":UUID().uuidString.lowercased()],["threadIds":[]],["threadIds":[id,id]],
                        ["ownershipRevision":6],["homeIdentity":"16777234:12346"],["writersStopped":false],
                        ["membershipComplete":true],["migrationAuthorized":true],["phase":"active"]] as [[String:Any]] {
            try expectThrows(check(changes))
        }
    }
    func testNativeSelectedOwnershipObservationRequiresCompleteRequestedRows()throws {
        let id=UUID().uuidString.lowercased(),requestID=UUID().uuidString.lowercased()
        let row:[String:Any]=["threadId":id,"requestId":requestID,"ownerHomeIdentity":"16777234:54321","phase":"retired"]
        func check(_ changes:[String:Any]=[:],row changedRow:[String:Any]?=nil)throws {
            var value:[String:Any]=["homeIdentity":"16777234:12345","ownershipRevision":1,"threads":[changedRow ?? row],
                "observationOnly":true,"migrationAuthorized":false]
            value.merge(changes,uniquingKeysWith:{$1})
            let snapshot=try JSONDecoder().decode(CodexNativeOwnershipObservation.self,from:JSONSerialization.data(withJSONObject:value))
            try snapshot.validate(threadIDs:[id])
        }
        try check()
        try check(["ownershipRevision":0],row:["threadId":id])
        for changes in [["threads":[]],["threads":[row,row]],["ownershipRevision":0],["homeIdentity":"bad"],
                        ["observationOnly":false],["migrationAuthorized":true]] as [[String:Any]] {
            try expectThrows(check(changes))
        }
        for changes in [["threadId":UUID().uuidString.lowercased()],["requestId":"bad"],
                        ["ownerHomeIdentity":"16777234:12345"],["phase":"active"],["phase":"ready"]] as [[String:Any]] {
            var bad=row;bad.merge(changes,uniquingKeysWith:{$1});try expectThrows(check(row:bad))
        }
        var active=row;active["phase"]="active";active["ownerHomeIdentity"]="16777234:12345";try check(row:active)
    }
    func testNativeSelectedShutdownRejectsOwnershipClaimsAndInconsistentResults()throws {
        let id=UUID().uuidString.lowercased()
        func check(_ changes:[String:Any]=[:],requestID:String?=nil)throws {
            var value:[String:Any]=["requestId":id,"state":"stopped","runtimesStopped":true,
                "writersStopped":false,"observationOnly":true,"migrationAuthorized":false,"error":NSNull()]
            value.merge(changes,uniquingKeysWith:{$1})
            let observation=try JSONDecoder().decode(CodexNativeSelectedShutdown.self,from:JSONSerialization.data(withJSONObject:value))
            try observation.validate(requestID:requestID ?? id)
        }
        try check()
        try check(["state":"pending","runtimesStopped":false])
        try check(["state":"failed","runtimesStopped":false,"error":"Shutdown not confirmed"])
        for changes in [["writersStopped":true],["migrationAuthorized":true],["observationOnly":false],
                        ["state":"pending"],["state":"failed"],["state":"complete"],
                        ["state":"failed","runtimesStopped":false,"error":""],
                        ["error":"Unexpected stopped error"],["requestId":UUID().uuidString.lowercased()]] as [[String:Any]] {
            try expectThrows(check(changes))
        }
    }

    func testNativeSelectedCohortRejectsIncompleteOrForgedReadiness()throws {
        let id=UUID().uuidString.lowercased(),other=UUID().uuidString.lowercased()
        let nonce=String(repeating:"a",count:32),generation=UUID().uuidString.lowercased(),lease=UUID().uuidString.lowercased()
        let peer=CodexNativePeerIdentity(source:"macos-audit-token",pid:123,effectiveUid:501,effectiveGid:20,auditPidVersion:7)
        let row:[String:Any]=["threadId":id,"status":"pending-init","loaded":true,"persistent":true,
            "hasActiveTurn":false,"hasBackgroundTerminal":false,"hasProtectedRequest":false,"hasQueuedInput":false,
            "goal":NSNull(),"goalId":NSNull(),"readyForWriterShutdown":true]
        let cohort:[String:Any]=["schemaVersion":1,"producer":"autoapprove-selected-runtime-cohort","threads":[row],
            "missingThreadIds":[],"knownSubtreeCovered":true,"readyForWriterShutdown":true,"inputScopeVerified":true,
            "membershipComplete":false,"writersStopped":false,"migrationAuthorized":false]
        func check(_ snapshot:[String:Any])throws {
            let value:[String:Any]=["schemaVersion":1,"producer":"autoapprove-selected-input-lease","pid":peer.pid,
                "nonce":nonce,"serverGeneration":generation,"scope":"selected-thread-input","threadIds":[id],"leaseId":lease,
                "inputAdmissionPaused":true,"leaseTTLMillis":29_000,"membershipComplete":false,"existingWorkStopped":false,
                "goalLifecycleManaged":false,"credentialsTouched":false,"migrationAuthorized":false,"runtimeCohort":snapshot]
            _ = try CodexNativeSelectedInputLease.validate(JSONSerialization.data(withJSONObject:value),operation:.cohort,
                nonce:nonce,peer:peer,generation:generation,leaseID:lease,threadIDs:[id])
        }
        try check(cohort)
        for (field,value) in [("membershipComplete",true),("writersStopped",true),("migrationAuthorized",true),
                              ("inputScopeVerified",false),("missingThreadIds",[other]),("threads",[])] as [(String,Any)] {
            var bad=cohort;bad[field]=value;try expectThrows(check(bad))
        }
        for field in ["hasActiveTurn","hasBackgroundTerminal","hasProtectedRequest","hasQueuedInput"] {
            var badRow=row;badRow[field]=true
            var bad=cohort;bad["threads"]=[badRow];try expectThrows(check(bad))
        }
        var changed=row;changed["threadId"]=other
        var bad=cohort;bad["threads"]=[changed];try expectThrows(check(bad))
        var active=row
        active["goal"]=["threadId":id,"objective":"Existing Goal","status":"active","createdAt":1,"updatedAt":2,
                        "tokensUsed":37,"timeUsedSeconds":4,"tokenBudget":1234]
        active["goalId"]=UUID().uuidString.lowercased()
        bad["threads"]=[active];try expectThrows(check(bad))
        active["readyForWriterShutdown"]=false;bad["threads"]=[active];bad["readyForWriterShutdown"]=false
        try check(bad) // A valid blocked observation is not a protocol failure.
        var missing=cohort;missing["missingThreadIds"]=[other];missing["knownSubtreeCovered"]=false;missing["readyForWriterShutdown"]=false
        try check(missing)
    }

    func testNativeSelectedInputLeaseRejectsChangedScopeAndAuthorityClaims()throws {
        let nonce=String(repeating:"a",count:32),generation=UUID().uuidString.lowercased(),lease=UUID().uuidString.lowercased()
        let ids=["a0000000-0000-4000-8000-000000000001","a0000000-0000-4000-8000-000000000002"]
        let peer=CodexNativePeerIdentity(source:"macos-audit-token",pid:123,effectiveUid:501,effectiveGid:20,auditPidVersion:7)
        func reply(_ operation:CodexNativeSelectedInputLease.Operation)->[String:Any] {
            let paused=operation != .inspect && operation != .release
            return ["schemaVersion":1,"producer":"autoapprove-selected-input-lease","pid":peer.pid,
                    "nonce":nonce,"serverGeneration":generation,"scope":"selected-thread-input",
                    "threadIds":operation == .inspect ? []:ids,"leaseId":operation == .inspect ? NSNull():lease as Any,
                    "inputAdmissionPaused":paused,"leaseTTLMillis":paused ? 29_000:0,
                    "membershipComplete":false,"existingWorkStopped":false,"goalLifecycleManaged":false,
                    "credentialsTouched":false,"migrationAuthorized":false]
        }
        func check(_ value:[String:Any],_ operation:CodexNativeSelectedInputLease.Operation)throws {
            _ = try CodexNativeSelectedInputLease.validate(JSONSerialization.data(withJSONObject:value),operation:operation,
                nonce:nonce,peer:peer,generation:operation == .inspect ? nil:generation,
                leaseID:operation == .inspect || operation == .pause ? nil:lease,threadIDs:ids)
        }
        for operation in [CodexNativeSelectedInputLease.Operation.inspect,.pause,.status,.renew,.release] {try check(reply(operation),operation)}
        for (field,value) in [("pid",999),("schemaVersion",2),("producer","other"),("scope","all-threads"),
                              ("nonce",String(repeating:"b",count:32)),("serverGeneration",UUID().uuidString.lowercased()),
                              ("leaseId",UUID().uuidString.lowercased()),("threadIds",[ids[0]]),("threadIds",[ids[0],ids[0]]),
                              ("threadIds",Array(ids.reversed())),("inputAdmissionPaused",false),("leaseTTLMillis",30_001),
                              ("leaseTTLMillis",0),("membershipComplete",true),("existingWorkStopped",true),
                              ("goalLifecycleManaged",true),("credentialsTouched",true),("migrationAuthorized",true),
                              ("inputAdmissionPaused",1),("leaseTTLMillis",true)] as [(String,Any)] {
            var bad=reply(.status);bad[field]=value;try expectThrows(check(bad,.status))
        }
        try expectThrows(check(reply(.status),.release))
        var leaked=reply(.inspect);leaked["threadIds"]=ids;try expectThrows(check(leaked,.inspect))
        try expectEqual(try CodexNativeSelectedInputLease.checkedScope(Array(ids.reversed())),ids)
        for scope in [[],[ids[0],ids[0]],[ids[0].uppercased()],["bad"],Array(repeating:ids[0],count:513)] as [[String]] {
            try expectThrows(CodexNativeSelectedInputLease.checkedScope(scope))
        }
    }
}
#endif
