import Foundation
import Darwin

/// Accept a launch home only when the original process is connected to its
/// exact user-owned control socket. Never guess by project or recent history.
public enum CodexServerLocation {
    public static func connectedHome(pid: Int32, hints: [String]) -> String? {
        let paths = connectedSocketPaths(pid: pid)
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
    private static func connectedSocketPaths(pid: Int32) -> Set<String> {
        let required = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        let entrySize = MemoryLayout<proc_fdinfo>.size
        guard required > 0, required <= 131_072 else { return [] }
        var entries = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(required) / entrySize + 16)
        let count = entries.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        var paths = Set<String>()
        for entry in entries.prefix(Int(count) / entrySize) where entry.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, Int32(entry.proc_fd), PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_family == AF_UNIX else { continue }
            let path: String? = withUnsafeBytes(of: info.psi.soi_proto.pri_un.unsi_caddr.ua_sun.sun_path) { bytes in
                guard bytes.first == 47, let end = bytes.firstIndex(of: 0) else { return nil }
                return String(decoding: bytes[..<end], as: UTF8.self)
            }
            if let path { paths.insert(URL(fileURLWithPath: path).resolvingSymlinksInPath().path) }
        }
        return paths
    }
}
