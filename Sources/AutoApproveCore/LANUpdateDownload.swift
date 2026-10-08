import Foundation
import Darwin

/// A private partial archive is tied to the complete manifest, never to an address alone.
public enum LANUpdateDownload {
    private struct Record: Codable { let manifest: LANUpdateManifest; let offset: Int; let updatedAt: Date }
    public static func clear(directory: URL) throws {
        for name in ["resume.json", "update.zip"] {
            let url = directory.appendingPathComponent(name)
            if (try? FileManager.default.attributesOfItem(atPath:url.path)) != nil { try FileManager.default.removeItem(at:url) }
        }
    }
    private static func regular(_ url: URL) throws -> Int? {
        let value: [FileAttributeKey: Any]
        do { value = try FileManager.default.attributesOfItem(atPath:url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError,NSFileReadNoSuchFileError].contains(error.code) { return nil }
        guard value[.type] as? FileAttributeType == .typeRegular,
              (value[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (value[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { throw AppError.message("저장한 업데이트 파일의 권한을 확인하지 못했습니다.") }
        return (value[.size] as? NSNumber)?.intValue
    }
    public static func download(manifest: LANUpdateManifest, directory: URL,
        read: @MainActor @Sendable (String) async throws -> RemoteHTTPResponse,
        progress: @MainActor @Sendable (Int) -> Void = { _ in }) async throws -> URL {
        try manifest.validate(nodeID:manifest.nodeID,newerThan:RemoteWebVersion(version:"0.0.0",build:0))
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath:directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw AppError.message("업데이트 저장 위치를 확인하지 못했습니다.") }
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
        let archive = directory.appendingPathComponent("update.zip"), recordURL = directory.appendingPathComponent("resume.json")
        _ = try regular(recordURL); let size = try regular(archive)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let record = (try? Data(contentsOf:recordURL)).flatMap { try? decoder.decode(Record.self,from:$0) }
        var offset = 0
        if let record, record.manifest == manifest, let size, size <= manifest.size,
           (-5...86_400).contains(Date().timeIntervalSince(record.updatedAt)), record.offset >= 0, record.offset <= manifest.size,
           record.offset.isMultiple(of:LANUpdateManifest.chunkSize) || record.offset == manifest.size {
            let available = min(size,record.offset)
            offset = available == manifest.size ? available : available / LANUpdateManifest.chunkSize * LANUpdateManifest.chunkSize
        } else { try clear(directory:directory) }
        if !FileManager.default.fileExists(atPath:archive.path) {
            guard FileManager.default.createFile(atPath:archive.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw AppError.message("업데이트 파일을 만들지 못했습니다.") }
        }
        let handle = try FileHandle(forUpdating:archive); defer { try? handle.close() }
        try handle.truncate(atOffset:UInt64(offset)); try handle.seek(toOffset:UInt64(offset))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        func save() throws {
            try encoder.encode(Record(manifest:manifest,offset:offset,updatedAt:Date())).write(to:recordURL,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:recordURL.path)
        }
        try save(); await progress(offset)
        while offset < manifest.size {
            try Task.checkCancellation()
            do {
                let chunk = try await read("/api/update/chunk?sha256=\(manifest.sha256)&offset=\(offset)")
                guard chunk.status == 200 else { throw RemoteHTTPError(chunk.status,"업데이트 파일을 받지 못했습니다.") }
                guard chunk.body.count == min(LANUpdateManifest.chunkSize,manifest.size-offset) else { throw RemoteHTTPError(503,"업데이트 전송이 끊겼습니다.") }
                try handle.write(contentsOf:chunk.body); offset += chunk.body.count
                try save(); await progress(offset)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                var diagnostics = (error as? RemoteHTTPError)?.diagnostics ?? [:]
                diagnostics["stage"] = "download"; diagnostics["offset"] = String(offset)
                throw RemoteHTTPError((error as? RemoteHTTPError)?.status ?? (RemoteReadRecovery.isTransient(error) ? 503 : 500),error.localizedDescription,diagnostics:diagnostics)
            }
        }
        try handle.synchronize(); try handle.close()
        guard LANUpdateInstallation.digest(try Data(contentsOf:archive,options:.mappedIfSafe)) == manifest.sha256 else {
            try clear(directory:directory); throw AppError.message("업데이트 파일의 체크섬이 일치하지 않습니다.")
        }
        return archive
    }
}

public enum LANUpdateRetryPolicy {
    public static func delay(failures: Int) -> TimeInterval { [2.0,5,10,20,30,60][min(5,max(0,failures-1))] }
}
