import Foundation
import Darwin

enum ClaudeFetchInterrupt {
    struct Target: Equatable {
        let pid: Int32
        let seconds: UInt64
        let micros: UInt64

        var token: String { "fetch:\(pid):\(seconds):\(micros)" }
        var started: Date { Date(timeIntervalSince1970:Double(seconds) + Double(micros) / 1_000_000) }

        init?(pid: Int32) {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout.size(ofValue:info))
            guard pid > 1, proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,size) == size, info.pbi_uid == getuid() else { return nil }
            self.pid = pid
            seconds = info.pbi_start_tvsec
            micros = info.pbi_start_tvusec
        }
    }

    static func status(_ token: String) -> String {
        let parts = token.split(separator:":")
        guard parts.count == 4, let pid = Int32(parts[1]), pid > 1 else { return "unknown" }
        if let current = Target(pid:pid) { return current.token == token ? "fetchStopRequested" : "fetchExited" }
        return kill(pid,0) == -1 && errno == ESRCH ? "fetchExited" : "unknown"
    }

    static func find(_ session: AgentSession, after: Date) throws -> Target? {
        let rows = try ProcessDiscovery.read()
        let indexed = ProcessDiscovery.index(rows)
        guard session.agent == .claude, let owner = indexed[session.pid], owner.key == session.id,
              owner.agent == .claude, "/dev/" + owner.tty == session.tty else { return nil }
        let matches = rows.compactMap { row -> Target? in
            guard (row.executable as NSString).lastPathComponent == "git", row.processGroup != owner.processGroup,
                  !(row.isForeground && row.tty == owner.tty),
                  ProcessDiscovery.ancestors(of:row.pid,byPID:indexed).contains(where: { $0.key == owner.key }),
                  let chain = try? ProcessDiscovery.readAncestorChain(of:row.pid,through:owner.pid),
                  chain.first?.key == row.key, chain.last?.key == owner.key,
                  chain.dropFirst().dropLast().allSatisfy({ ["sh","zsh","bash"].contains(($0.executable as NSString).lastPathComponent) }),
                  let target = Target(pid:row.pid), target.started >= after,
                  let args = ProcessEnvironment.arguments(row), args.dropFirst().first == "fetch",
                  Target(pid:row.pid) == target else { return nil }
            return target
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func stop(_ target: Target, session: AgentSession, after: Date) throws {
        guard try find(session,after:after) == target, Target(pid:target.pid) == target else { throw GroupJobProvider.stale() }
        guard kill(target.pid,SIGTERM) == 0 else {
            throw RemoteHTTPError(409,"git fetch 종료 요청을 전달하지 못했습니다.",diagnostics:["delivery":"not_started"])
        }
    }
}
