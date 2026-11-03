import Foundation
import AutoApproveCore

@main struct DiscoveryCheck {
    static func main() async throws {
        let args=CommandLine.arguments
        guard args.count==5,let pid=Int32(args[1]),pid>0 else {throw AppError.message("Owned fixture PID required")}
        let records=try ProcessDiscovery.read(pid:pid)
        guard records.count==1,records[0].agent == .codex,records[0].tty.hasPrefix("ttys"),records[0].executable==args[4] else {
            throw AppError.message("Synthetic argv[0]/PTY metadata differs")
        }
        let targets=try await CodexAccountTransitionTarget.discover(records)
        let home=try CodexAccountTransitionTarget.canonicalHome(args[2])
        guard targets.count==1,targets[0].home==home,targets[0].executable==args[3],
              targets[0].witnesses.count==1,targets[0].witnesses[0].pid==pid else {
            throw AppError.message("Connected synthetic Codex was omitted: argv[0]="+records[0].executable)
        }
        var stale=records;stale[0].started="Mon Jan 1 00:00:00 2001"
        guard try await CodexAccountTransitionTarget.discover(stale).isEmpty else {throw AppError.message("Stale original identity was accepted")}
        print("{\"verified\":true,\"actualPTY\":true,\"actualUnixConnection\":true,\"staleIdentityRejected\":true}")
    }
}
