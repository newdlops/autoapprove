import Foundation
import Darwin
import CryptoKit
import Security
import Network
import TerminalInputSupport

public struct LANUpdateStatus: Codable, Equatable, Sendable {
    public var enabled = true
    public var phase = "idle"
    public var detail = "같은 네트워크의 최신 버전을 자동으로 받습니다."
    public var version: String?
    public var progress: Int?
    public init() {}
}

public struct LANUpdateManifest: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var nodeID: String
    public var release: RemoteWebVersion
    public var architecture: String
    public var size: Int
    public var sha256: String
    public init(protocolVersion: Int = 1, nodeID: String, release: RemoteWebVersion, architecture: String = Self.architecture, size: Int, sha256: String) {
        self.protocolVersion = protocolVersion; self.nodeID = nodeID; self.release = release
        self.architecture = architecture; self.size = size; self.sha256 = sha256
    }
    public static let maximumSize = 32 * 1_024 * 1_024
    public static let chunkSize = 256 * 1_024
    public static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    public func validate(nodeID: String, newerThan: RemoteWebVersion) throws {
        guard protocolVersion == 1, self.nodeID == nodeID, UUID(uuidString: nodeID) != nil,
              release.isCompatible, release > newerThan, architecture == Self.architecture,
              size > 0, size <= Self.maximumSize,
              sha256.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw AppError.message("호환되는 최신 AutoApprove 업데이트가 아닙니다.")
        }
    }
}

/// Only the installed, signed application is offered. Preferences, transcripts,
/// helper-service state and signing keychains never enter this archive.
actor LANUpdateArchive {
    private let directory: URL
    private let nodeID: String
    private var building: Task<(LANUpdateManifest, URL), Error>?
    init(directory: URL, nodeID: String) { self.directory = directory; self.nodeID = nodeID }
    func offer() async throws -> (LANUpdateManifest, URL) {
        if let building { return try await building.value }
        let directory = directory, nodeID = nodeID
        let task = Task.detached(priority: .utility) {
            let app = try LANUpdateInstallation.currentApp()
            let release = try LANUpdateInstallation.release(app)
            try LANUpdateInstallation.verifyPublisher(app)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let archive = directory.appendingPathComponent("offer.zip")
            let result = try CommandRunner.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--keepParent", app.path, archive.path], timeout: 90)
            guard result.status == 0 else { throw AppError.message("업데이트 파일을 준비하지 못했습니다.") }
            let data = try Data(contentsOf: archive, options: .mappedIfSafe)
            guard data.count > 0, data.count <= LANUpdateManifest.maximumSize else { throw AppError.message("업데이트 파일이 너무 큽니다.") }
            try LANUpdateInstallation.validateArchive(data)
            return (LANUpdateManifest(protocolVersion: 1, nodeID: nodeID, release: release,
                architecture: LANUpdateManifest.architecture, size: data.count, sha256: LANUpdateInstallation.digest(data)), archive)
        }
        building = task
        do { return try await task.value }
        catch { building = nil; throw error }
    }
    func chunk(hash: String, offset: Int) async throws -> Data {
        let (manifest, file) = try await offer()
        guard hash == manifest.sha256, offset >= 0, offset < manifest.size,
              offset % LANUpdateManifest.chunkSize == 0 else { throw RemoteHTTPError(409, "업데이트 파일이 바뀌었습니다. 다시 확인해주세요.") }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: min(LANUpdateManifest.chunkSize, manifest.size - offset)) ?? Data()
    }
}

public enum LANUpdateInstallation {
    public static func currentApp() throws -> URL {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app", try release(app).isCompatible else { throw AppError.message("설치된 AutoApprove 앱에서만 자동 업데이트를 사용할 수 있습니다.") }
        return app
    }
    public static func release(_ app: URL) throws -> RemoteWebVersion {
        let file = app.appendingPathComponent("Contents/Info.plist")
        guard let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? JSONObject,
              object["CFBundleIdentifier"] as? String == "local.autoapprove.mac",
              object["CFBundleExecutable"] as? String == "AutoApproveApp",
              let version = object["CFBundleShortVersionString"] as? String,
              let build = object["CFBundleVersion"] as? String, let number = Int(build) else { throw AppError.message("AutoApprove 설치 정보를 확인하지 못했습니다.") }
        let result = RemoteWebVersion(version: version, build: number)
        guard result.isCompatible else { throw AppError.message("AutoApprove 버전 정보를 확인하지 못했습니다.") }
        let web = app.appendingPathComponent("Contents/Resources/AutoApprove_AutoApproveCore.bundle/RemoteWeb/web-version.json")
        guard try JSONDecoder().decode(RemoteWebVersion.self, from: Data(contentsOf: web)) == result else { throw AppError.message("앱과 웹 리소스의 버전이 다릅니다.") }
        return result
    }
    public static func verifyPublisher(_ app: URL) throws {
        let text = try TTYInputSigning.peerRequirements(ownIdentifiers: ["local.autoapprove.mac", "local.autoapprove.helper"], peerIdentifiers: ["local.autoapprove.mac"])
        var requirement: SecRequirement?, code: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw AppError.message("현재 설치본과 같은 게시자 서명인지 확인하지 못해 업데이트를 중단했습니다.")
        }
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Validate the complete central directory before invoking the OS extractor.
    /// Reject links, traversal, alternate Unicode paths, ZIP64 and oversized output.
    public static func validateArchive(_ data: Data) throws {
        func invalid() -> AppError { .message("안전한 AutoApprove 업데이트 압축 파일이 아닙니다.") }
        func uint(_ offset: Int, _ size: Int) throws -> UInt64 {
            guard offset >= 0, size > 0, offset <= data.count - size else { throw invalid() }
            return (0..<size).reduce(0) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
        }
        guard data.count >= 22, data.count <= LANUpdateManifest.maximumSize else { throw invalid() }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if try uint(offset, 4) == 0x06054b50, offset + 22 + Int(try uint(offset + 20, 2)) == data.count { end = offset; break }
        }
        guard let end, try uint(end + 4, 2) == 0, try uint(end + 6, 2) == 0,
              try uint(end + 8, 2) == uint(end + 10, 2) else { throw invalid() }
        let count = Int(try uint(end + 10, 2)), size = Int(try uint(end + 12, 4)), start = Int(try uint(end + 16, 4))
        guard count > 0, count <= 4_096, start >= 0, size > 0, start + size == end else { throw invalid() }
        var cursor = start, output: UInt64 = 0, names = Set<String>(), localRanges: [Range<Int>] = []
        for _ in 0..<count {
            guard try uint(cursor, 4) == 0x02014b50 else { throw invalid() }
            let flags = try uint(cursor + 8, 2), method = try uint(cursor + 10, 2)
            let packed = Int(try uint(cursor + 20, 4)), unpacked = try uint(cursor + 24, 4)
            let length = Int(try uint(cursor + 28, 2)), extra = Int(try uint(cursor + 30, 2)), comment = Int(try uint(cursor + 32, 2))
            let mode = (try uint(cursor + 38, 4) >> 16) & 0xf000, local = Int(try uint(cursor + 42, 4))
            let next = cursor + 46 + length + extra + comment
            guard flags & 1 == 0, [UInt64(0), 8].contains(method), try uint(cursor + 34, 2) == 0,
                  [UInt64(0), 0x8000, 0x4000].contains(mode), next <= end, length > 0,
                  let name = String(data: data[(cursor + 46)..<(cursor + 46 + length)], encoding: .utf8),
                  !name.contains("\\"), !name.contains("\0"), !name.hasPrefix("/"),
                  name.split(separator: "/", omittingEmptySubsequences: false).dropLast(name.hasSuffix("/") ? 1 : 0).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  name == "AutoApprove.app/" || name.hasPrefix("AutoApprove.app/"),
                  names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw invalid() }
            output += unpacked
            guard output <= 128 * 1_024 * 1_024, unpacked <= 64 * 1_024 * 1_024 else { throw invalid() }
            var extraCursor = cursor + 46 + length
            while extraCursor < cursor + 46 + length + extra {
                let id = try uint(extraCursor, 2), bytes = Int(try uint(extraCursor + 2, 2))
                guard [UInt64(0x5855), 0x5455, 0x7875].contains(id), extraCursor + 4 + bytes <= cursor + 46 + length + extra else { throw invalid() }
                extraCursor += 4 + bytes
            }
            guard try uint(local, 4) == 0x04034b50, try uint(local + 6, 2) == flags, try uint(local + 8, 2) == method,
                  try uint(local + 26, 2) == UInt64(length) else { throw invalid() }
            let payload = local + 30 + length + Int(try uint(local + 28, 2))
            guard local >= 0, payload <= start, packed <= start - payload,
                  data[(local + 30)..<(local + 30 + length)] == data[(cursor + 46)..<(cursor + 46 + length)] else { throw invalid() }
            var localExtra = local + 30 + length
            while localExtra < payload {
                let id = try uint(localExtra, 2), bytes = Int(try uint(localExtra + 2, 2))
                guard [UInt64(0x5855), 0x5455, 0x7875].contains(id), localExtra + 4 + bytes <= payload else { throw invalid() }
                localExtra += 4 + bytes
            }
            localRanges.append(local..<(payload + packed)); cursor = next
        }
        let ranges = localRanges.sorted { $0.lowerBound < $1.lowerBound }
        guard cursor == end, zip(ranges, ranges.dropFirst()).allSatisfy({ $0.upperBound <= $1.lowerBound }),
              names.contains("autoapprove.app/contents/info.plist"), names.contains("autoapprove.app/contents/macos/autoapproveapp") else { throw invalid() }
    }

    public struct Job: Codable, Sendable {
        public var app: String
        public var candidate: String
        public var managerPID: Int32
        public var managerStarted: String
        public var release: RemoteWebVersion
        public var nodeID: String
        public var port: UInt16
        public var directory: String
        public var home: String
    }
    public static func stage(archive: URL, manifest: LANUpdateManifest, directory: URL) throws -> URL {
        let bytes = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard bytes.count == manifest.size, digest(bytes) == manifest.sha256 else { throw AppError.message("업데이트 파일의 체크섬이 일치하지 않습니다.") }
        try validateArchive(bytes)
        let result = try CommandRunner.run("/usr/bin/ditto", ["-x", "-k", "--norsrc", archive.path, directory.path], timeout: 90)
        guard result.status == 0 else { throw AppError.message("업데이트 파일을 풀지 못했습니다.") }
        let candidate = directory.appendingPathComponent("AutoApprove.app")
        try verifyPublisher(candidate)
        guard try release(candidate) == manifest.release else { throw AppError.message("파일과 안내된 업데이트 버전이 다릅니다.") }
        // Signature covers this file and every helper; the current OS must satisfy the bundle minimum.
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: candidate.appendingPathComponent("Contents/Info.plist")), format: nil) as? JSONObject
        let os = ProcessInfo.processInfo.operatingSystemVersion
        guard let minimum = plist?["LSMinimumSystemVersion"] as? String,
              minimum.compare("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", options: .numeric) != .orderedDescending else {
            throw AppError.message("이 macOS 버전에서는 업데이트를 실행할 수 없습니다.")
        }
        let architectures = try CommandRunner.run("/usr/bin/lipo", ["-archs", candidate.appendingPathComponent("Contents/MacOS/AutoApproveApp").path])
        guard architectures.status == 0, architectures.output.split(whereSeparator: \.isWhitespace).contains(Substring(LANUpdateManifest.architecture)) else { throw AppError.message("이 Mac과 다른 종류의 설치 파일입니다.") }
        return candidate
    }

    /// A signed helper waits for a cooperative application quit. Never signal a
    /// user's CLI, replace a root service, request sudo or change privacy settings.
    public static func install(jobFile: URL) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: jobFile.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { throw AppError.message("업데이트 작업 파일을 확인하지 못했습니다.") }
        let job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: jobFile))
        let app = URL(fileURLWithPath: job.app), candidate = URL(fileURLWithPath: job.candidate), directory = URL(fileURLWithPath: job.directory)
        guard directory.standardizedFileURL.resolvingSymlinksInPath() == jobFile.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath(),
              directory.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == URL(fileURLWithPath: job.home).appendingPathComponent("updates").standardizedFileURL.resolvingSymlinksInPath(),
              candidate == directory.appendingPathComponent("AutoApprove.app"),
              app.pathExtension == "app", FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path),
              job.release.isCompatible, UUID(uuidString: job.nodeID) != nil else { throw AppError.message("업데이트 설치 경로를 확인하지 못했습니다.") }
        try verifyPublisher(app); try verifyPublisher(candidate)
        guard try release(candidate) == job.release, try release(app) < job.release,
              let manager = try ProcessDiscovery.read().first(where: { $0.pid == job.managerPID && $0.started == job.managerStarted }),
              manager.executable == app.appendingPathComponent("Contents/MacOS/AutoApproveApp").path else { throw AppError.message("업데이트할 AutoApprove 실행이 바뀌었습니다.") }
        try Data("ready".utf8).write(to: directory.appendingPathComponent("helper-ready"), options: .atomic)
        let deadline = Date().addingTimeInterval(40)
        while try ProcessDiscovery.read().contains(where: { $0.pid == job.managerPID && $0.started == job.managerStarted }) {
            guard Date() < deadline else { throw AppError.message("앱이 종료되지 않아 업데이트를 적용하지 않았습니다.") }
            try await Task.sleep(for: .milliseconds(250))
        }
        let reading = PowerControl.live.read()
        if reading.lidClosed {
            _ = try? CommandRunner.run("/usr/bin/open", [app.path])
            throw AppError.message("덮개가 닫혀 업데이트 적용을 멈추고 기존 AutoApprove를 다시 열었습니다.")
        }
        let parent = app.deletingLastPathComponent(), identifier = UUID().uuidString
        let staged = parent.appendingPathComponent(".AutoApprove-staged-\(identifier).app")
        let backup = parent.appendingPathComponent(".AutoApprove-backup-\(identifier).app")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: candidate, to: staged); try verifyPublisher(staged)
        try FileManager.default.moveItem(at: app, to: backup)
        do {
            try FileManager.default.moveItem(at: staged, to: app)
            let opened = try CommandRunner.run("/usr/bin/open", ["-n", app.path])
            guard opened.status == 0 else { throw AppError.message("업데이트한 앱을 열지 못했습니다.") }
            let healthyUntil = Date().addingTimeInterval(40)
            while Date() < healthyUntil {
                // The normal busy-port fallback may choose a new port on restart.
                // Read the same installation's private control socket, then verify
                // the exact node and release at its actual current HTTP listener.
                let web = try? SocketClient.request(path: AppPaths(directory: URL(fileURLWithPath: job.home)).socket, message: ["method": "web"])
                let port = (web?["port"] as? Int).flatMap(UInt16.init(exactly:)) ?? job.port
                if let response = try? await RemoteHTTPExchange(endpoint: RemoteNetworkAddress.endpoint("http://127.0.0.1:\(port)"),
                    path: "/api/discovery", method: "GET", body: Data(), expectedNodeID: job.nodeID, timeout: 2).run(),
                   response.status == 200, let object = try? JSONSerialization.jsonObject(with: response.body) as? JSONObject,
                   object["id"] as? String == job.nodeID, let releaseObject = object["release"],
                   let observed = try? JSONDecoder().decode(RemoteWebVersion.self, from: JSONSerialization.data(withJSONObject: releaseObject)), observed == job.release {
                    try? FileManager.default.removeItem(at: backup)
                    try? FileManager.default.removeItem(at: directory)
                    return
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw AppError.message("업데이트 후 웹 연결을 확인하지 못했습니다.")
        } catch {
            // Leave a running new manager intact; replacing its executable is unsafe.
            let live = (try? ProcessDiscovery.read())?.contains { $0.executable == app.appendingPathComponent("Contents/MacOS/AutoApproveApp").path } ?? true
            if !live {
                try? FileManager.default.removeItem(at: app)
                try FileManager.default.moveItem(at: backup, to: app)
                _ = try? CommandRunner.run("/usr/bin/open", [app.path])
            }
            throw error
        }
    }
}

@MainActor final class LANUpdateReceiver {
    private weak var engine: ApprovalEngine?
    private let app: URL?
    private var task: Task<Void, Never>?
    private var retryAfter = Date.distantPast
    private var staged: (LANUpdateManifest, URL, URL)?
    private var applying = false
    init(engine: ApprovalEngine) { self.engine = engine; app = try? LANUpdateInstallation.currentApp() }
    deinit { if !applying, let staged { try? FileManager.default.removeItem(at: staged.1) } }
    func stop() { task?.cancel() }
    func check(endpoint: NWEndpoint, nodeID: String, release: RemoteWebVersion) {
        guard let engine, engine.lanUpdate.enabled, let app, let current = RemoteWebVersion.current,
              release > current, task == nil, Date() >= retryAfter else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            var incoming: URL?
            do {
                if self.staged?.0.release != release || self.staged?.0.nodeID != nodeID {
                    if let previous = self.staged { try? FileManager.default.removeItem(at: previous.1) }; self.staged = nil
                    self.status("checking", "최신 Mac의 업데이트를 확인하고 있습니다.", version: release.version)
                    let offered = try await RemoteHTTPExchange(endpoint: endpoint, path: "/api/update/manifest", method: "GET", body: Data(), expectedNodeID: nodeID).run()
                    guard offered.status == 200 else { throw AppError.message("이 Mac은 자동 업데이트 제공을 지원하지 않습니다. 첫 업데이트는 설치 파일로 적용해주세요.") }
                    let manifest = try JSONDecoder().decode(LANUpdateManifest.self, from: offered.body)
                    try manifest.validate(nodeID: nodeID, newerThan: current)
                    guard manifest.release == release else { throw AppError.message("Mac의 업데이트 버전이 바뀌었습니다.") }
                    let directory = engine.paths.directory.appendingPathComponent("updates/incoming-\(UUID().uuidString)")
                    incoming = directory
                    try? FileManager.default.removeItem(at: directory)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let archive = directory.appendingPathComponent("update.zip")
                    FileManager.default.createFile(atPath: archive.path, contents: nil, attributes: [.posixPermissions: 0o600])
                    let handle = try FileHandle(forWritingTo: archive)
                    defer { try? handle.close() }
                    for offset in stride(from: 0, to: manifest.size, by: LANUpdateManifest.chunkSize) {
                        try Task.checkCancellation()
                        guard engine.lanUpdate.enabled else { throw CancellationError() }
                        self.status("downloading", "최신 버전을 받고 있습니다.", version: release.version, progress: offset * 100 / manifest.size)
                        let chunk = try await RemoteHTTPExchange(endpoint: endpoint,
                            path: "/api/update/chunk?sha256=\(manifest.sha256)&offset=\(offset)", method: "GET", body: Data(), expectedNodeID: nodeID).run()
                        guard chunk.status == 200, chunk.body.count == min(LANUpdateManifest.chunkSize, manifest.size - offset) else { throw AppError.message("업데이트 전송이 끊겼습니다. 잠시 후 다시 확인합니다.") }
                        try handle.write(contentsOf: chunk.body)
                    }
                    try handle.synchronize(); try handle.close()
                    self.status("checking", "업데이트 서명과 체크섬을 확인하고 있습니다.", version: release.version)
                    let candidate = try await Task.detached(priority: .utility) { try LANUpdateInstallation.stage(archive: archive, manifest: manifest, directory: directory) }.value
                    try Task.checkCancellation()
                    self.staged = (manifest, directory, candidate); incoming = nil
                }
                guard let staged = self.staged, engine.lanUpdate.enabled else { return }
                if let reason = engine.lanUpdateWaitReason {
                    self.status("waiting", reason, version: release.version); return
                }
                let manager = try ProcessDiscovery.read().first { $0.pid == getpid() }
                guard let manager, manager.executable == app.appendingPathComponent("Contents/MacOS/AutoApproveApp").path,
                      let port = engine.webStatus.port, FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path),
                      FileManager.default.isWritableFile(atPath: app.path) else { throw AppError.message("설치 위치에 쓸 수 없습니다. 설치 파일을 Applications에 적용해주세요.") }
                let job = LANUpdateInstallation.Job(app: app.path, candidate: staged.2.path, managerPID: getpid(), managerStarted: manager.started,
                    release: staged.0.release, nodeID: engine.webService?.nodeID ?? "", port: port, directory: staged.1.path, home: engine.paths.directory.path)
                let file = staged.1.appendingPathComponent("job.json")
                try JSONEncoder().encode(job).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                let helper = Process()
                try? FileManager.default.removeItem(at: staged.1.appendingPathComponent("helper-ready"))
                helper.executableURL = app.appendingPathComponent("Contents/MacOS/autoapprove")
                helper.arguments = ["lan-update-install", file.path]
                helper.standardInput = FileHandle.nullDevice; helper.standardOutput = FileHandle.nullDevice
                let log = staged.1.appendingPathComponent("install-error.txt")
                FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
                helper.standardError = try FileHandle(forWritingTo: log)
                try helper.run()
                let until = Date().addingTimeInterval(8)
                while !FileManager.default.fileExists(atPath: staged.1.appendingPathComponent("helper-ready").path) {
                    guard helper.isRunning, Date() < until else { throw AppError.message("업데이트 설치 도구를 준비하지 못했습니다.") }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
                guard engine.lanUpdate.enabled, engine.lanUpdateWaitReason == nil else {
                    helper.terminate(); self.status("waiting", engine.lanUpdateWaitReason ?? "자동 업데이트가 꺼져 있습니다.", version: release.version); return
                }
                self.status("applying", "AutoApprove를 업데이트하고 다시 엽니다. 원본 CLI는 계속 실행됩니다.", version: release.version)
                self.applying = true
                engine.finishLANUpdate()
            } catch {
                if let incoming { try? FileManager.default.removeItem(at: incoming) }
                if !Task.isCancelled, engine.lanUpdate.enabled {
                    self.retryAfter = Date().addingTimeInterval(600)
                    self.status("failed", error.localizedDescription, version: release.version)
                }
            }
        }
    }
    private func status(_ phase: String, _ detail: String, version: String?, progress: Int? = nil) {
        guard let engine, engine.lanUpdate.enabled else { return }
        var value = engine.lanUpdate; value.phase = phase; value.detail = detail; value.version = version; value.progress = progress
        engine.updateLANUpdateStatus(value)
    }
}
