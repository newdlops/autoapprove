import Foundation
import AutoApproveCore
@main struct CLIContextCheck {
    static func main() async throws {
        let args=CommandLine.arguments
        guard args.count==4 || args.count==5 else{throw AppError.message("Owned CLI arguments required")}
        let start=ContinuousClock.now
        if args.count==5 {
            var witnesses:[CodexAccountTransitionWitness]=[]
            if let pid=Int32(args[4]),let row=try ProcessDiscovery.read(pid:pid).first {
                witnesses=[.init(pid:pid,started:row.started,tty:"/dev/"+row.tty,threadID:nil)]
            }
            let status=try await AgentAccountServices.codex(.init(home:args[3],executable:args[2],witnesses:witnesses)).check("codex")
            guard status.phase=="authenticated",status.method=="chatgpt" else{throw AppError.message("Scoped login status lost")}
            print("{\"verified\":true}");return
        }
        let status=try await CodexManagedServerServices.local(userHome:args[1],executable:args[2]).inspect(args[3],[])
        guard status.phase == .running,status.version=="0.166.0",status.autoStartEnabled==true else{throw AppError.message("CLI inspection lost literal metadata: "+status.detail)}
        print("{\"verified\":true,\"elapsed\":\"\(start.duration(to:.now))\"}")
    }
}

