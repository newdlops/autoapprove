import Foundation
import CryptoKit

public enum RemoteTunnelTool {
    public static let version="2026.10.3"
    public static func install(directory: URL) async throws -> String {
        #if arch(arm64)
        let architecture="arm64", size=19_841_881, digest="1165d14b6f6360a3b8c283d7d1100024d6ec7cd9bc9e32519e96150645f3ec55"
        #else
        let architecture="amd64", size=21_823_395, digest="81b7b85f2376815c4f59b1aa323887b62e16ce8b67555c2e1577dc23f2a82000"
        #endif
        let url=URL(string:"https://github.com/cloudflare/cloudflared/releases/download/\(version)/cloudflared-darwin-\(architecture).tgz")!
        let config=URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest=30; config.timeoutIntervalForResource=180
        let session=URLSession(configuration:config,delegate:TunnelDownloadRedirects(),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        let (download,response)=try await session.download(from:url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.message("Cloudflare 연결 도구를 다운로드하지 못했습니다. 인터넷 연결을 확인해주세요.") }
        return try await Task.detached {
            let attributes=try FileManager.default.attributesOfItem(atPath:download.path)
            guard (attributes[.size] as? NSNumber)?.intValue == size else { throw AppError.message("Cloudflare 다운로드 크기가 맞지 않아 설치하지 않았습니다.") }
            let file=try FileHandle(forReadingFrom:download); defer { try? file.close() }
            var hash=SHA256()
            while let bytes=try file.read(upToCount:65536), !bytes.isEmpty { hash.update(data:bytes) }
            guard hash.finalize().map({String(format:"%02x",$0)}).joined() == digest else { throw AppError.message("Cloudflare 다운로드 체크섬이 맞지 않아 설치하지 않았습니다.") }
            let tools=directory.appendingPathComponent("tunnel-tools"), scratch=tools.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            defer { try? FileManager.default.removeItem(at:scratch) }
            let result=try CommandRunner.run("/usr/bin/tar",["-xzf",download.path,"-C",scratch.path,"cloudflared"],timeout:20,inheritEnvironment:false,outputLimit:1024,errorLimit:4096)
            let binary=scratch.appendingPathComponent("cloudflared")
            let values=try binary.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard result.status == 0, values.isRegularFile == true, values.isSymbolicLink == false, let bytes=values.fileSize, (1...128_000_000).contains(bytes) else { throw AppError.message("Cloudflare 실행 파일을 확인하지 못했습니다.") }
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:binary.path)
            let checked=try CommandRunner.run(binary.path,["--version"],timeout:5,inheritEnvironment:false,outputLimit:1024,errorLimit:4096)
            guard checked.status == 0, checked.output.contains(version) else { throw AppError.message("Cloudflare 연결 도구의 버전을 확인하지 못했습니다.") }
            let destination=tools.appendingPathComponent("cloudflared")
            if FileManager.default.fileExists(atPath:destination.path) { _ = try FileManager.default.replaceItemAt(destination,withItemAt:binary) }
            else { try FileManager.default.moveItem(at:binary,to:destination) }
            return destination.path
        }.value
    }
}

private final class TunnelDownloadRedirects: NSObject,URLSessionTaskDelegate,@unchecked Sendable {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) {
        let allowed=["github.com","objects.githubusercontent.com","release-assets.githubusercontent.com"]
        completionHandler(request.url?.scheme == "https" && allowed.contains(request.url?.host ?? "") ? request : nil)
    }
}
