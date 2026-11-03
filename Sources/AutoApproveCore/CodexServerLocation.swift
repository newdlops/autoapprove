import Foundation
import Darwin

/// Accept a launch home only when the original process is connected to its
/// exact user-owned control socket. Never guess by project or recent history.
public enum CodexServerLocation {
    /// argv[0] may be just "codex" for a normal PATH launch. Resolve the
    /// executable from the kernel, never from cwd or an unrelated PATH entry.
    static func executable(_ record:ProcessRecord) -> String? {
        func sameOriginal() -> Bool {
            (try? ProcessDiscovery.read(pid:record.pid))?.contains {
                $0.key==record.key && $0.tty==record.tty && $0.executable==record.executable && $0.agent == .codex
            } == true
        }
        var owner=proc_bsdinfo(),buffer=[UInt8](repeating:0,count:4096)
        let size=Int32(MemoryLayout<proc_bsdinfo>.size)
        guard record.pid>0,sameOriginal(),proc_pidinfo(record.pid,PROC_PIDTBSDINFO,0,&owner,size)==size,
              owner.pbi_uid==getuid(),proc_pidpath(record.pid,&buffer,UInt32(buffer.count))>0,
              let end=buffer.firstIndex(of:0),end>0 else{return nil}
        let path=String(decoding:buffer[..<end],as:UTF8.self)
        var binary=stat(),identity=record;identity.executable=path
        var after=proc_bsdinfo()
        guard path.hasPrefix("/"),identity.agent == .codex,FileManager.default.isExecutableFile(atPath:path),
              stat(path,&binary)==0,[getuid(),0].contains(binary.st_uid),sameOriginal(),
              proc_pidinfo(record.pid,PROC_PIDTBSDINFO,0,&after,size)==size,after.pbi_uid==getuid(),
              after.pbi_start_tvsec==owner.pbi_start_tvsec,after.pbi_start_tvusec==owner.pbi_start_tvusec else{return nil}
        return path
    }
    public static func connectedHome(pid: Int32, hints: [String], peerPID: Int32? = nil) -> String? {
        let paths = connectedSocketPaths(pid: pid, peerPID: peerPID)
        guard !paths.isEmpty else { return nil }
        var matches = Set<String>()
        for hint in hints where hint.hasPrefix("/") {
            let home = URL(fileURLWithPath: hint).standardizedFileURL.resolvingSymlinksInPath()
            let socket = home.appendingPathComponent("app-server-control/app-server-control.sock")
            var link = stat()
            guard lstat(socket.path, &link) == 0, link.st_uid == getuid(),
                  [mode_t(S_IFSOCK), mode_t(S_IFLNK)].contains(link.st_mode & S_IFMT) else { continue }
            let target = socket.resolvingSymlinksInPath().path
            var info = stat()
            guard lstat(target, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK,
                  paths.contains(target) else { continue }
            matches.insert(home.path)
        }
        return matches.count == 1 ? matches.first : nil
    }
    private struct UnixConnection {let socket:UInt64,peer:UInt64,path:String?}
    private static func connectedSocketPaths(pid:Int32,peerPID:Int32?) -> Set<String> {
        let clients=connections(pid:pid)
        var peers:[UInt64:UInt64]?
        if let peerPID {
            var owner=proc_bsdinfo()
            let size=Int32(MemoryLayout<proc_bsdinfo>.size)
            guard peerPID>0,proc_pidinfo(peerPID,PROC_PIDTBSDINFO,0,&owner,size)==size,owner.pbi_uid==getuid() else{return []}
            peers=[:]
            for value in connections(pid:peerPID) {peers?[value.socket]=value.peer}
        }
        return Set(clients.compactMap { value in
            guard let path=value.path,peers == nil || peers?[value.peer]==value.socket else{return nil}
            return path
        })
    }
    private static func connections(pid: Int32) -> [UnixConnection] {
        let required = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        let entrySize = MemoryLayout<proc_fdinfo>.size
        guard required > 0, required <= 131_072 else { return [] }
        var entries = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(required) / entrySize + 16)
        let count = entries.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        var sockets:[UnixConnection]=[]
        for entry in entries.prefix(Int(count) / entrySize) where entry.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, Int32(entry.proc_fd), PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_family == AF_UNIX,
                  Int(info.psi.soi_state) & Int(SOI_S_ISCONNECTED) != 0,
                  Int(info.psi.soi_state) & Int(SOI_S_ISDISCONNECTED | SOI_S_ISDISCONNECTING | SOI_S_CANTSENDMORE | SOI_S_CANTRCVMORE) == 0,
                  info.psi.soi_so != 0,info.psi.soi_proto.pri_un.unsi_conn_so != 0 else { continue }
            let path: String? = withUnsafeBytes(of: info.psi.soi_proto.pri_un.unsi_caddr.ua_sun.sun_path) { bytes in
                guard bytes.first == 47, let end = bytes.firstIndex(of: 0) else { return nil }
                return String(decoding: bytes[..<end], as: UTF8.self)
            }
            sockets.append(.init(socket:info.psi.soi_so,peer:info.psi.soi_proto.pri_un.unsi_conn_so,
                path:path.map{URL(fileURLWithPath:$0).resolvingSymlinksInPath().path}))
        }
        return sockets
    }
}
