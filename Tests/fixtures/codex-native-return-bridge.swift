import Foundation
import CryptoKit
import Darwin
@testable import AutoApproveCore

// Owned fixture bridge to the Node parent's real stdio app-server connection.
// The parent serially owns that connection and constructed all its root threads.
// Settings evidence below is the actual resume acknowledgment, not a general
// readonly settings API or proof about arbitrary preexisting user clients.
enum NativeReturnBridge {
    private final class Lines {
        var buffer=Data(),sequence=0
        func read()throws->JSONObject {
            while true {
                if let end=buffer.firstIndex(of:10) {
                    let bytes=buffer[..<end];buffer.removeSubrange(...end)
                    guard let object=try JSONSerialization.jsonObject(with:Data(bytes)) as? JSONObject else{throw AppError.message("Owned bridge JSON required")}
                    return object
                }
                let data=FileHandle.standardInput.availableData
                guard !data.isEmpty,buffer.count+data.count<=8*1024*1024 else{throw AppError.message("Owned bridge closed or oversized")}
                buffer.append(data)
            }
        }
        func send(_ object:JSONObject)throws {
            var data=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes]);data.append(10)
            try FileHandle.standardOutput.write(contentsOf:data)
        }
        func rpc(_ method:String,_ params:JSONObject)throws->JSONObject {
            sequence+=1;try send(["type":"rpc","id":sequence,"method":method,"params":params])
            let response=try read()
            if response["id"] as? Int==sequence,response["ownedInjectedDrop"] as? Bool==true {_exit(52)}
            guard response["id"] as? Int==sequence,response["error"]==nil,let result=response["result"] as? JSONObject else{throw AppError.message("Owned native bridge request failed: "+method)}
            return result
        }
    }
    private static func digest(_ value:Any)throws->String {
        SHA256.hash(data:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes])).map{String(format:"%02x",$0)}.joined()
    }
    private static func settings(_ value:JSONObject)throws->String {
        let keys=["model","modelProvider","cwd","approvalPolicy","approvalsReviewer","sandbox","serviceTier","reasoningEffort","disabledPluginIds","runtimeWorkspaceRoots"]
        return try digest(Dictionary(uniqueKeysWithValues:keys.map{($0,value[$0] ?? NSNull())}))
    }
    static func run(_ args:[String])throws {
        guard args.count==5,args[2].hasPrefix("/private/tmp/aa-cross-home-"),args[3].hasPrefix("/private/tmp/aa-cross-home-") else{throw AppError.message("Owned native restoration homes required")}
        let lines=Lines(),context=try lines.read(),sourceHome=args[2],destinationHome=args[3],threadID=args[4]
        guard let serverID=context["serverID"] as? String,let cliVersion=context["cliVersion"] as? String,
              ["0.166.0","0.167.1"].contains(cliVersion),let relative=context["sessionRelativePath"] as? String,
              let history=context["history"] as? [Any],let sourceSettings=context["settings"] as? JSONObject else{throw AppError.message("Owned native context missing")}
        let store=try AuditStore(path:URL(fileURLWithPath:sourceHome).deletingLastPathComponent().appendingPathComponent("retirement-audit.sqlite").path)
        let journal=try CodexMigrationJournal(store:store)
        guard let id=store.value("owned-goal-return-id"),let encoded=store.value("owned-goal-return-source") else{throw AppError.message("Owned return source missing")}
        _=try journal.repair(id:id)
        let goal=try CodexGoalReturn(journal:journal).state(id:id)
        let source=try JSONDecoder().decode(CodexMigrationRetirement.self,from:Data(encoded.utf8))
        let old=goal.backup.retirement
        let plan:CodexNativeReturnPlan
        if let saved=goal.nativeRestore?.plan {
            guard saved.server.serverID==serverID,saved.server.cliVersion==cliVersion,saved.rootID==threadID,saved.server.home==destinationHome,
                  saved.threads.count==1,saved.threads[0].source==source,saved.threads[0].sessionRelativePath==relative,
                  saved.threads[0].historyDigest == (try digest(history)),saved.threads[0].settingsDigest == (try settings(sourceSettings)) else{throw AppError.message("Owned restart context changed")}
            plan=saved
        }else{
            let archive=try CodexMigrationRolloutWitness.capture(home:destinationHome,homeIdentity:old.goal.homeIdentity,relative:old.rollout.relativePath)
            let identity=CodexNativeReturnServer(home:destinationHome,homeIdentity:old.goal.homeIdentity,serverID:serverID,cliVersion:cliVersion)
            let entry=CodexNativeReturnThread(source:source,archive:archive,sessionRelativePath:relative,historyDigest:try digest(history),settingsDigest:try settings(sourceSettings),previousOwner:goal.backup.currentOwner)
            plan = .init(rootID:threadID,server:identity,threads:[entry])
        }
        var acknowledgedSettings:[String:String]=[:],unarchives=0,resumes=0
        let services=CodexNativeReturnServices(observe:{plan in
            let raw=try lines.rpc("owned/observe",["threadId":threadID])
            guard let actualServer=raw["serverID"] as? String,raw["cliVersion"] as? String==cliVersion,let thread=raw["thread"] as? JSONObject,
                  let path=thread["path"] as? String,path.hasPrefix(destinationHome+"/"),
                  let loaded=raw["loadedIDs"] as? [String] else{throw AppError.message("Owned native observation missing")}
            let relative=String(path.dropFirst(destinationHome.count+1)),isLoaded=loaded.contains(threadID)
            let status=(thread["status"] as? JSONObject)?["type"] as? String
            // The sole surviving fixture broker may hold a real native reply
            // across a controller exit. Arbitrary production clients cannot
            // infer current settings from this fixture-only acknowledgment.
            var settingsProof=acknowledgedSettings[threadID]
            if let ack=raw["settingsAcknowledgment"] as? JSONObject {
                guard (ack["thread"] as? JSONObject)?["id"] as? String==threadID else{throw AppError.message("Owned settings acknowledgment changed thread")}
                settingsProof=try settings(ack)
            }
            let row=CodexNativeReturnObservation.Thread(id:threadID,relativePath:relative,archived:relative.hasPrefix("archived_sessions/"),loaded:isLoaded,
                active:status=="active",blocked:status != "idle" && status != "notLoaded",
                historyDigest:isLoaded ? try digest(thread["turns"] as? [Any] ?? []):nil,settingsDigest:settingsProof)
            var server=plan.server;server.serverID=actualServer
            return .init(server:server,affectedIDs:[threadID],completeScope:raw["ownedCompleteScope"] as? Bool==true,threads:[row])
        },unarchive:{_ in
            guard try CodexGoalReturn(journal:journal).state(id:id).nativeRestore?.phase == .unarchiveAttempted,
                  try journal.load(id:id)?.consistent==true else{throw AppError.message("Unarchive receipt not synced")}
            unarchives+=1
            let result=try lines.rpc("thread/unarchive",["threadId":threadID])
            guard (result["thread"] as? JSONObject)?["id"] as? String==threadID else{throw AppError.message("Owned unarchive ID changed")}
        },resume:{_,requested in
            guard requested==threadID,try CodexGoalReturn(journal:journal).state(id:id).nativeRestore?.phase == .resumeAttempted,
                  try journal.load(id:id)?.consistent==true else{throw AppError.message("Resume receipt not synced")}
            resumes+=1
            let result=try lines.rpc("thread/resume",["threadId":threadID,"excludeTurns":true])
            guard (result["thread"] as? JSONObject)?["id"] as? String==threadID else{throw AppError.message("Owned resume ID changed")}
            acknowledgedSettings[threadID]=try settings(result)
        })
        let engine=CodexNativeReturn(journal:journal,services:services)
        var state=try goal.nativeRestore==nil ? engine.prepare(id:id,plan:plan):engine.state(id:id)
        for _ in 0..<8 where state.phase != .verified {state=try engine.advance(id:id)}
        guard state.phase == .verified,unarchives<=1,resumes<=1 else{throw AppError.message("Owned native restore remains unverified")}
        _=try engine.commit(id:id)
        guard try engine.state(id:id).phase == .completed else{throw AppError.message("Owned native completion missing")}
        try lines.send(["type":"result","result":["verified":true,"journaledNativeRestore":true,"destinationOwnershipCommitted":true,"unarchiveRequests":unarchives,"resumeRequests":resumes]])
    }
}
