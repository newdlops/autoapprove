import Foundation
import Darwin
@testable import AutoApproveCore

@main struct OfficialRetirementCheck {
    struct Driver:Codable {let intent:CodexOfficialRetirementIntent}
    static func main() throws {
        let args=CommandLine.arguments
        guard args.count==7,args[1].hasPrefix("/private/tmp/aa-official-retirement-"),
              args[2]==args[1]+"/source",args[3]==args[1]+"/destination",
              UUID(uuidString:args[4])?.uuidString.lowercased()==args[4],args[5].hasPrefix(args[2]+"/archived_sessions/") else {
            throw AppError.message("Owned retirement fixture scope required")
        }
        let root=args[1],source=args[2],destination=args[3],thread=args[4],mode=args[6]
        let driver=URL(fileURLWithPath:root+"/driver-"+thread+".json")
        let journal=try CodexMigrationJournal(store:AuditStore(path:root+"/retirement-audit.sqlite"))
        let service=CodexOfficialRetirement(journal:journal)
        if mode=="prepare" || mode=="prepare-crash" {
            let archived=try CodexMigrationRetirement.capture(home:source,threadID:thread,rolloutPath:args[5])
            let record=try journal.create(id:UUID().uuidString,homes:[source,destination],payload:Data("Owned retirement storage operation; no migration authority".utf8))
            let lease=try CodexOfficialWriterLease(home:source,threadIDs:[thread]);defer{lease.close()}
            let intent=try service.prepare(record:record,source:archived,lease:lease,checkpoint:{})
            if mode=="prepare-crash" {_exit(79)}
            try JSONEncoder().encode(Driver(intent:intent)).write(to:driver,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:driver.path)
            print("{\"state\":\"reserved\"}");return
        }
        let intent:CodexOfficialRetirementIntent
        if mode.hasPrefix("recover") {
            let active=try journal.activeRecords();guard active.count==1 else{throw AppError.message("Owned active request is ambiguous")}
            let record=try journal.repair(id:active[0].id)
            intent=try service.load(record:record,sourceHome:source,threadID:thread)
            if mode=="recover" {print("{\"state\":\"\(try service.observe(intent).rawValue)\"}");return}
        }else{intent=try JSONDecoder().decode(Driver.self,from:Data(contentsOf:driver)).intent}
        if mode=="inspect" {print("{\"state\":\"\(try service.observe(intent).rawValue)\"}");return}
        let record=try journal.repair(id:intent.requestID)
        if mode=="finish" || mode=="recover-finish" {
            _=try journal.save(id:record.id,payload:record.payload,expectedRevision:record.revision,terminal:true)
            try journal.release(id:record.id);print("{\"finished\":true}");return
        }
        let fake="00000000-0000-4000-8000-000000000001"
        let lease=try CodexOfficialWriterLease(home:source,threadIDs:[mode=="reject-scope" ? fake:thread]);defer{lease.close()}
        if ["reject-checkpoint","reject-scope","reject-terminal","prepare-again"].contains(mode) {
            var rejected=false
            do {
                if mode=="prepare-again" {_=try service.prepare(record:record,source:intent.source,lease:lease,checkpoint:{})}
                else {_=try service.withdraw(intent,record:record,lease:lease,checkpoint:{if mode=="reject-checkpoint" {throw AppError.message("Owned changed authority")}})}
            }catch{rejected=true}
            guard rejected else{throw AppError.message("Invalid owned retirement request accepted")}
            print("{\"rejected\":true}");return
        }
        func moved(_ operation:String)throws {
            let path=root+"/count-"+thread+"-"+operation
            let fd=open(path,O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW|O_CLOEXEC,0o600)
            guard fd>=0 else{throw AppError.message("Owned effect counter unavailable")};defer{close(fd)}
            guard write(fd,"1\n",2)==2,fsync(fd)==0 else{throw AppError.message("Owned effect count not durable")}
        }
        let result:CodexOfficialRetirement.Observation
        if mode.hasPrefix("withdraw") {
            result=try service.withdraw(intent,record:record,lease:lease,checkpoint:{},
                afterAttempt:{if mode=="withdraw-attempt-crash" {_exit(80)}},
                afterRename:{try moved("withdraw");if mode=="withdraw-rename-crash" {_exit(81)}})
        }else if mode.hasPrefix("return") {
            result=try service.returnOriginal(intent,record:record,lease:lease,checkpoint:{},
                afterAttempt:{if mode=="return-attempt-crash" {_exit(82)}},
                afterRename:{try moved("return");if mode=="return-rename-crash" {_exit(83)}})
        }else{throw AppError.message("Unknown owned retirement action")}
        print("{\"state\":\"\(result.rawValue)\"}")
    }
}
