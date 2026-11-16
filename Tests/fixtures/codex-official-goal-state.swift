import Foundation
@testable import AutoApproveCore

@main struct OfficialGoalStateCheck {
    static func main() throws {
        let args=CommandLine.arguments
        guard args.count>=5,args[1].hasPrefix("/private/tmp/aa-child-goal-"),args[1].hasSuffix("/home") else{throw AppError.message("Owned child Goal home required")}
        let access=try CodexOfficialGoalStateAccess(home:args[1],userHome:URL(fileURLWithPath:args[1]).deletingLastPathComponent().path,executable:args[2])
        if args[3]=="snapshot" {
            let value=try access.snapshot(threadID:args[4])
            if value.row.status=="active" {
                var rejected=false
                do{_ = try CodexGoalTransferStore.captureSlot(home:args[1],threadID:args[4])}catch{rejected=true}
                guard rejected else{throw AppError.message("Active state observation may not make a Goal transferable")}
            }
            print(String(decoding:try JSONEncoder().encode(value),as:UTF8.self));return
        }
        guard args.count==7 else{throw AppError.message("Owned resume snapshot and timestamp required")}
        let expected=try JSONDecoder().decode(CodexOfficialGoalStateSnapshot.self,from:Data(args[5].utf8))
        guard let timestamp=Int64(args[6]),expected.row.threadID==args[4] else{throw AppError.message("Owned Goal identity mismatch")}
        let mode=args[3]
        if mode.hasPrefix("journal:") {
            let parts=mode.split(separator:":")
            guard parts.count==3,let id=UUID(uuidString:String(parts[1])) else{throw AppError.message("Owned journal request ID required")}
            let journal=try CodexOfficialGoalStateJournal(path:URL(fileURLWithPath:args[1]).deletingLastPathComponent().appendingPathComponent("goal-state-journal.sqlite").path)
            let receipt=try journal.restore(id:id,expected:expected,updatedAtMs:timestamp,access:access,
                afterReserve:{if parts[2]=="reserveCrash"{_exit(70)}},afterApply:{
                    let log=URL(fileURLWithPath:args[1]).deletingLastPathComponent().appendingPathComponent("state-applied-"+id.uuidString+".log")
                    if !FileManager.default.fileExists(atPath:log.path){FileManager.default.createFile(atPath:log.path,contents:nil)}
                    let file=try FileHandle(forWritingTo:log);defer{try? file.close()}
                    try file.seekToEnd();try file.write(contentsOf:Data("applied\n".utf8));try file.synchronize()
                    if parts[2]=="applyCrash"{_exit(71)}
                })
            print(String(decoding:try JSONEncoder().encode(receipt),as:UTF8.self));return
        }
        let socket=args[1]+"/app-server-control/app-server-control.sock",backup=socket+".owned-held"
        var moved=false
        defer{if moved{try? FileManager.default.moveItem(atPath:backup,toPath:socket)}}
        var checks=0
        do {
            let result=try access.resume(expected,updatedAtMs:timestamp,check:{
                checks+=1
                // The third callback runs after SQL updates and before COMMIT.
                if mode=="cancel",checks==3 {throw CancellationError()}
                if mode=="sqlCrash",checks==3 {_exit(72)}
                if mode=="lostBinding",checks==3 {try FileManager.default.moveItem(atPath:socket,toPath:backup);moved=true}
            })
            guard mode=="resume" || mode=="compete" else{throw AppError.message("Unexpected Goal restore acceptance")}
            let encoded=String(decoding:try JSONEncoder().encode(result),as:UTF8.self)
            print(mode=="compete" ? "{\"accepted\":true,\"snapshot\":"+encoded+"}":encoded)
        }catch {
            guard ["reject","cancel","lostBinding","compete"].contains(mode),!error.localizedDescription.contains("Unexpected Goal restore acceptance") else{throw error}
            print("{\"rejected\":true,\"checks\":\(checks)}")
        }
    }
}
