import Foundation
import Darwin

/// Git으로 확인한 브랜치 이름을 메타데이터가 그대로인 동안 재사용해 주기적인 프로세스 생성을 줄인다.
enum GitBranchCache {
    struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
    }
    private enum MetadataError: Error { case missing, unreadable, tooLarge }
    struct Fingerprint: Equatable {
        let branch: String
        let gitDirectory: String
        let commonDirectory: String
        let marker: Data?
        let commonMarker: Data?
        let head: Data
        let looseReference: Data?
        let packedReferences: FileIdentity?
        let config: Data?
        let worktreeConfig: Data?
    }

    private struct Entry {
        let fingerprint: Fingerprint
        let state: GitBranchState
    }
    private static let lock = NSLock()
    private static var entries: [String: Entry] = [:]

    /// 같은 폴더의 HEAD·참조·설정이 마지막 확인 때와 같으면 검증된 브랜치 상태를 반환한다.
    static func value(directory: String, fingerprint: Fingerprint?) -> GitBranchState? {
        guard let fingerprint else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[directory], entry.fingerprint == fingerprint else { return nil }
        return entry.state
    }

    /// Git 실행 도중 메타데이터가 바뀌지 않은 일반 브랜치만 저장하며 항목 수를 제한한다.
    static func store(_ state: GitBranchState, directory: String, before: Fingerprint?) {
        guard state.kind == .branch, let before, state.name == before.branch,
              fingerprint(directory: directory) == before else { return }
        lock.lock(); defer { lock.unlock() }
        if entries.count >= 256, entries[directory] == nil { entries.removeAll(keepingCapacity: true) }
        entries[directory] = Entry(fingerprint: before, state: state)
    }

    /// 저장소 루트와 연결된 worktree의 작은 메타데이터만 읽는다. 알 수 없는 구조는 Git에 맡긴다.
    static func fingerprint(directory: String) -> Fingerprint? {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        let markerURL = root.appendingPathComponent(".git")
        guard manager.fileExists(atPath: markerURL.path, isDirectory: &isDirectory) else { return nil }
        do {
            let marker: Data?
            let gitDirectory: URL
            if isDirectory.boolValue {
                marker = nil
                gitDirectory = markerURL.resolvingSymlinksInPath()
            } else {
                let data = try smallFile(markerURL, limit: 4096)
                guard let line = String(data: data, encoding: .utf8), line.hasPrefix("gitdir: ") else { return nil }
                marker = data
                gitDirectory = resolve(String(line.dropFirst(8)), relativeTo: root)
            }
            let commonMarker = try optionalFile(gitDirectory.appendingPathComponent("commondir"), limit: 4096)
            let commonDirectory: URL
            if let commonMarker {
                guard let path = String(data: commonMarker, encoding: .utf8) else { return nil }
                commonDirectory = resolve(path, relativeTo: gitDirectory)
            } else { commonDirectory = gitDirectory }
            let head = try smallFile(gitDirectory.appendingPathComponent("HEAD"), limit: 4096)
            guard let rawHead = String(data: head, encoding: .utf8), rawHead.hasPrefix("ref: refs/heads/") else { return nil }
            let branch = String(rawHead.dropFirst("ref: refs/heads/".count)).trimmingCharacters(in: .newlines)
            guard !branch.isEmpty, !branch.contains("\0"), !branch.contains(".."), !branch.contains("\n"), !branch.contains("\r") else { return nil }
            return Fingerprint(branch: branch, gitDirectory: gitDirectory.path, commonDirectory: commonDirectory.path,
                marker: marker, commonMarker: commonMarker, head: head,
                looseReference: try optionalFile(commonDirectory.appendingPathComponent("refs/heads/" + branch), limit: 4096),
                packedReferences: try fileIdentity(commonDirectory.appendingPathComponent("packed-refs")),
                config: try optionalFile(commonDirectory.appendingPathComponent("config"), limit: 131072),
                worktreeConfig: try optionalFile(gitDirectory.appendingPathComponent("config.worktree"), limit: 131072))
        } catch { return nil }
    }

    /// gitdir·commondir의 상대 경로와 줄바꿈을 처리하되 경로 안의 공백은 보존한다.
    private static func resolve(_ path: String, relativeTo parent: URL) -> URL {
        let value = path.trimmingCharacters(in: .newlines)
        return (value.hasPrefix("/") ? URL(fileURLWithPath: value) : parent.appendingPathComponent(value))
            .standardizedFileURL.resolvingSymlinksInPath()
    }

    /// 비정상적으로 큰 메타데이터를 전부 읽지 않도록 상한보다 한 바이트까지만 읽는다.
    private static func smallFile(_ url: URL, limit: Int) throws -> Data {
        // Foundation attributes also query extended attributes. Only a regular
        // file and its bytes are needed, and the check must refer to the opened
        // descriptor. Nonblocking/no-follow prevents a replaced FIFO or symlink
        // from turning periodic metadata reads into a blocking operation.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw errno == ENOENT ? MetadataError.missing : .unreadable }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw MetadataError.unreadable }
        guard info.st_size <= limit else { throw MetadataError.tooLarge }
        var data = Data()
        data.reserveCapacity(max(0, Int(info.st_size)))
        return try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: min(8192, limit + 1)) { bytes in
            while data.count <= limit {
                let count = Darwin.read(descriptor, bytes.baseAddress, min(bytes.count, limit + 1 - data.count))
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw MetadataError.unreadable }
                if count == 0 { return data }
                data.append(bytes.baseAddress!, count: count)
            }
            throw MetadataError.tooLarge
        }
    }

    /// 없는 선택 파일과 읽기 실패를 구분해, 실패한 메타데이터를 캐시 적중으로 취급하지 않는다.
    private static func optionalFile(_ url: URL, limit: Int) throws -> Data? {
        do { return try smallFile(url, limit: limit) }
        catch MetadataError.missing { return nil }
    }

    /// 큰 packed-refs는 내용 대신 inode·수정 시각·크기를 비교해 갱신을 감지한다.
    private static func fileIdentity(_ url: URL) throws -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw MetadataError.unreadable
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw MetadataError.unreadable }
        return FileIdentity(device: info.st_dev, inode: info.st_ino, size: info.st_size,
            modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
            changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
    }
}
