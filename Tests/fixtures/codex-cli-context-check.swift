import Foundation
@testable import AutoApproveCore
@main struct CLIContextCheck {
    static func main() async throws {
        let args=CommandLine.arguments
        guard args.count==4 || args.count==5 else{throw AppError.message("Owned CLI arguments required")}
        let start=ContinuousClock.now
        if args.count==5 {
            if ["browser","device"].contains(args[4]) {
                let services=AgentAccountServices.local(userHome:args[1],codexHome:args[3],executable:args[2],
                    browser:args[4]=="browser",verifyExecutable:{_ in})
                let pty=try services.launch("codex")
                defer {pty.close()}
                for _ in 0..<100 {
                    if let exit=pty.descriptor.exitCode {guard exit==0 else {throw AppError.message("Owned login environment rejected: \(exit) \(pty.screen())")};print("{\"verified\":true}");return}
                    try await Task.sleep(for:.milliseconds(20))
                }
                throw AppError.message("Owned login did not exit")
            }
            var witnesses:[CodexAccountTransitionWitness]=[]
            if let pid=Int32(args[4]),let row=try ProcessDiscovery.read(pid:pid).first {
                witnesses=[.init(pid:pid,started:row.started,tty:"/dev/"+row.tty,threadID:nil)]
            }
            let status=try await AgentAccountServices.local(userHome:args[1],codexHome:args[3],executable:args[2],
                witnesses:witnesses,verifyExecutable:{_ in}).check("codex")
            guard status.phase=="authenticated",status.method=="chatgpt" else{throw AppError.message("Scoped login status lost")}
            print("{\"verified\":true}");return
        }
        let status=try await CodexManagedServerServices.local(userHome:args[1],executable:args[2],verifyExecutable:{_ in}).inspect(args[3],[])
        guard status.phase == .running,status.version=="0.166.0",status.autoStartEnabled==true else{throw AppError.message("CLI inspection lost literal metadata: "+status.detail)}
        print("{\"verified\":true,\"elapsed\":\"\(start.duration(to:.now))\"}")
    }
}

