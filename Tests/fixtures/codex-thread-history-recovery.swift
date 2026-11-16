import Foundation
import Darwin
@testable import AutoApproveCore

/// Process-death probes operate only on cloned, synthetic integration history.
/// No CLI, desktop, account, or model traffic is used by this helper.
@main struct HistoryRecoveryCheck {
    static func main()throws {
        let args=CommandLine.arguments
        guard args.count==7,args[1].hasPrefix("/private/tmp/aa-history-transfer-"),
              args[2].hasPrefix(args[1]+"/"),args[3].hasPrefix(args[1]+"/"),
              let id=UUID(uuidString:args[5]) else{throw AppError.message("Owned history fixture required")}
        let directory=args[1],source=args[2],destination=args[3],thread=args[4],mode=args[6]
        let store=try AuditStore(path:directory+"/history-journal.sqlite")
        let sourceLease=try CodexOfficialWriterLease(home:source,threadIDs:[thread],initializeDestination:true)
        let targetLease=try CodexOfficialWriterLease(home:destination,threadIDs:[thread],initializeDestination:true)
        defer{sourceLease.close();targetLease.close()}
        var checkpoints=0
        func install(_ replacing:Bool=false)throws {
            try CodexThreadHistoryTransfer.install(id:id,sourceHome:source,destinationHome:destination,
                threadID:thread,replacingRetired:replacing,store:store,checkpoint:{
                    try sourceLease.verifyScope(home:source,threadIDs:[thread])
                    try targetLease.verifyScope(home:destination,threadIDs:[thread])
                    checkpoints+=1
                    if mode=="capture",checkpoints==1{_exit(88)}
                    if mode=="crash-before",checkpoints==2{_exit(87)}
                    if mode=="crash-after",checkpoints==3{_exit(86)}
                })
        }
        if mode=="reject" {
            var rejected=false
            do{try install()}catch{rejected=true}
            guard rejected else{throw AppError.message("Changed history was overwritten")}
            print("{\"verified\":true,\"rejected\":true}");return
        }
        let observed=try CodexThreadHistoryTransfer.completed(id:id,sourceHome:source,destinationHome:destination,threadID:thread,store:store)
        try install(mode=="return")
        guard try CodexThreadHistoryTransfer.completed(id:id,sourceHome:source,destinationHome:destination,threadID:thread,store:store) else{throw AppError.message("History recovery did not confirm the applied state")}
        print("{\"verified\":true,\"alreadyApplied\":\(observed),\"checkpoints\":\(checkpoints)}")
    }
}
