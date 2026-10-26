import Foundation
import Security
import Darwin
import LocalAuthentication

public struct CloudflareHTTPReply:Sendable {
    public let data:Data
    public let status:Int
    public init(data:Data,status:Int) {self.data=data;self.status=status}
}

/// Dependency boundary for isolated account/HTTP tests; live URLs stay pinned.
public struct CloudflareServices:Sendable {
    public var exchange:@Sendable (URLRequest) async throws -> CloudflareHTTPReply
    public var login:@Sendable (String,URL,@escaping @Sendable (URL)->Void) async throws -> Data
    public var readSecret:@Sendable (URL,String) throws -> Data?
    public var saveSecret:@Sendable (URL,String,Data) throws -> Void
    public init(exchange:@escaping @Sendable(URLRequest) async throws -> CloudflareHTTPReply,
                login:@escaping @Sendable(String,URL,@escaping @Sendable(URL)->Void) async throws -> Data,
                readSecret:@escaping @Sendable(URL,String) throws -> Data?,saveSecret:@escaping @Sendable(URL,String,Data) throws -> Void) {
        self.exchange=exchange;self.login=login;self.readSecret=readSecret;self.saveSecret=saveSecret
    }
    public static let live=CloudflareServices(exchange:{request in
        let configuration=URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies=false;configuration.timeoutIntervalForRequest=15;configuration.timeoutIntervalForResource=30
        let session=URLSession(configuration:configuration,delegate:TunnelRedirectPolicy(),delegateQueue:nil)
        defer {session.invalidateAndCancel()}
        let (bytes,response)=try await session.bytes(for:request)
        var data=Data();data.reserveCapacity(8192)
        for try await byte in bytes {
            guard data.count < 2_000_000 else {throw AppError.message("Cloudflare 응답이 너무 큽니다. 잠시 후 다시 시도해주세요.")}
            data.append(byte)
        }
        return CloudflareHTTPReply(data:data,status:(response as? HTTPURLResponse)?.statusCode ?? 0)
    },login:{executable,directory,onURL in
        try await CloudflareLogin.run(executable:executable,directory:directory,onURL:onURL)
    },readSecret:{directory,account in
        var query=RemoteTunnelCredentials.query(directory);query[kSecAttrAccount as String]=account
        query[kSecReturnData as String]=true;query[kSecMatchLimit as String]=kSecMatchLimitOne
        let context=LAContext();context.interactionNotAllowed=true
        query[kSecUseAuthenticationContext as String]=context
        var result:CFTypeRef?
        let status=SecItemCopyMatching(query as CFDictionary,&result)
        if status == errSecItemNotFound {return nil}
        guard status == errSecSuccess,let data=result as? Data else {throw AppError.message("Mac 키체인의 Cloudflare 승인 정보를 읽지 못했습니다. 키체인을 잠금 해제한 뒤 다시 승인해주세요.")}
        return data
    },saveSecret:{directory,account,data in
        var query=RemoteTunnelCredentials.query(directory);query[kSecAttrAccount as String]=account
        let result=SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if result == errSecItemNotFound {
            query[kSecValueData as String]=data;query[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(query as CFDictionary,nil) == errSecSuccess else {throw AppError.message("Cloudflare 승인 정보를 Mac 키체인에 저장하지 못했습니다.")}
        } else if result != errSecSuccess {throw AppError.message("Cloudflare 승인 정보를 Mac 키체인에 저장하지 못했습니다.")}
    })
}

/// Owns only this login child. Cancellation also works during app termination.
private final class CloudflareLogin:@unchecked Sendable {
    private let lock=NSLock()
    private let process=Process(),pipe=Pipe()
    private var buffer="",cancelled=false
    private func stop() {
        lock.lock();cancelled=true;pipe.fileHandleForReading.readabilityHandler=nil
        if process.isRunning {
            process.terminate();let deadline=ProcessInfo.processInfo.systemUptime+0.25
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {Thread.sleep(forTimeInterval:0.01)}
            if process.isRunning {kill(process.processIdentifier,SIGKILL)}
            process.waitUntilExit()
        }
        lock.unlock()
    }
    static func run(executable:String,directory:URL,onURL:@escaping @Sendable(URL)->Void) async throws -> Data {
        let owned=CloudflareLogin()
        return try await withTaskCancellationHandler(operation:{
            try await owned.execute(executable,directory:directory,onURL:onURL)
        },onCancel:{owned.stop()})
    }
    private func execute(_ executable:String,directory:URL,onURL:@escaping @Sendable(URL)->Void) async throws -> Data {
        try Task.checkCancellation()
        let root=directory.appendingPathComponent("cloudflare-login/"+UUID().uuidString),home=root.appendingPathComponent(".cloudflared")
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.path)
        defer {stop();try? pipe.fileHandleForReading.close();try? pipe.fileHandleForWriting.close();try? FileManager.default.removeItem(at:root)}
        let configuration=root.appendingPathComponent("config.json")
        guard FileManager.default.createFile(atPath:configuration.path,contents:Data("{}".utf8),attributes:[.posixPermissions:0o600]) else {throw AppError.message("Cloudflare 승인 폴더를 준비하지 못했습니다.")}
        process.executableURL=URL(fileURLWithPath:executable);process.arguments=["tunnel","--config",configuration.path,"--no-autoupdate","login"]
        var environment=["HOME":root.path,"PATH":"/usr/bin:/bin:/usr/sbin:/sbin","TUNNEL_ORIGIN_CERT":home.appendingPathComponent("cert.pem").path]
        for key in ["HTTP_PROXY","HTTPS_PROXY","ALL_PROXY","NO_PROXY","SSL_CERT_FILE","SSL_CERT_DIR"] {
            if let value=ProcessInfo.processInfo.environment[key] {environment[key]=value}
        }
        process.environment=environment;process.standardInput=FileHandle.nullDevice;process.standardOutput=pipe;process.standardError=pipe
        let fd=pipe.fileHandleForReading.fileDescriptor,flags=fcntl(pipe.fileHandleForReading.fileDescriptor,F_GETFL)
        if flags >= 0 {_ = fcntl(fd,F_SETFL,flags | O_NONBLOCK)}
        pipe.fileHandleForReading.readabilityHandler={ [weak self] handle in
            var bytes=[UInt8](repeating:0,count:4096)
            let count=bytes.withUnsafeMutableBytes {Darwin.read(fd,$0.baseAddress,4096)}
            guard count > 0 else {if count == 0 {handle.readabilityHandler=nil};return}
            guard let self else {return}
            self.lock.lock();defer {self.lock.unlock()}
            guard !self.cancelled else {return}
            self.buffer += String(decoding:bytes.prefix(count),as:UTF8.self)
            if self.buffer.utf8.count > 16384 {self.buffer=String(self.buffer.suffix(8192))}
            while let end=self.buffer.firstIndex(of:"\n") {
                let line=String(self.buffer[..<end]);self.buffer.removeSubrange(...end)
                if let range=line.range(of:#"https://dash\.cloudflare\.com/argotunnel[^\s\u001B]*"#,options:.regularExpression),
                   let url=URL(string:String(line[range])),url.absoluteString.count <= 4096,
                   url.host == "dash.cloudflare.com",url.path == "/argotunnel" {onURL(url)}
            }
        }
        try startChild()
        let until=ProcessInfo.processInfo.systemUptime+600
        while process.isRunning {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < until else {throw AppError.message("Cloudflare 승인 시간이 지났습니다. 다시 승인해주세요.")}
            try await Task.sleep(for:.milliseconds(50))
        }
        try Task.checkCancellation()
        let certificate=home.appendingPathComponent("cert.pem")
        guard process.terminationStatus == 0,let attributes=try? certificate.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]),
              attributes.isRegularFile == true,attributes.isSymbolicLink == false,let size=attributes.fileSize,(1...65536).contains(size) else {
            throw AppError.message("Cloudflare 승인이 완료되지 않았습니다. 브라우저에서 허용한 뒤 다시 시도해주세요.")
        }
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:certificate.path)
        return try Data(contentsOf:certificate)
    }
    private func startChild() throws {
        lock.lock();defer {lock.unlock()}
        guard !cancelled else {throw CancellationError()}
        do {try process.run()} catch {throw AppError.message("Cloudflare 승인 도구를 실행하지 못했습니다.")}
    }
}
