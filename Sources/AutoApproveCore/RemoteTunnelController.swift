import Foundation
import Darwin
import Security
import CryptoKit

/// Tokens never enter engine snapshots, public responses, arguments or logs.
enum RemoteTunnelCredentials {
    static func query(_ directory: URL) -> [String:Any] {
        let profile=SHA256.hash(data:Data(directory.path.utf8)).map { String(format:"%02x",$0) }.joined()
        return [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.autoapprove.tunnel."+profile,kSecAttrAccount as String:"cloudflare"]
    }
    static func save(_ value: String, directory: URL) throws {
        let key=query(directory), attributes=[kSecValueData as String:Data(value.utf8)]
        let result=SecItemUpdate(key as CFDictionary,attributes as CFDictionary)
        if result == errSecItemNotFound {
            var entry=key; entry.merge(attributes) { _,new in new }; entry[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(entry as CFDictionary,nil) == errSecSuccess else { throw AppError.message("Cloudflare 토큰을 키체인에 저장하지 못했습니다.") }; return
        }
        guard result == errSecSuccess else { throw AppError.message("Cloudflare 토큰을 키체인에 저장하지 못했습니다.") }
    }
    static func read(_ directory: URL) throws -> String {
        var key=query(directory); key[kSecReturnData as String]=true; key[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?
        guard SecItemCopyMatching(key as CFDictionary,&result) == errSecSuccess, let data=result as? Data, let token=String(data:data,encoding:.utf8), !token.isEmpty else {
            throw AppError.message("Cloudflare 터널 토큰을 입력해주세요. 저장한 토큰이 있다면 Mac 키체인을 잠금 해제해주세요.")
        }
        return token
    }
}

@MainActor public final class RemoteTunnelController {
    private let directory: URL
    private let handler: @MainActor (RemoteHTTPRequest) async -> RemoteHTTPResponse
    private let onStatus: @MainActor (RemoteTunnelStatus) -> Void
    private var gateway: RemoteTunnelGateway?
    private var process: Process?
    private var output: Pipe?
    private var runDirectory: URL?
    private var task: Task<Void,Never>?
    private var generation=UUID(), retries=0
    private var configuration=RemoteTunnelConfiguration(), token="", logBuffer=""
    private var startedAt:TimeInterval=0
    private var checkingURL: String?
    private var edgeConnectionFailed=false
    private var managedCredentials:Data?
    private var qualityTracker = RemoteTunnelQualityTracker()
    private var monitor:RemoteTunnelMonitor?
    private var metricsPort:UInt16?
    public private(set) var status=RemoteTunnelStatus()
    public var accessKey: String? { gateway?.accessKey }
    public var shareURL: URL? {
        guard status.ready, let origin=status.publicURL, let key=accessKey else { return nil }
        return URL(string:origin+(gateway?.pinEnabled == true ? "/":"/#access="+key))
    }
    public init(directory: URL,handler:@escaping @MainActor (RemoteHTTPRequest) async -> RemoteHTTPResponse,onStatus:@escaping @MainActor (RemoteTunnelStatus)->Void) {
        self.directory=directory; self.handler=handler; self.onStatus=onStatus
    }
    public static func executable(directory: URL) -> String? {
        [directory.appendingPathComponent("tunnel-tools/cloudflared").path,"/opt/homebrew/bin/cloudflared","/usr/local/bin/cloudflared"].first { FileManager.default.isExecutableFile(atPath:$0) }
    }
    private func publish(_ phase: String,_ detail: String) {
        status.phase=phase; status.detail=detail; onStatus(status)
    }
    public func setPIN(_ pin:RemoteTunnelPIN?,accessKey:String) {gateway?.setPIN(pin,accessKey:accessKey)}
    public func start(_ supplied: RemoteTunnelConfiguration, token: String = "",credentials:Data? = nil,pin:RemoteTunnelPIN? = nil) async throws {
        stop(); qualityTracker = RemoteTunnelQualityTracker(); configuration=try supplied.validated(); self.token=token;managedCredentials=credentials;retries=0
        let epoch=UUID(); generation=epoch; status.provider=configuration.provider
        publish("starting","인증 접속을 준비하고 있습니다…")
        do {
            let gateway=try RemoteTunnelGateway(polling:configuration.provider == .quick,pin:pin,handler:handler)
            self.gateway=gateway
            try await gateway.start(port:[.quick,.managed].contains(configuration.provider) ? 0 : configuration.port)
            guard generation == epoch else { gateway.stop(); throw CancellationError() }
            guard let port=gateway.port else { throw AppError.message("터널 연결 포트를 열지 못했습니다.") }
            status.localURL="http://127.0.0.1:\(port)"
            if configuration.provider == .external {
                status.publicURL=configuration.publicURL; try gateway.setOrigin(configuration.publicURL)
                verify(configuration.publicURL,epoch:epoch)
            } else { try launch(epoch:epoch) }
        } catch {
            guard generation == epoch else { throw error }
            stop(); publish("failed",error.localizedDescription); throw error
        }
    }
    public func stop(waitForExit:Bool = false) {
        monitor?.stop();monitor = nil;metricsPort = nil
        generation=UUID(); task?.cancel(); task=nil; checkingURL=nil
        let child=process, pipe=output, scratch=runDirectory
        process=nil; output=nil; runDirectory=nil; logBuffer=""; token="";managedCredentials=nil
        pipe?.fileHandleForReading.readabilityHandler=nil
        child?.terminationHandler=nil
        if let child, child.isRunning {
            child.terminate()
            if waitForExit {
                // App termination cannot depend on an async task surviving it.
                let deadline=ProcessInfo.processInfo.systemUptime+0.25
                while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline {Thread.sleep(forTimeInterval:0.01)}
                if child.isRunning {kill(child.processIdentifier,SIGKILL)}
                child.waitUntilExit();try? pipe?.fileHandleForReading.close();try? pipe?.fileHandleForWriting.close()
                if let scratch {try? FileManager.default.removeItem(at:scratch)}
            } else { Task.detached {
                let deadline=ProcessInfo.processInfo.systemUptime+2
                while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(for:.milliseconds(20)) }
                if child.isRunning { kill(child.processIdentifier,SIGKILL) }
                child.waitUntilExit(); try? pipe?.fileHandleForReading.close(); try? pipe?.fileHandleForWriting.close()
                if let scratch { try? FileManager.default.removeItem(at:scratch) }
            } }
        } else {
            try? pipe?.fileHandleForReading.close(); try? pipe?.fileHandleForWriting.close()
            if let scratch { try? FileManager.default.removeItem(at:scratch) }
        }
        gateway?.stop(); gateway=nil; status=RemoteTunnelStatus(); onStatus(status)
    }
    private func launch(epoch: UUID) throws {
        guard generation == epoch, let localURL=status.localURL else { throw CancellationError() }
        guard let executable=configuration.executable.isEmpty ? Self.executable(directory:directory) : configuration.executable else {
            throw AppError.message("Cloudflare 연결 도구를 설치하거나 cloudflared 파일을 선택해주세요.")
        }
        let root=directory.appendingPathComponent("tunnel-runs/"+UUID().uuidString)
        metricsPort = nil;monitor?.setMetricsPort(nil)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]); runDirectory=root
        var arguments=["tunnel","--no-autoupdate","--protocol","auto","--edge-ip-version","auto","--metrics","127.0.0.1:0"]
        if configuration.provider == .managed {
            guard let id=configuration.tunnelID,let data=managedCredentials,data.count <= 65536,
                  let value=try? JSONSerialization.jsonObject(with:data) as? JSONObject,
                  (value["TunnelID"] as? String)?.lowercased() == id.lowercased(),
                  let account=value["AccountTag"] as? String,account.range(of:#"^[a-fA-F0-9]{32}$"#,options:.regularExpression) != nil,
                  let secret=value["TunnelSecret"] as? String,Data(base64Encoded:secret)?.count == 32,
                  let host=URLComponents(string:configuration.publicURL)?.host else {throw AppError.message("이 Mac의 Cloudflare 터널 정보를 읽지 못했습니다. 도메인을 선택하고 다시 연결해주세요.")}
            let credential=root.appendingPathComponent("credentials.json"),config=root.appendingPathComponent("config.json")
            let settings:JSONObject=["tunnel":id,"credentials-file":credential.path,"ingress":[["hostname":host,"service":localURL],["service":"http_status:404"]]]
            guard FileManager.default.createFile(atPath:credential.path,contents:data,attributes:[.posixPermissions:0o600]),
                  // cloudflared reads this through YAML: JSON's optional \/
                  // escape is not accepted by its YAML parser.
                  FileManager.default.createFile(atPath:config.path,contents:try JSONSerialization.data(withJSONObject:settings,options:.withoutEscapingSlashes),attributes:[.posixPermissions:0o600]) else {throw AppError.message("Cloudflare 연결 설정을 준비하지 못했습니다.")}
            arguments.insert(contentsOf:["--config",config.path],at:1)
            arguments += ["run","--credentials-file",credential.path,id]
            status.publicURL=configuration.publicURL;try gateway?.setOrigin(configuration.publicURL)
        } else if configuration.provider == .quick { arguments += ["--url",localURL] }
        else {
            guard !token.isEmpty, token.utf8.count <= 16384, !token.contains("\n"), !token.contains("\0") else { throw AppError.message("Cloudflare 터널 토큰을 확인해주세요.") }
            let file=root.appendingPathComponent("token")
            guard FileManager.default.createFile(atPath:file.path,contents:Data(token.utf8),attributes:[.posixPermissions:0o600]) else { throw AppError.message("토큰 임시 파일을 만들지 못했습니다.") }
            arguments += ["run","--token-file",file.path]
            status.publicURL=configuration.publicURL; try gateway?.setOrigin(configuration.publicURL)
        }
        let child=Process(), pipe=Pipe(); output=pipe; process=child; logBuffer=""; edgeConnectionFailed=false; startedAt=ProcessInfo.processInfo.systemUptime
        child.executableURL=URL(fileURLWithPath:executable); child.arguments=arguments
        var environment=["HOME":root.path,"PATH":"/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HTTP_PROXY","HTTPS_PROXY","ALL_PROXY","NO_PROXY","SSL_CERT_FILE","SSL_CERT_DIR"] {
            if let value=ProcessInfo.processInfo.environment[key] { environment[key]=value }
        }
        child.environment=environment; child.standardInput=FileHandle.nullDevice; child.standardOutput=pipe; child.standardError=pipe
        let readFD=pipe.fileHandleForReading.fileDescriptor
        let flags=fcntl(readFD,F_GETFL)
        if flags >= 0 {_ = fcntl(readFD,F_SETFL,flags | O_NONBLOCK)}
        pipe.fileHandleForReading.readabilityHandler={ [weak self,weak child] handle in
            // FileHandle.read(upToCount:) can wait for a full buffer on pipes.
            // A connector emitting only its registration line must advance now.
            var bytes=[UInt8](repeating:0,count:4096)
            let count=bytes.withUnsafeMutableBytes {Darwin.read(readFD,$0.baseAddress,4096)}
            guard count > 0 else {if count == 0 {handle.readabilityHandler=nil};return}
            let data=Data(bytes.prefix(count))
            Task { @MainActor in guard let self, let child, self.process === child else { return }; self.readLog(data,epoch:epoch) }
        }
        child.terminationHandler={ [weak self] child in Task { @MainActor in self?.exited(child,epoch:epoch) } }
        publish("connecting","Cloudflare로 연결하고 있습니다…")
        do { try child.run() }
        catch { pipe.fileHandleForReading.readabilityHandler=nil; throw AppError.message("Cloudflare 연결 도구를 실행하지 못했습니다. 파일과 실행 권한을 확인해주세요.") }
        task?.cancel(); task=Task { [weak self] in
            do { try await Task.sleep(for:.seconds(60)) } catch { return }
            guard let self, self.generation == epoch, !self.status.ready else { return }
            let detail=self.edgeConnectionFailed ? "Cloudflare 자동 연결에 실패했습니다. Tunnel은 UDP 또는 TCP 7844가 필요합니다. 443만 허용된 네트워크에서는 HTTPS 중계 연결이 필요합니다." : "Cloudflare 연결 시간이 초과됐습니다. 인터넷 연결과 터널 설정을 확인하고 다시 시도해주세요."
            self.stop(); self.publish("failed",detail)
        }
    }
    private func readLog(_ data: Data,epoch:UUID) {
        guard generation == epoch else { return }
        logBuffer += String(decoding:data,as:UTF8.self)
        if logBuffer.utf8.count > 16384 { logBuffer=String(logBuffer.suffix(4096)) }
        while let newline=logBuffer.firstIndex(of:"\n") {
            let line=String(logBuffer[..<newline]); logBuffer.removeSubrange(...newline)
            if let range = line.range(of:#"Starting metrics server on 127\.0\.0\.1:[0-9]{1,5}(?:/metrics)?"#,options:.regularExpression),
               let port = UInt16(line[range].split(separator:":").last!.split(separator:"/").first!),port > 0 {
                metricsPort = port;monitor?.setMetricsPort(port)
            }
            // Classify a known network failure without exposing diagnostic text.
            if line.contains("HTTP/2 connection is blocked or unreachable") || (line.contains("dial tcp ") && line.contains(":7844:") && line.contains("timeout")) { edgeConnectionFailed=true }
            if line.contains("failed to dial to edge with quic") && line.contains("timeout") {edgeConnectionFailed=true}
            if configuration.provider == .quick, let range=line.range(of:"https://[a-z0-9-]+\\.trycloudflare\\.com",options:.regularExpression) {
                let url=String(line[range]); status.publicURL=url
                do { try gateway?.setOrigin(url) } catch { stop(); publish("failed","Cloudflare 접속 주소를 확인하지 못했습니다.") }
            }
            if line.contains("Registered tunnel connection"), let url=status.publicURL {
                qualityTracker.registration(line);status.quality = qualityTracker.snapshot();onStatus(status);verify(url,epoch:epoch)
            }
        }
    }
    private func verify(_ url:String,epoch:UUID) {
        guard checkingURL != url else { return }; checkingURL=url
        publish("checking","공개 HTTPS 주소가 이 Mac으로 연결되는지 확인 중…")
        task?.cancel(); task=Task { [weak self] in
            guard let self else { return }
            let session=URLSession(configuration:.ephemeral,delegate:TunnelRedirectPolicy(),delegateQueue:nil)
            defer { session.invalidateAndCancel() }
            var failure="응답 없음"
            for _ in 0..<(self.configuration.provider == .quick ? 20 : 5) {
                guard !Task.isCancelled, self.generation == epoch, let gateway=self.gateway else { return }
                do {
                    var request=URLRequest(url:URL(string:url+"/auth/probe")!); request.timeoutInterval=3
                    let (data,response)=try await session.data(for:request)
                    guard self.generation == epoch, !Task.isCancelled else { return }
                    failure="HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                    if (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1024,
                       let value=try JSONSerialization.jsonObject(with:data) as? [String:String], value["probe"] == gateway.probe {
                        self.publish("ready",self.configuration.provider == .quick ? "임시 주소로 연결됨 · 화면 순차 조회" : "외부 접속 연결됨 · 실시간 터미널")
                        self.startMonitor(url,epoch:epoch);return
                    }
                } catch {failure="네트워크 오류 \((error as NSError).code)"}
                do { try await Task.sleep(for:.seconds(1)) } catch { return }
            }
            guard self.generation == epoch else { return }
            if self.configuration.provider == .quick {
                self.stop();self.publish("failed","공개 주소에서 이 Mac을 확인하지 못했습니다 (\(failure)). 인터넷 연결을 확인한 뒤 다시 시도해주세요.")
            } else {
                self.checkingURL=nil
                if self.configuration.provider == .managed {
                    self.publish("routeRequired","터널과 DNS 설정을 마쳤습니다. DNS 반영을 잠시 기다린 뒤 ‘공개 주소 확인’을 눌러주세요 (\(failure)).")
                } else {
                    let provider=self.configuration.provider == .named ? "Cloudflare의 게시된 애플리케이션 경로" : "사용 중인 터널"
                    self.publish("routeRequired","연결 도구가 준비됐습니다. \(provider)에 서비스 URL을 지정한 뒤 ‘공개 주소 확인’을 눌러주세요 (\(failure)).")
                }
            }
        }
    }
    public func checkPublicURL() {
        guard status.phase == "routeRequired",let url=status.publicURL,gateway != nil else {return}
        checkingURL=nil;verify(url,epoch:generation)
    }
    private func startMonitor(_ origin:String,epoch:UUID) {
        guard let gateway else {return}
        monitor?.stop()
        let monitor = RemoteTunnelMonitor(origin:origin,nonce:gateway.probe,tracker:qualityTracker,onUpdate:{ [weak self] quality in
            guard let self,self.generation == epoch else {return};self.status.quality = quality;self.onStatus(self.status)
        })
        self.monitor = monitor;monitor.setMetricsPort(metricsPort);monitor.start()
    }
    public func measureConnection() async {await monitor?.sample()}
    private func exited(_ child:Process,epoch:UUID) {
        guard generation == epoch, process === child else { return }
        output?.fileHandleForReading.readabilityHandler=nil
        try? output?.fileHandleForReading.close(); try? output?.fileHandleForWriting.close(); output=nil; process=nil
        if let runDirectory { try? FileManager.default.removeItem(at:runDirectory) }; runDirectory=nil
        task?.cancel(); checkingURL=nil; gateway?.disconnectClients()
        monitor?.stop();qualityTracker.reconnected();status.quality = qualityTracker.snapshot()
        if ProcessInfo.processInfo.systemUptime-startedAt > 60 { retries=0 }
        guard retries < 5 else { stop(); publish("failed","Cloudflare 연결이 반복 종료됐습니다. 도구·토큰·네트워크를 확인하고 다시 연결해주세요."); return }
        let delay=Double(1 << retries); retries += 1
        publish("reconnecting","터널 연결을 다시 시도합니다… (\(retries)/5)")
        task=Task { [weak self] in
            do { try await Task.sleep(for:.seconds(delay)) } catch { return }
            guard let self, self.generation == epoch else { return }
            do { try self.launch(epoch:epoch) } catch { self.stop(); self.publish("failed",error.localizedDescription) }
        }
    }
}

/// Public-origin probes never follow a redirect to a different service.
final class TunnelRedirectPolicy: NSObject,URLSessionTaskDelegate,@unchecked Sendable {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) { completionHandler(nil) }
}
