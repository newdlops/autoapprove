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
        guard !text.isEmpty else {return .missing}
        let utf8 = text.utf8
        if let result = utf8.withContiguousStorageIfAvailable({ bytes -> Status in
            var found = false, start = 0, index = 0, ascii = true
            while index < bytes.count {
                let width: Int
                let byte = bytes[index]
                if byte >= 10 && byte <= 13 {width = 1}
                else if byte == 0xc2 && index + 1 < bytes.count && bytes[index + 1] == 0x85 {width = 2}
                else if byte == 0xe2 && index + 2 < bytes.count && bytes[index + 1] == 0x80,
                        bytes[index + 2] == 0xa8 || bytes[index + 2] == 0xa9 {width = 3}
                else {if byte >= 0x80 {ascii = false};index += 1;continue}
                if start < index {
                    let line: Status
                    if ascii {line = asciiLineStatus(bytes,start:start,end:index)}
                    else {
                        let first = utf8.index(utf8.startIndex,offsetBy:start),last = utf8.index(utf8.startIndex,offsetBy:index)
                        line = lineStatus(text[first..<last])
                    }
                    if line == .conflict {return .conflict}
                    if line == .ready {found = true}
                }
                index += width;start = index;ascii = true
            }
            if start < bytes.count {
                let line: Status
                if ascii {line = asciiLineStatus(bytes,start:start,end:bytes.count)}
                else {
                    let first = utf8.index(utf8.startIndex,offsetBy:start)
                    line = lineStatus(text[first..<text.endIndex])
                }
                if line == .conflict {return .conflict}
                if line == .ready {found = true}
            }
            return found ? .ready : .missing
        }) {return result}
        // Foreign Cocoa storage stays UTF-16. Inspect one bounded block rather
        // than making a complete UTF-8 copy or retaining an array of every line.
        let cocoa = text as NSString, length = cocoa.length
        var buffer = [unichar](repeating:0,count:min(4096,length))
        return buffer.withUnsafeMutableBufferPointer { units in
            var found = false, start = 0, offset = 0
            while offset < length {
                let count = min(units.count,length-offset)
                cocoa.getCharacters(units.baseAddress!,range:NSRange(location:offset,length:count))
                for position in 0..<count {
                    let unit = units[position]
                    guard (unit >= 10 && unit <= 13) || unit == 0x85 || unit == 0x2028 || unit == 0x2029 else {continue}
                    let end = offset + position
                    if start < end {
                        let first = String.Index(utf16Offset:start,in:text),last = String.Index(utf16Offset:end,in:text)
                        let line = lineStatus(text[first..<last])
                        if line == .conflict {return .conflict}
                        if line == .ready {found = true}
                    }
                    start = end + 1
                }
                offset += count
            }
            if start < length {
                let first = String.Index(utf16Offset:start,in:text)
                let line = lineStatus(text[first..<text.endIndex])
                if line == .conflict {return .conflict}
                if line == .ready {found = true}
            }
            return found ? .ready : .missing
        }
    }
    private static func asciiLineStatus(_ bytes: UnsafeBufferPointer<UInt8>,start: Int,end: Int) -> Status {
        // Every byte in this line is ASCII, so tabs/spaces and '#' have exactly
        // the released Character semantics. Non-ASCII lines use lineStatus.
        var index = start
        func token() -> Range<Int>? {
            while index < end, bytes[index] == 9 || bytes[index] == 32 {index += 1}
            guard index < end, bytes[index] != 35 else {return nil}
            let first = index
            while index < end, bytes[index] != 9, bytes[index] != 32, bytes[index] != 35 {index += 1}
            return first..<index
        }
        guard let address = token() else {return .missing}
        while let field = token() {
            let last = bytes[field.upperBound-1] == 46 ? field.upperBound-1 : field.upperBound
            guard last-field.lowerBound == 11 else {continue}
            var matches = true
            for (offset,expected) in "autoapprove".utf8.enumerated() {
                let byte = bytes[field.lowerBound+offset]
                if (byte >= 65 && byte <= 90 ? byte+32 : byte) != expected {matches = false;break}
            }
            guard matches else {continue}
            if address.count == 3, bytes[address.lowerBound] == 58,
               bytes[address.lowerBound+1] == 58, bytes[address.lowerBound+2] == 49 {return .ready}
            if address.count == 9 {
                for (offset,expected) in "127.0.0.1".utf8.enumerated() {
                    if bytes[address.lowerBound+offset] != expected {return .conflict}
                }
                return .ready
            }
            return .conflict
        }
        return .missing
    }
    private static func lineStatus(_ line: Substring) -> Status {
        // Keep Character-based whitespace and comment matching. A combining
        // mark after '#' must retain exactly the released parser's meaning.
        let end = line.firstIndex(of:"#") ?? line.endIndex, body = line[..<end]
        var index = body.startIndex
        func token() -> Substring? {
            while index < end, body[index].isWhitespace {body.formIndex(after:&index)}
            guard index < end else {return nil}
            let start = index
            while index < end, !body[index].isWhitespace {body.formIndex(after:&index)}
            return body[start..<index]
        }
        guard let address = token() else {return .missing}
        while let field = token() {
            let name = field.lowercased()
            if (name.hasSuffix(".") ? String(name.dropLast()) : name) == hostname {
                return address == "::1" || address == "127.0.0.1" ? .ready : .conflict
            }
        }
        return .missing
    }
    public static func status() -> Status {
        // The live path is fixed. Keep every open/read/stat fresh without
        // reconstructing and decoding a URL for the same literal path.
        readStatus(descriptor:Darwin.open(hostsPath,O_RDONLY | O_CLOEXEC | O_NONBLOCK)).status
    }
    /// Counts only bytes read by this invocation; no contents or result survive
    /// it. The file argument also supports isolated library diagnostics.
    public struct StatusReading: Equatable {
        public let status: Status
        public let bytesRead: Int
    }
    public static let maximumStatusBytes = 1_048_576
    public static func readStatus(file: URL) -> StatusReading {
        guard file.isFileURL else {return StatusReading(status:.unavailable,bytesRead:0)}
        // Nonblocking open avoids waiting on a substituted FIFO. Follow normal
        // symlinks as before, then validate the opened object itself.
        let fd = file.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0,O_RDONLY | O_CLOEXEC | O_NONBLOCK) } ?? -1
        }
        return readStatus(descriptor:fd)
    }
    private static func readStatus(descriptor fd: Int32) -> StatusReading {
        guard fd >= 0 else {return StatusReading(status:.unavailable,bytesRead:0)}
        defer {_ = Darwin.close(fd)}
        var before = stat()
        guard fstat(fd,&before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= maximumStatusBytes else {
            return StatusReading(status:.unavailable,bytesRead:0)
        }
        // The extra byte detects growth even when it happens after fstat.
        // Every read shares this fixed allowance; neither memory nor I/O grows
        // with a concurrently growing file.
        let allowance = Int(before.st_size) + 1
        var data = Data(count:allowance), count = 0
        let succeeded = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else {return false}
            while count < allowance {
                let amount = Darwin.read(fd,base.advanced(by:count),allowance-count)
                if amount > 0 {count += amount}
                else if amount == 0 {return true}
                else if errno != EINTR {return false}
            }
            return true
        }
        var after = stat()
        guard succeeded, count == before.st_size, fstat(fd,&after) == 0,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else {
            return StatusReading(status:.unavailable,bytesRead:count)
        }
        data.count = count
        guard let text = String(data:data,encoding:.utf8) else {return StatusReading(status:.unavailable,bytesRead:count)}
        return StatusReading(status:status(in:text),bytesRead:count)
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
