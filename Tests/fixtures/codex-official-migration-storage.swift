import Foundation
@testable import AutoApproveCore

// Explicitly known owned roots only. This adapter supplies no discovery,
// complete-client assertion or production runtime migration authority.
enum OfficialMigrationStorage {
    private struct Forward:Codable {let intent:CodexOfficialRetirementIntent}
    static func run(_ args:[String])throws->Bool {
        if args.count==6,args[1]=="--production-official-transfer" {
            guard args[2].hasPrefix("/private/tmp/aa-cross-home-"),args[3].hasPrefix("/private/tmp/aa-cross-home-"),UUID(uuidString:args[4]) != nil else{throw AppError.message("Owned official transfer required")}
            let path=URL(fileURLWithPath:args[2]).deletingLastPathComponent().appendingPathComponent("production-transfer-audit.sqlite").path
            let service=try CodexOfficialConversationTransfer(store:AuditStore(path:path)),id=UUID()
            try service.prepare(id:id,sourceHome:args[2],destinationHome:args[3],threadID:args[4],archivedPath:args[5],checkpoint:{})
            fputs("Owned production transfer prepared\n",stderr)
            let value=try service.advance(id:id,checkpoint:{})
            fputs("Owned production transfer advanced\n",stderr)
            guard try service.completed(id:id),let relative=value.imported?.importedFiles.first?.relativePath ?? (value.returnVerified==true ? value.returnTo?.originalArchivePath:nil) else{throw AppError.message("Official transfer did not commit")}
            _=try service.advance(id:id,checkpoint:{})
            guard try CodexOfficialConversationTransfer(store:AuditStore(path:path)).completed(id:id) else{throw AppError.message("Cold official transfer receipt missing")}
            print(String(decoding:try JSONSerialization.data(withJSONObject:["verified":true,"productionTransfer":true,"coldReceiptVerified":true,"returnVerified":value.returnVerified==true,"importedPath":args[3]+"/"+relative]),as:UTF8.self))
            return true
        }
        guard args.count==6,["--official-retire","--official-commit","--official-return","--official-return-crash"].contains(args[1]) else{return false}
        guard args[2].hasPrefix("/private/tmp/aa-cross-home-"),args[3].hasPrefix("/private/tmp/aa-cross-home-"),
              UUID(uuidString:args[4])?.uuidString.lowercased()==args[4] else{throw AppError.message("Owned original migration scope required")}
        let source=args[2],destination=args[3],thread=args[4],mode=args[1]
        let store=try AuditStore(path:URL(fileURLWithPath:source).deletingLastPathComponent().appendingPathComponent("retirement-audit.sqlite").path)
        let journal=try CodexMigrationJournal(store:store),service=CodexOfficialRetirement(journal:journal)
        if mode=="--official-retire" {
            let retirement=try CodexMigrationRetirement.capture(home:source,threadID:thread,rolloutPath:args[5])
            let request=try journal.create(id:UUID().uuidString,homes:[source,destination],payload:Data("Owned explicit source, official archive retention".utf8))
            let lease=try CodexOfficialWriterLease(home:source,threadIDs:[thread]);defer{lease.close()}
            let intent=try service.prepare(record:request,source:retirement,lease:lease,checkpoint:{})
            guard try service.withdraw(intent,record:request,lease:lease,checkpoint:{}) == .withheld else{throw AppError.message("Owned source was not retained")}
            let fact=try service.storageFact(intent)
            try store.set("owned-official-forward",String(decoding:try JSONEncoder().encode(Forward(intent:intent)),as:UTF8.self))
            let result:[String:Any]=["verified":true,"sourceWithdrawn":true,"retainedPath":source+"/"+fact.rollout.relativePath]
            print(String(decoding:try JSONSerialization.data(withJSONObject:result),as:UTF8.self));return true
        }
        if mode=="--official-commit" {
            guard let data=store.value("owned-official-forward") else{throw AppError.message("Owned original retirement receipt missing")}
            let intent=try JSONDecoder().decode(Forward.self,from:Data(data.utf8)).intent
            let record=try journal.repair(id:intent.requestID),fact=try service.storageFact(intent)
            guard let target=record.homes.first(where:{$0.path==destination}),fact.goal.sourceHome==source else{throw AppError.message("Owned original destination changed")}
            _=try journal.complete(id:record.id,payload:record.payload,expectedRevision:record.revision,
                ownership:[.init(threadID:thread,previous:nil,destination:target,retirement:fact)])
            try journal.release(id:record.id)
            print("{\"verified\":true,\"nativeRetirementWitnessed\":true,\"officialStorageOwnerCommitted\":true}");return true
        }
        if let existing=store.value("owned-official-return-id") {
            _=try journal.repair(id:existing)
            let from=try CodexOfficialWriterLease(home:source,threadIDs:[thread]),to=try CodexOfficialWriterLease(home:destination,threadIDs:[thread])
            defer{from.close();to.close()}
            let publication=CodexOfficialArchivePublication(journal:journal)
            guard try publication.advance(id:existing,source:from,destination:to,checkpoint:{}).stage == .verified,
                  try publication.observe(id:existing) == .applied,store.value("owned-official-publication-count")=="1" else{throw AppError.message("Owned publication recovery did not confirm its one rename")}
            print("{\"verified\":true,\"exactGoalReturned\":true,\"latestHistoryReturned\":true,\"latestArchivePublished\":true,\"publicationRenameCount\":1,\"nativeOwnershipCommitted\":false}")
            return true
        }
        guard let owner=try journal.owner(threadID:thread),owner.home.path==source else{throw AppError.message("Owned latest source owner missing")}
        let old=try journal.retired(threadID:thread,toHome:destination,expectedOwner:owner)
        let request=try journal.create(id:UUID().uuidString,homes:[source,destination],payload:Data("Owned latest official history return".utf8))
        let from=try CodexOfficialWriterLease(home:source,threadIDs:[thread]),to=try CodexOfficialWriterLease(home:destination,threadIDs:[thread])
        defer{from.close();to.close()}
        let archive=try CodexMigrationRetirement.capture(home:source,threadID:thread,rolloutPath:args[5])
        let intent=try service.prepare(record:request,source:archive,lease:from,checkpoint:{})
        guard try service.withdraw(intent,record:request,lease:from,checkpoint:{}) == .withheld else{throw AppError.message("Owned latest source remains writable")}
        let latest=try service.storageFact(intent)
        let backup=try journal.backupRetired(old,expectedOwner:owner,requestID:request.id,expectedRevision:request.revision)
        let goals=CodexGoalReturn(journal:journal)
        _=try goals.prepare(backup:backup,source:latest.goal,expectedRevision:request.revision)
        guard [.applied,.unchanged].contains(try goals.apply(id:request.id)) else{throw AppError.message("Owned latest Goal not returned")}
        let history=CodexRolloutReturn(journal:journal)
        _=try history.prepare(id:request.id,source:latest)
        guard [.applied,.unchanged].contains(try history.apply(id:request.id)) else{throw AppError.message("Owned latest history not returned")}
        let publication=CodexOfficialArchivePublication(journal:journal)
        _=try publication.prepare(id:request.id,source:from,destination:to,checkpoint:{})
        try store.set("owned-goal-return-id",request.id)
        try store.set("owned-official-return-id",request.id)
        try store.set("owned-goal-return-source",String(decoding:try JSONEncoder().encode(latest),as:UTF8.self))
        guard try publication.advance(id:request.id,source:from,destination:to,checkpoint:{},afterRename:{
            guard store.value("owned-official-publication-count")==nil else{throw AppError.message("Owned publication repeated its rename")}
            try store.set("owned-official-publication-count","1")
            if mode=="--official-return-crash" {_exit(84)}
        }).stage == .verified,
              try publication.observe(id:request.id) == .applied else{throw AppError.message("Owned latest archive not published")}
        print("{\"verified\":true,\"exactGoalReturned\":true,\"latestHistoryReturned\":true,\"latestArchivePublished\":true,\"publicationRenameCount\":1,\"nativeOwnershipCommitted\":false}")
        return true
    }
}
