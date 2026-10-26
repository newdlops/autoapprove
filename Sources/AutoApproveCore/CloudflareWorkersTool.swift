import Foundation
import CryptoKit
import Network

public struct CloudflareWorkersAuthorization:Sendable {
    public let credential:Data,token:String
    public init(credential:Data,token:String) {self.credential=credential;self.token=token}
}
public enum CloudflareWorkersTool {
    public static let version="4.152.0"
    private static let integrity="sha512-lmXTF1sCDEqBaEMpreGczvg/x3AIh1d/qxc4BN7utQ4jEDwdA4YG0L6kr3ev0TtVLHRb6QLySNAOAunwn+dHeA=="
    private struct Tool:Codable,Sendable {let node:String,cli:String,version:String,integrity:String}
    private static func root(_ directory:URL)->URL {directory.appendingPathComponent("worker-tools")}
    private static func ready(_ directory:URL)->Tool? {
        let location=root(directory)
        guard let data=try? Data(contentsOf:location.appendingPathComponent("ready.json")),data.count<4096,
              let value=try? JSONDecoder().decode(Tool.self,from:data),value.version==version,value.integrity==integrity,
              value.cli==location.appendingPathComponent("wrangler-\(version)/node_modules/wrangler/wrangler-dist/cli.js").path,
              FileManager.default.isExecutableFile(atPath:value.node),FileManager.default.fileExists(atPath:value.cli) else {return nil}
        return value
    }
    public static func installed(directory:URL)->Bool {ready(directory) != nil}
    private static func environment(home:URL,node:String,interactive:Bool)->[String:String] {
        var values=["PATH":URL(fileURLWithPath:node).deletingLastPathComponent().path+":/usr/bin:/bin:/usr/sbin:/sbin",
                    "HOME":home.path,"XDG_CONFIG_HOME":home.appendingPathComponent("xdg").path,"LANG":"en_US.UTF-8",
                    "WRANGLER_SEND_METRICS":"false","NO_COLOR":"1","NPM_CONFIG_UPDATE_NOTIFIER":"false"]
        if !interactive {values["CI"]="true"}
        for key in ["HTTP_PROXY","HTTPS_PROXY","ALL_PROXY","NO_PROXY","SSL_CERT_FILE","SSL_CERT_DIR","NODE_EXTRA_CA_CERTS","PORT_MANAGER_PRESERVE_LISTEN_PORTS"] {
            if let value=ProcessInfo.processInfo.environment[key] {values[key]=value}
        }
        return values
    }
    private static func prepare(_ directory:URL) async throws -> Tool {
        if let value=ready(directory) {return value}
        let location=root(directory);try FileManager.default.createDirectory(at:location,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var chosen:String?
        for path in [location.appendingPathComponent("node-v24.22.1/bin/node").path,"/opt/homebrew/bin/node","/usr/local/bin/node","/usr/bin/node"] where FileManager.default.isExecutableFile(atPath:path) {
            let resolved=URL(fileURLWithPath:path).resolvingSymlinksInPath()
            let npm=resolved.deletingLastPathComponent().appendingPathComponent("../lib/node_modules/npm/bin/npm-cli.js").standardizedFileURL
            guard FileManager.default.fileExists(atPath:npm.path) else {continue}
            let checked=try await OwnedToolProcess.run(resolved.path,arguments:["--use-system-ca","--version"],environment:environment(home:location,node:resolved.path,interactive:false),directory:location,timeout:5)
            let text=String(decoding:checked.output,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
            let parts=text.dropFirst().split(separator:".").compactMap {Int($0)}
            if checked.status==0,text.hasPrefix("v"),parts.count==3,(parts[0]>22 || parts[0]==22&&parts[1]>=19) {chosen=resolved.path;break}
        }
        let node:String
        if let chosen {node=chosen} else {node=try await installNode(location)}
        try Task.checkCancellation()
        let npm=URL(fileURLWithPath:node).deletingLastPathComponent().appendingPathComponent("../lib/node_modules/npm/bin/npm-cli.js").standardizedFileURL.path
        let prefix=location.appendingPathComponent("wrangler-"+version)
        let result=try await OwnedToolProcess.run(node,arguments:["--use-system-ca",npm,"install","--prefix",prefix.path,"--ignore-scripts","--no-audit","--no-fund","--save-exact","--registry","https://registry.npmjs.org/","wrangler@"+version],environment:environment(home:location,node:node,interactive:false),directory:location,timeout:240)
        guard result.status==0 else {throw AppError.message("Cloudflare HTTPS 연결 도구를 준비하지 못했습니다. 인터넷 연결을 확인한 뒤 다시 승인해주세요.")}
        let cli=prefix.appendingPathComponent("node_modules/wrangler/wrangler-dist/cli.js")
        let manifest=try Data(contentsOf:prefix.appendingPathComponent("package-lock.json"))
        guard manifest.count<=2_000_000,let json=try JSONSerialization.jsonObject(with:manifest) as? JSONObject,
              let packages=json["packages"] as? JSONObject,let package=packages["node_modules/wrangler"] as? JSONObject,
              package["version"] as? String==version,package["integrity"] as? String==integrity,FileManager.default.fileExists(atPath:cli.path) else {
            throw AppError.message("Cloudflare HTTPS 연결 도구의 검증 정보가 맞지 않습니다.")
        }
        let value=Tool(node:node,cli:cli.path,version:version,integrity:integrity)
        try Task.checkCancellation();let marker=location.appendingPathComponent("ready.json")
        guard FileManager.default.createFile(atPath:marker.path,contents:try JSONEncoder().encode(value),attributes:[.posixPermissions:0o600]) else {throw AppError.message("연결 도구 설정을 저장하지 못했습니다.")}
        return value
    }
    private static func installNode(_ location:URL) async throws -> String {
        #if arch(arm64)
        let arch="arm64",digest="89c682593d76cd44233fa53b1563264e7de9cbb189cad169135c5b4fadfbc0a7"
        #else
        let arch="x64",digest="d132557e7ee2b85af08b0c8c34338e65c6430f2238d01f727728ef42dc83b035"
        #endif
        let url=URL(string:"https://nodejs.org/dist/v24.22.1/node-v24.22.1-darwin-\(arch).tar.gz")!
        let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=30;config.timeoutIntervalForResource=180
        let session=URLSession(configuration:config,delegate:TunnelRedirectPolicy(),delegateQueue:nil);defer {session.invalidateAndCancel()}
        let (download,response)=try await session.download(from:url)
        guard (response as? HTTPURLResponse)?.statusCode==200,
              let size=try? download.resourceValues(forKeys:[.fileSizeKey]).fileSize,(1...80_000_000).contains(size) else {throw AppError.message("HTTPS 연결 실행 도구를 다운로드하지 못했습니다.")}
        let file=try FileHandle(forReadingFrom:download);defer {try? file.close()};var hash=SHA256()
        while let data=try file.read(upToCount:65536),!data.isEmpty {hash.update(data:data)}
        guard hash.finalize().map({String(format:"%02x",$0)}).joined()==digest else {throw AppError.message("HTTPS 실행 도구의 체크섬이 맞지 않습니다.")}
        let nodeRoot=location.appendingPathComponent("node-v24.22.1")
        try FileManager.default.createDirectory(at:nodeRoot,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let extracted=try await OwnedToolProcess.run("/usr/bin/tar",arguments:["-xzf",download.path,"--strip-components=1","-C",nodeRoot.path],environment:["PATH":"/usr/bin:/bin"],directory:location,timeout:30)
        let node=nodeRoot.appendingPathComponent("bin/node")
        guard extracted.status==0,FileManager.default.isExecutableFile(atPath:node.path) else {throw AppError.message("HTTPS 실행 도구를 설치하지 못했습니다.")}
        return node.path
    }
    public static func authorize(directory:URL,credential:Data? = nil,interactive:Bool,onURL:@escaping @Sendable(URL)->Void) async throws -> CloudflareWorkersAuthorization {
        let tools=try await prepare(directory);try Task.checkCancellation()
        let session=try WorkerAuthSession(directory:directory)
        defer {session.close()}
        return try await withTaskCancellationHandler(operation:{
            let config=session.home.appendingPathComponent(".wrangler/config/default.toml")
            if !interactive {
                guard let credential,!credential.isEmpty,credential.count<=65536,
                      FileManager.default.createFile(atPath:config.path,contents:credential,attributes:[.posixPermissions:0o600]) else {throw AppError.message("Cloudflare HTTPS 연결 승인이 필요합니다.")}
            }
            var env=environment(home:session.home,node:tools.node,interactive:interactive)
            if interactive {
                let port=try availableCallbackPort()
                if env["PORT_MANAGER_PRESERVE_LISTEN_PORTS"] != nil {env["PORT_MANAGER_PRESERVE_LISTEN_PORTS"]=(env["PORT_MANAGER_PRESERVE_LISTEN_PORTS"]!+",\(port)")}
                let watcher=WorkerLoginURL(onURL)
                let result=try await session.run(tools.node,["--use-system-ca",tools.cli,"login","--browser=true","--use-keyring=false","--callback-host","127.0.0.1","--callback-port",String(port),"--install-skills=false","--scopes","account:read","user:read","workers:write","workers_routes:write","zone:read","offline_access"],env:env,timeout:600,onOutput:{watcher.read($0)})
                guard result.status==0 else {throw AppError.message("Cloudflare Workers 승인이 완료되지 않았습니다. 브라우저에서 승인한 뒤 다시 시도해주세요.")}
            }
            env["CI"]="true"
            let token=try await session.run(tools.node,["--use-system-ca",tools.cli,"auth","token","--json","--install-skills=false"],env:env,timeout:45)
            guard token.status==0,let json=try? JSONSerialization.jsonObject(with:token.output) as? JSONObject,
                  json["type"] as? String=="oauth",let value=json["token"] as? String,(16...8192).contains(value.utf8.count),
                  value.utf8.allSatisfy({$0>=33&&$0<=126}),let attributes=try? config.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]),
                  attributes.isRegularFile==true,attributes.isSymbolicLink==false,let size=attributes.fileSize,(1...65536).contains(size) else {throw AppError.message("Cloudflare HTTPS 승인 정보를 확인하지 못했습니다. 다시 승인해주세요.")}
            try Task.checkCancellation();try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:config.path)
            return CloudflareWorkersAuthorization(credential:try Data(contentsOf:config),token:value)
        },onCancel:{session.close()})
    }
    private static func availableCallbackPort() throws -> UInt16 {
        let fd=socket(AF_INET,SOCK_STREAM,0);guard fd>=0 else {throw AppError.message("승인 콜백 포트를 준비하지 못했습니다.")};defer {Darwin.close(fd)}
        // Official Wrangler's registered redirect remains localhost:8976 even
        // when --callback-port is changed. Keep its registered port; a random
        // listener would silently strand the browser after consent.
        var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_addr.s_addr=inet_addr("127.0.0.1");address.sin_port=UInt16(8976).bigEndian
        let bound=withUnsafePointer(to:&address) {$0.withMemoryRebound(to:sockaddr.self,capacity:1) {Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
        var length=socklen_t(MemoryLayout<sockaddr_in>.size)
        let result=withUnsafeMutablePointer(to:&address) {$0.withMemoryRebound(to:sockaddr.self,capacity:1) {getsockname(fd,$0,&length)}}
        guard bound==0,result==0 else {throw AppError.message("Cloudflare 승인에 필요한 이 Mac의 8976 포트를 다른 앱이 사용 중입니다. 해당 앱을 닫고 다시 승인해주세요.")};return UInt16(bigEndian:address.sin_port)
    }
}
private final class WorkerAuthSession:@unchecked Sendable {
    let home:URL
    private let lock=NSLock();private var closed=false,child:OwnedToolProcess?
    init(directory:URL) throws {
        home=directory.appendingPathComponent("worker-auth/"+UUID().uuidString)
        try FileManager.default.createDirectory(at:home.appendingPathComponent(".wrangler/config"),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:home.path)
    }
    private func set(_ process:OwnedToolProcess?) throws {lock.lock();defer {lock.unlock()};guard !closed else {throw CancellationError()};child=process}
    func run(_ node:String,_ args:[String],env:[String:String],timeout:TimeInterval,onOutput:@escaping @Sendable(Data)->Void = {_ in}) async throws -> OwnedToolProcess.Result {
        let process=OwnedToolProcess();try set(process);defer {try? set(nil)}
        return try await process.result(node,arguments:args,environment:env,directory:home,timeout:timeout,onOutput:onOutput)
    }
    func close() {lock.lock();defer {lock.unlock()};guard !closed else {return};closed=true;child?.cancel();child=nil;try? FileManager.default.removeItem(at:home)}
}
private final class WorkerLoginURL:@unchecked Sendable {
    private let lock=NSLock();private var buffer=""
    private let onURL:@Sendable(URL)->Void
    init(_ onURL:@escaping @Sendable(URL)->Void) {self.onURL=onURL}
    func read(_ data:Data) {
        lock.lock();defer {lock.unlock()};buffer+=String(decoding:data,as:UTF8.self)
        if buffer.utf8.count>16384 {buffer=String(buffer.suffix(8192))}
        while let end=buffer.firstIndex(of:"\n") {
            let line=String(buffer[..<end]);buffer.removeSubrange(...end)
            if let range=line.range(of:#"https://dash\.cloudflare\.com/oauth2/[^\s\u001B]+"#,options:.regularExpression),
               let url=URL(string:String(line[range])),url.absoluteString.count<=4096,url.host=="dash.cloudflare.com",url.path=="/oauth2/auth" {onURL(url)}
        }
    }
}
