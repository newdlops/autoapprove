import Darwin
import Foundation

final class CodexAccountIdleProbe: @unchecked Sendable {
    private struct FileStamp: Equatable {
        let path: String
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let changed: Int
        let nanos: Int

        init?(_ path: String, type: mode_t) {
            self.path = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            var info = stat()
            guard lstat(self.path, &info) == 0, info.st_mode & S_IFMT == type,
                  info.st_uid == getuid() || (type == S_IFREG && info.st_uid == 0) else { return nil }
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            changed = info.st_ctimespec.tv_sec
            nanos = info.st_ctimespec.tv_nsec
        }
    }

    private struct Environment: Equatable {
        let cli: FileStamp
        let managed: FileStamp
        let socket: FileStamp
        let peer: [String]

        init?(target: CodexAccountTransitionTarget, runtime: CodexAccountRuntime, peer: [String]) {
            guard !peer.isEmpty, let selected = try? CodexManagedPackageSelection.selectedExecutable(home: target.home),
                  let path = CodexQueueConnection.socketPath(home: target.home),
                  let cli = FileStamp(runtime.context.executable, type: S_IFREG),
                  let managed = FileStamp(selected, type: S_IFREG),
                  let socket = FileStamp(path, type: S_IFSOCK) else { return nil }
            self.cli = cli
            self.managed = managed
            self.socket = socket
            self.peer = peer
        }
    }

    private struct Entry {
        let environment: Environment
        let serverID: String
        let checkedAt: TimeInterval
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func observe(_ target: CodexAccountTransitionTarget, runtime: CodexAccountRuntime) throws -> CodexAccountTransitionObservation {
        let connection = try CodexQueueConnection(home: target.home, requestScopedDeadline: true)
        let peer = try runtime.connectedServerIdentity(connection)
        let environment = Environment(target: target, runtime: runtime, peer: peer)
        let entry = lock.withLock { entries[target.home] }
        let now = ProcessInfo.processInfo.systemUptime
        if let entry, let environment, entry.environment == environment, now - entry.checkedAt < 300 {
            let saved = try CodexAccountMetadataProcess.read(target, runtime: runtime)
            let current = try CodexAccountTransitionLocal.account(connection.request("accountSession/list", ["refreshWorkspaceMetadata": false]))
            try runtime.validate(target)
            if saved == nil || saved == current {
                let finalPeer = try runtime.connectedServerIdentity(home: target.home)
                if Environment(target: target, runtime: runtime, peer: finalPeer) == environment {
                    return .init(savedAccount: saved, serverAccount: current, serverID: entry.serverID, threads: [])
                }
            }
        }

        var managedPath: String?, verifiedPeer: [String]?
        let result = try CodexAccountTransitionLocal.observe(target, runtime: runtime, idleCheck: true) { path, identity in
            managedPath = path
            verifiedPeer = identity
        }
        if let environment, let managedPath, verifiedPeer == peer,
           environment.managed.path == URL(fileURLWithPath: managedPath).resolvingSymlinksInPath().path,
           result.savedAccount == nil || result.savedAccount == result.serverAccount,
           Environment(target: target, runtime: runtime, peer: try runtime.connectedServerIdentity(home: target.home)) == environment {
            lock.withLock {
                if entries.count >= 32, entries[target.home] == nil { entries.removeAll(keepingCapacity: true) }
                entries[target.home] = Entry(environment: environment, serverID: result.serverID, checkedAt: now)
            }
        }
        return result
    }
}
