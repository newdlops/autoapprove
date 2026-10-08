import Foundation
import Darwin
import CLocalDashboard

/// A per-Mac loopback name. It is never advertised as another Mac's LAN address.
public enum LocalDashboardAddress {
    public static let hostname = "autoapprove"
    public static let hostsPath = "/private/etc/hosts"
    public static let marker = "# AutoApprove local dashboard"
    public static func url(port: UInt16 = 8765) -> URL { URL(string:"http://autoapprove:\(port)")! }

    public enum Status: Equatable {
        case ready, missing, conflict, unavailable
        public var detail: String {
            switch self {
            case .ready: return "이 주소는 항상 이 Mac의 관리 페이지를 엽니다."
            case .missing: return "처음 한 번 Mac 관리자 승인을 받으면 IP가 바뀌어도 같은 주소로 엽니다."
            case .conflict: return "autoapprove에 다른 주소가 설정돼 있습니다. 기존 설정을 확인해주세요."
            case .unavailable: return "Mac의 로컬 주소 설정을 읽지 못했습니다. 다시 확인해주세요."
            }
        }
    }
    public static func status(in text: String) -> Status {
        var found = false
        for line in text.components(separatedBy:.newlines) {
            let fields = line.split(separator:"#",maxSplits:1,omittingEmptySubsequences:false)[0].split(whereSeparator:{$0.isWhitespace})
            guard fields.count > 1, fields.dropFirst().contains(where:{
                let name = $0.lowercased(); return (name.hasSuffix(".") ? String(name.dropLast()) : name) == hostname
            }) else {continue}
            found = true
            let address = String(fields[0])
            if address != "::1" && address != "127.0.0.1" { return .conflict }
        }
        return found ? .ready : .missing
    }
    public static func status() -> Status {
        guard let data = try? Data(contentsOf:URL(fileURLWithPath:hostsPath)), data.count <= 1_048_576,
              let text = String(data:data,encoding:.utf8) else {return .unavailable}
        return status(in:text)
    }
    public static func prepared(_ text: String) throws -> String {
        guard text.utf8.count <= 1_048_576 else {throw AppError.message("Mac 주소 설정 파일이 너무 큽니다.")}
        switch status(in:text) {
        case .ready: return text
        case .conflict: throw AppError.message(Status.conflict.detail)
        case .unavailable: throw AppError.message(Status.unavailable.detail)
        case .missing: break
        }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        return text + (text.isEmpty || text.hasSuffix("\n") ? "" : newline)
            + [marker,"127.0.0.1 autoapprove","::1 autoapprove",""].joined(separator:newline)
    }

    /// Append only; retain the inode, owner, permissions, ACLs and all unrelated names.
    /// The CLI exposes only the fixed system path. Temporary paths are used by checks.
    public static func apply(to file: URL, backup: URL) throws {
        let fd = open(file.path,O_RDWR | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {throw AppError.message("로컬 주소 설정에 Mac 관리자 권한이 필요합니다.")}
        defer {close(fd)}
        try apply(descriptor:fd,backup:backup)
    }
    private static func apply(descriptor fd: Int32,backup: URL) throws {
        guard flock(fd,LOCK_EX | LOCK_NB) == 0 else {throw AppError.message("다른 프로그램이 주소 설정을 변경 중입니다. 잠시 뒤 다시 시도해주세요.")}
        defer {_ = flock(fd,LOCK_UN)}
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 1_048_576 else {throw AppError.message("Mac 주소 설정 파일을 확인하지 못했습니다.")}
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:false)
        let before = try handle.readToEnd() ?? Data()
        guard let text = String(data:before,encoding:.utf8) else {throw AppError.message("Mac 주소 설정 파일을 읽지 못했습니다.")}
        let updated = Data(try prepared(text).utf8)
        guard updated != before else {return}
        guard updated.starts(with:before) else {throw AppError.message("기존 주소를 유지할 수 없어 설정하지 않았습니다.")}
        // Backup before the first write; neither it nor the existing file is made less private.
        guard !FileManager.default.fileExists(atPath:backup.path) else {throw AppError.message("주소 설정 백업이 이미 있습니다. 기존 설정과 백업을 확인해주세요.")}
        let backupFD = open(backup.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard backupFD >= 0 else {throw AppError.message("기존 주소 설정을 백업하지 못했습니다.")}
        do {
            try write(before,to:backupFD); guard fsync(backupFD) == 0 else {throw AppError.message("주소 설정 백업을 저장하지 못했습니다.")}
            close(backupFD)
        } catch {close(backupFD); throw error}
        do {
            try write(Data(updated.dropFirst(before.count)),to:fd)
            guard fsync(fd) == 0 else {throw AppError.message("로컬 주소를 저장하지 못했습니다.")}
        } catch {
            _ = ftruncate(fd,off_t(before.count)); _ = fsync(fd); throw error
        }
    }
    private static func write(_ data: Data,to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
                if count < 0 && errno == EINTR {continue}
                guard count > 0 else {throw AppError.message("로컬 주소 설정을 저장하지 못했습니다.")}
                offset += count
            }
        }
    }
    public static func applySystem(backupDirectory: URL = AppPaths().directory.appendingPathComponent("local-address-backups")) throws {
        let descriptor = aa_open_dashboard_hosts(1)
        guard descriptor >= 0 else {throw AppError.message("Mac에서 주소 설정을 취소했거나 해당 파일의 관리자 승인을 받지 못했습니다.")}
        defer {close(descriptor)}
        try FileManager.default.createDirectory(at:backupDirectory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let backup = backupDirectory.appendingPathComponent("hosts-"+UUID().uuidString+".backup")
        try apply(descriptor:descriptor,backup:backup)
        let flushed = try CommandRunner.run("/usr/bin/dscacheutil",["-flushcache"],timeout:10)
        guard flushed.status == 0 else {throw AppError.message("주소는 저장됐지만 이름 캐시를 갱신하지 못했습니다. 다시 확인해주세요.")}
    }
    public static func configure(app: URL,backupDirectory: URL) throws {
        guard Bundle(url:app)?.bundleIdentifier == "local.autoapprove.mac" else {throw AppError.message("설치된 AutoApprove에서 로컬 주소를 설정해주세요.")}
        if status() == .ready {return}
        try applySystem(backupDirectory:backupDirectory)
        guard status() == .ready else {throw AppError.message("로컬 주소 설정 결과를 확인하지 못했습니다.")}
    }
}
