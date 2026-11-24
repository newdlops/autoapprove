import Foundation
import Darwin

enum ClaudeBackgroundJobs {
    static let provider = GroupJobProvider(inventory: { live,group,member in
        let thread = try conversation(live)
        let directory = try taskDirectory(live,thread:thread)
        let generation = live.id
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath:directory,isDirectory:&isDirectory), isDirectory.boolValue else {
            return .init(server:generation,jobs:[],complete:false)
        }
        guard let owner = try ProcessDiscovery.read(pid:live.session.pid).first(where: { $0.key == live.id && $0.agent == .claude && "/dev/" + $0.tty == live.session.tty }) else { throw GroupJobProvider.stale() }
        var jobs: [GroupBackgroundJob] = []
        let children = try related(owner.pid,children:true)
        for root in children where root.parent == owner.pid && root.pid == root.processGroup && root.processGroup != owner.processGroup && (root.tty != owner.tty || !root.isForeground) {
            let executable = URL(fileURLWithPath:root.executable).lastPathComponent
            guard ["sh","bash","zsh"].contains(executable),
                  let file = taskFile(root:root,directory:directory,records:try related(root.pid,children:false)) else { continue }
            let nativeID = URL(fileURLWithPath:file).deletingPathExtension().lastPathComponent
            let arguments = ProcessEnvironment.arguments(root) ?? []
            let command = arguments.last.flatMap { $0.count > 0 && $0 != root.executable ? $0 : nil } ?? executable
            var job = GroupBackgroundJob(group:group,member:member,session:live.id,conversation:thread,server:generation,
                process:nativeID,item:root.key,command:String(SessionGroupOrchestration.oneLine(command).prefix(160)),firstSeen:Date())
            job.startedAt = ProcessEnvironment.startDate(root.started)
            job.outputFileIdentity = fileIdentity(file)
            jobs.append(job)
        }
        let counts = Dictionary(grouping:jobs,by:\.process)
        return .init(server:generation,jobs:jobs.filter { counts[$0.process]?.count == 1 },complete:false)
    }, evidence: { live,job in
        let thread = try conversation(live)
        guard live.id == job.session, thread == job.conversation, validID(job.process),
              let pid = pid(job) else { throw GroupJobProvider.stale() }
        let active: Bool
        if Darwin.kill(-pid,0) == 0 { active = true }
        else if errno == ESRCH { active = false }
        else { throw GroupJobProvider.stale() }
        let file = try taskDirectory(live,thread:thread) + "/" + job.process + ".output"
        return .init(output:tail(file,identity:job.outputFileIdentity),ended:!active)
    }, stop: { live,job,authorize in
        let thread = try conversation(live)
        guard live.id == job.session, thread == job.conversation, validID(job.process), let pid = pid(job) else { throw GroupJobProvider.stale() }
        let directory = try taskDirectory(live,thread:thread)
        try await authorize()
        return try await Task.detached {
            let records = try related(pid,children:false)
            guard let owner = try ProcessDiscovery.read(pid:live.session.pid).first(where: { $0.key == live.id && $0.agent == .claude && "/dev/" + $0.tty == live.session.tty }),
                  let root = records.first(where: { $0.key == job.item && $0.pid == pid && $0.parent == owner.pid &&
                      $0.processGroup == pid && pid != owner.processGroup }),
                  (root.tty != owner.tty || !root.isForeground),
                  taskFile(root:root,directory:directory,records:records) == directory + "/" + job.process + ".output",
                  let identity = job.outputFileIdentity, identity == fileIdentity(directory + "/" + job.process + ".output"),
                  try ProcessDiscovery.readAncestorChain(of:pid,through:owner.pid).map(\.key) == [root.key,owner.key],
                  getpgid(pid) == pid else { throw GroupJobProvider.stale() }
            guard Darwin.kill(-pid,SIGTERM) == 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
            return true
        }.value
    })

    private static func related(_ pid:Int32,children:Bool) throws -> [ProcessRecord] {
        var pids = [Int32](repeating:0,count:257)
        let count = pids.withUnsafeMutableBytes { buf in
            children ? proc_listchildpids(pid,buf.baseAddress,Int32(buf.count)) : proc_listpgrppids(pid,buf.baseAddress,Int32(buf.count))
        }
        guard count >= 0, Int(count) < pids.count else { throw GroupJobProvider.stale() }
        var rows: [ProcessRecord] = []
        for id in pids.prefix(Int(count)) where id > 0 {
            rows += try ProcessDiscovery.read(pid:id)
        }
        return rows
    }

    private static func pid(_ job: GroupBackgroundJob) -> Int32? {
        let fields = job.item.split(separator:":",maxSplits:2)
        guard fields.count == 3, fields[0] == "process", let pid = Int32(fields[1]), pid > 1 else { return nil }
        return pid
    }

    private static func conversation(_ live: SessionGroupLiveSession) throws -> String {
        guard live.session.agent == .claude, let id = live.conversationID, UUID(uuidString:id) != nil else { throw GroupJobProvider.stale() }
        return id.lowercased()
    }

    private static func taskDirectory(_ live: SessionGroupLiveSession, thread: String) throws -> String {
        let project = live.session.cwd.replacingOccurrences(of:"[^a-zA-Z0-9]",with:"-",options:.regularExpression)
        guard !project.isEmpty, project.utf8.count <= 255 else { throw GroupJobProvider.stale() }
        return "/private/tmp/claude-\(getuid())/" + project + "/" + thread + "/tasks"
    }

    private static func validID(_ id: String) -> Bool {
        (1...128).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private static func taskFile(root:ProcessRecord,directory:String,records:[ProcessRecord]) -> String? {
        let members = records.filter { $0.processGroup == root.pid }
        let indexed = ProcessDiscovery.index(records)
        guard !members.isEmpty, members.count <= 64, members.allSatisfy({ row in row.agent == nil &&
            (row.pid == root.pid || ProcessDiscovery.ancestors(of:row.pid,byPID:indexed).contains(where: { $0.key == root.key })) }) else { return nil }
        var paths = Set<String>()
        for row in members {
            for fd: Int32 in [1,2] {
                var info = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout.size(ofValue:info))
                guard proc_pidfdinfo(row.pid,fd,PROC_PIDFDVNODEPATHINFO,&info,size) == size,
                      info.pvip.vip_vi.vi_stat.vst_uid == getuid() else { continue }
                let path = withUnsafeBytes(of:info.pvip.vip_path) { String(decoding:$0.prefix(while: { $0 != 0 }),as:UTF8.self) }
                let url = URL(fileURLWithPath:path)
                guard url.deletingLastPathComponent().path == directory, url.pathExtension == "output",
                      validID(url.deletingPathExtension().lastPathComponent) else { continue }
                paths.insert(path)
            }
        }
        return paths.count == 1 ? paths.first : nil
    }

    private static func fileIdentity(_ path:String) -> String? {
        var info = stat()
        guard lstat(path,&info) == 0, info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }

    private static func tail(_ path:String,identity:String?) -> String? {
        guard let canonical = realpath(path,nil) else { return nil }
        defer { free(canonical) }
        guard String(cString:canonical) == path else { return nil }
        let fd = open(path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_nlink == 1, identity == "\(info.st_dev):\(info.st_ino)", info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              (try? handle.seek(toOffset:UInt64(max(0,info.st_size-6400)))) != nil,
              let data = try? handle.read(upToCount:6400) else { return nil }
        return String(String(decoding:data,as:UTF8.self).suffix(1600))
    }
}

final class BackgroundJobExitObservation {
    private let queue: Int32
    private let pid: Int32
    private var observed: GroupJobEvidence?

    init?(job: GroupBackgroundJob) {
        let parts = job.item.split(separator:":",maxSplits:2)
        guard parts.count == 3, parts[0] == "process", let pid = Int32(parts[1]), pid > 1,
              (try? ProcessDiscovery.read(pid:pid))?.first?.key == job.item else { return nil }
        let fd = kqueue()
        guard fd >= 0 else { return nil }
        var registration = kevent(ident:UInt(pid),filter:Int16(EVFILT_PROC),flags:UInt16(EV_ADD | EV_ONESHOT),
                                  fflags:NOTE_EXIT | UInt32(NOTE_EXITSTATUS),data:0,udata:nil)
        guard fcntl(fd,F_SETFD,FD_CLOEXEC) == 0, kevent(fd,&registration,1,nil,0,nil) == 0,
              (try? ProcessDiscovery.read(pid:pid))?.first?.key == job.item else { close(fd); return nil }
        self.queue = fd
        self.pid = pid
    }

    func result() -> GroupJobEvidence? {
        if let observed { return observed }
        var event = kevent(), timeout = timespec()
        guard kevent(queue,nil,0,&event,1,&timeout) == 1, event.ident == UInt(pid),
              event.flags & UInt16(EV_ERROR) == 0, event.fflags & UInt32(NOTE_EXITSTATUS) != 0 else { return nil }
        let signal = event.data & 0x7f
        let code = signal == 0 ? (event.data >> 8) & 0xff : nil
        let result = GroupJobEvidence(exitCode:code,failed:signal != 0 || code != 0,ended:true)
        observed = result
        return result
    }

    deinit { close(queue) }
}
