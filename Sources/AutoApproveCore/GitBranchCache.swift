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
        let branch: String?
        let detached: Bool
        let gitDirectory: String
        let commonDirectory: String
        let marker: Data?
        let commonMarker: Data?
        let head: Data
        let objectStore: [String: FileIdentity]?
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

    /// Verified entries are only grouping hints. Every participating read still
    /// resolves its own markers, and must reach the same common directory.
    static func collectionMetadata(directories: [String]) -> CollectionMetadata? {
        guard directories.count >= 3 else { return nil }
        var counts: [String: Int] = [:]
        lock.lock()
        for directory in directories {
            if let common = entries[directory]?.fingerprint.commonDirectory { counts[common, default: 0] += 1 }
        }
        lock.unlock()
        let shared = counts.filter { $0.value >= 3 }.keys.sorted().prefix(64)
        return shared.isEmpty ? nil : CollectionMetadata(commonDirectories: Array(shared))
    }

    /// One collect owns these snapshots. A slow loader never holds the lock or
    /// makes other readers wait; they can always use the original file reader.
    final class CollectionMetadata: @unchecked Sendable {
        private struct Snapshot { let identity: FileIdentity?; let data: Data? }
        private final class SharedConfig {
            let url: URL
            var loading = false, dirty = false
            var snapshot: Snapshot?
            var participants: Set<String> = []
            init(directory: String) {
                url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("config", isDirectory: false)
            }
        }
        private let lock = NSLock()
        private let configs: [String: SharedConfig]
        private var retainedBytes = 0, reusedReads = 0
        init(commonDirectories: [String]) {
            configs = Dictionary(uniqueKeysWithValues: commonDirectories.map { ($0, SharedConfig(directory: $0)) })
        }

        func config(commonDirectory: String, directory: String, url: URL) throws -> Data? {
            guard let entry = configs[commonDirectory] else { return try optionalFile(url, limit: 131072) }
            lock.lock()
            guard !entry.dirty, !entry.loading, entry.participants.count < 256 else {
                lock.unlock(); return try optionalFile(url, limit: 131072)
            }
            if let snapshot = entry.snapshot {
                lock.unlock()
                let current: FileIdentity?
                do { current = try fileIdentity(url) }
                catch {
                    markDirty(entry); return try optionalFile(url, limit: 131072)
                }
                lock.lock()
                guard !entry.dirty, current == snapshot.identity, entry.participants.count < 256 else {
                    if current != snapshot.identity { entry.dirty = true }
                    lock.unlock(); return try optionalFile(url, limit: 131072)
                }
                entry.participants.insert(directory); reusedReads += 1
                lock.unlock()
                return snapshot.data
            }
            entry.loading = true
            lock.unlock()
            do {
                let before = try fileIdentity(url)
                let data = try optionalFile(url, limit: 131072)
                let after = try fileIdentity(url)
                let size = data?.count ?? 0
                lock.lock()
                entry.loading = false
                guard before == after, (data == nil) == (after == nil), size <= 262144 - retainedBytes else {
                    entry.dirty = true
                    lock.unlock(); return try optionalFile(url, limit: 131072)
                }
                entry.snapshot = Snapshot(identity: after, data: data)
                entry.participants.insert(directory); retainedBytes += size
                lock.unlock()
                return data
            } catch {
                lock.lock(); entry.loading = false; entry.dirty = true; lock.unlock()
                throw error
            }
        }

        private func markDirty(_ entry: SharedConfig) {
            lock.lock(); entry.dirty = true; lock.unlock()
        }

        /// Runs after all readers finish, off the UI. Identity alone is never
        /// sufficient to finish a collect that reused common config bytes.
        func invalidatedDirectories() -> Set<String> {
            var invalid: Set<String> = []
            // No workers remain. The snapshot and participant sets are now
            // immutable; no lock spans these fresh descriptor reads.
            for entry in configs.values where !entry.participants.isEmpty {
                guard !entry.dirty, let snapshot = entry.snapshot else {
                    invalid.formUnion(entry.participants); continue
                }
                do {
                    let before = try fileIdentity(entry.url)
                    let data = try optionalFile(entry.url, limit: 131072)
                    let after = try fileIdentity(entry.url)
                    if before != after || after != snapshot.identity || data != snapshot.data {
                        invalid.formUnion(entry.participants)
                    }
                } catch { invalid.formUnion(entry.participants) }
            }
            return invalid
        }

        func metrics() -> GitBranchCollectionMetadataMetrics {
            lock.lock(); defer { lock.unlock() }
            return .init(retainedConfigBytes: retainedBytes, retainedConfigs: configs.values.filter { $0.snapshot != nil }.count,
                         participants: configs.values.reduce(0) { $0 + $1.participants.count },
                         maximumParticipants: configs.values.map { $0.participants.count }.max() ?? 0,
                         reusedConfigReads: reusedReads)
        }
    }

    /// 같은 폴더의 HEAD·참조·설정이 마지막 확인 때와 같으면 검증된 브랜치 상태를 반환한다.
    static func value(directory: String, fingerprint: Fingerprint?) -> GitBranchState? {
        guard let fingerprint else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[directory], entry.fingerprint == fingerprint else { return nil }
        return entry.state
    }

    /// Git 실행 도중 메타데이터가 바뀌지 않은 브랜치 또는 detached HEAD만 저장한다.
    static func store(_ state: GitBranchState, directory: String, before: Fingerprint?) {
        guard let before,
              let fullHead = String(data: before.head, encoding: .utf8)?.trimmingCharacters(in: .newlines),
              (state.kind == .branch && !before.detached && state.name == before.branch) ||
                (state.kind == .detached && before.detached && before.branch == nil &&
                    state.name.map { fullHead.hasPrefix($0) } == true),
              fingerprint(directory: directory) == before else { return }
        lock.lock(); defer { lock.unlock() }
        if entries.count >= 256, entries[directory] == nil { entries.removeAll(keepingCapacity: true) }
        entries[directory] = Entry(fingerprint: before, state: state)
    }

    /// 저장소 루트와 연결된 worktree의 작은 메타데이터만 읽는다. 알 수 없는 구조는 Git에 맡긴다.
    static func fingerprint(directory: String, metadata: CollectionMetadata? = nil) -> Fingerprint? {
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
            // Metadata leaves have a known file role. Skip URL's directory
            // inference; the descriptor/type checks below remain authoritative.
            let commonMarker = try optionalFile(gitDirectory.appendingPathComponent("commondir", isDirectory: false), limit: 4096)
            let commonDirectory: URL
            if let commonMarker {
                guard let path = String(data: commonMarker, encoding: .utf8) else { return nil }
                commonDirectory = resolve(path, relativeTo: gitDirectory)
            } else { commonDirectory = gitDirectory }
            func config() throws -> Data? {
                let url = commonDirectory.appendingPathComponent("config", isDirectory: false)
                if let metadata { return try metadata.config(commonDirectory: commonDirectory.path, directory: directory, url: url) }
                return try optionalFile(url, limit: 131072)
            }
            let head = try smallFile(gitDirectory.appendingPathComponent("HEAD", isDirectory: false), limit: 4096)
            guard let rawHead = String(data: head, encoding: .utf8) else { return nil }
            let headValue = rawHead.trimmingCharacters(in: .newlines)
            let branch: String?, detached: Bool
            if headValue.hasPrefix("ref: refs/heads/") {
                let name = String(headValue.dropFirst("ref: refs/heads/".count))
                guard !name.isEmpty, !name.contains("\0"), !name.contains(".."), !name.contains("\n"), !name.contains("\r") else { return nil }
                branch = name; detached = false
            } else if !headValue.hasPrefix("ref:"), [40, 64].contains(headValue.utf8.count), headValue.allSatisfy(\.isHexDigit) {
                branch = nil; detached = true
            } else { return nil }
            if detached {
                // Retain config identity because invalid repository format or
                // extensions must continue to surface Git's diagnostic result.
                guard let objectStore = try objectStoreIdentity(gitDirectory.appendingPathComponent("objects", isDirectory: true)) else { return nil }
                return Fingerprint(branch: nil, detached: true, gitDirectory: gitDirectory.path, commonDirectory: commonDirectory.path,
                    marker: marker, commonMarker: commonMarker, head: head, objectStore: objectStore, looseReference: nil,
                    packedReferences: try fileIdentity(commonDirectory.appendingPathComponent("packed-refs", isDirectory: false)),
                    config: try config(),
                    worktreeConfig: try optionalFile(gitDirectory.appendingPathComponent("config.worktree", isDirectory: false), limit: 131072))
            }
            guard let branch else { return nil }
            let looseReference = try optionalFile(commonDirectory.appendingPathComponent("refs/heads/" + branch, isDirectory: false), limit: 4096)
            return Fingerprint(branch: branch, detached: detached, gitDirectory: gitDirectory.path, commonDirectory: commonDirectory.path,
                marker: marker, commonMarker: commonMarker, head: head, objectStore: nil, looseReference: looseReference,
                packedReferences: try fileIdentity(commonDirectory.appendingPathComponent("packed-refs", isDirectory: false)),
                config: try config(),
                worktreeConfig: try optionalFile(gitDirectory.appendingPathComponent("config.worktree", isDirectory: false), limit: 131072))
        } catch { return nil }
    }

    /// gitdir·commondir의 상대 경로와 줄바꿈을 처리하되 경로 안의 공백은 보존한다.
    private static func resolve(_ path: String, relativeTo parent: URL) -> URL {
        let value = path.trimmingCharacters(in: .newlines)
        return (value.hasPrefix("/") ? URL(fileURLWithPath: value, isDirectory: true) : parent.appendingPathComponent(value, isDirectory: true))
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

    /// Detached abbreviations are unique within the object database. Track its
    /// shallow directory entries so new loose objects or packs invalidate them.
    /// Alternates can change elsewhere, so repositories using them stay uncached.
    private static func objectStoreIdentity(_ objects: URL) throws -> [String: FileIdentity]? {
        let alternates = objects.appendingPathComponent("info/alternates", isDirectory: false)
        var alternateInfo = stat()
        if lstat(alternates.path, &alternateInfo) == 0 { return nil }
        guard errno == ENOENT else { throw MetadataError.unreadable }
        let names = try FileManager.default.contentsOfDirectory(atPath: objects.path)
        var result: [String: FileIdentity] = [:]
        func add(_ url: URL, key: String) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw MetadataError.unreadable }
            guard info.st_mode & S_IFMT == S_IFDIR || info.st_mode & S_IFMT == S_IFREG else { throw MetadataError.unreadable }
            result[key] = FileIdentity(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
        }
        for name in names.sorted() {
            let url = objects.appendingPathComponent(name)
            try add(url, key: name)
            if name == "pack" {
                for child in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
                    try add(url.appendingPathComponent(child), key: "pack/" + child)
                }
            }
        }
        return result
    }
}
