import Foundation

public struct CloudflareRelayCredential:Codable,Sendable {
    public let script:String,origin:String,key:String
    public init(script:String,origin:String,key:String) {self.script=script;self.origin=origin;self.key=key}
    public func validated(for origin:String) throws -> Self {
        guard self.origin == origin,script.range(of:#"^autoapprove-relay-[a-f0-9]{32}$"#,options:.regularExpression) != nil,
              key.range(of:#"^[A-Za-z0-9_-]{43}$"#,options:.regularExpression) != nil,
              Data(base64Encoded:key.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")+"=")?.count == 32 else {
            throw AppError.message("HTTPS 중계 정보를 읽지 못했습니다. Cloudflare에서 승인한 도메인을 선택하고 다시 연결해주세요.")
        }
        return self
    }
}

@MainActor public final class CloudflareRelayController {
    private let handler:@MainActor(RemoteHTTPRequest) async -> RemoteHTTPResponse
    private let onStatus:@MainActor(RemoteTunnelStatus)->Void
    private let services:CloudflareRelayServices
    private let recovery:RemoteNetworkRecovery
    private var gateway:RemoteTunnelGateway?,socket:CloudflareRelaySocket?,agent:CloudflareRelayAgent?
    private var task:Task<Void,Never>?,probe:Task<Void,Never>?,watchdog:Task<Void,Never>?,ping:Task<Void,Never>?,pingDeadline:Task<Void,Never>?
    private var generation=UUID(),connection=UUID()
    private var qualityTracker = RemoteTunnelQualityTracker()
    private var monitor:RemoteTunnelMonitor?
    private var connectedAt:TimeInterval?,heartbeat = UUID()
    public private(set) var status=RemoteTunnelStatus()
    public var accessKey:String? {gateway?.accessKey}
    public var shareURL:URL? {guard status.ready,let origin=status.publicURL,let gateway else {return nil};return URL(string:origin+(gateway.pinEnabled ? "/":"/#access="+gateway.accessKey))}
    public func setPIN(_ pin:RemoteTunnelPIN?,accessKey:String) {gateway?.setPIN(pin,accessKey:accessKey)}
    public init(handler:@escaping @MainActor(RemoteHTTPRequest) async -> RemoteHTTPResponse,services:CloudflareRelayServices = .live,recovery:RemoteNetworkRecovery? = nil,onStatus:@escaping @MainActor(RemoteTunnelStatus)->Void) {
        self.handler=handler;self.services=services;self.recovery = recovery ?? RemoteNetworkRecovery();self.onStatus=onStatus
    }
    private func publish(_ phase:String,_ detail:String) {status.phase=phase;status.detail=detail;onStatus(status)}
    public func stop() {
        recovery.stop();connectedAt = nil;heartbeat = UUID()
        monitor?.stop();monitor = nil
        generation=UUID();connection=UUID();task?.cancel();probe?.cancel();watchdog?.cancel();ping?.cancel()
        pingDeadline?.cancel();pingDeadline=nil
        task=nil;probe=nil;watchdog=nil;ping=nil;socket?.cancel();agent?.cancel();socket=nil;agent=nil
        gateway?.stop();gateway=nil;status=RemoteTunnelStatus();onStatus(status)
    }
    public func start(_ supplied:RemoteTunnelConfiguration,credential:Data,pin:RemoteTunnelPIN? = nil) async throws {
        stop();qualityTracker = RemoteTunnelQualityTracker();let config=try supplied.validated()
        guard config.provider == .https,credential.count<=65536 else {throw AppError.message("HTTPS 중계 설정을 확인해주세요.")}
        let secret=try JSONDecoder().decode(CloudflareRelayCredential.self,from:credential).validated(for:config.publicURL)
        let epoch=UUID();generation=epoch;status.provider = .https;status.publicURL=config.publicURL
        publish("starting","HTTPS 443 인증 접속을 준비하고 있습니다…")
        do {
            let gateway=try RemoteTunnelGateway(pin:pin,handler:handler);self.gateway=gateway
            try await gateway.start(port:0);try Task.checkCancellation()
            guard generation==epoch,let address=gateway.localURL,let local=URL(string:address) else {gateway.stop();throw CancellationError()}
            try gateway.setOrigin(config.publicURL)
            status.localURL=local.absoluteString
            var endpoint=URLComponents(string:config.publicURL)!;endpoint.scheme="wss";endpoint.path="/_autoapprove/connector"
            var request=URLRequest(url:endpoint.url!);request.setValue("Bearer "+secret.key,forHTTPHeaderField:"Authorization");request.setValue("2",forHTTPHeaderField:"X-AutoApprove-Relay");request.timeoutInterval=20
            recovery.start { [weak self] in self?.networkAvailable() }
            task=Task { [weak self] in
                var backoff = RemoteReconnectBackoff()
                while !Task.isCancelled {
                    guard let self,self.generation==epoch,!Task.isCancelled else {return}
                    let id=UUID();self.connection=id;self.connectedAt = nil
                    let socket=self.services.connect(request);self.socket=socket
                    let agent=CloudflareRelayAgent(socket:socket,localURL:local,host:endpoint.host!,diagnostic:self.services.diagnostic);self.agent=agent
                    self.publish(backoff.failures==0 ? "connecting" : "reconnecting",backoff.failures==0 ? "Cloudflare에 HTTPS 443으로 연결하고 있습니다…" : "HTTPS 연결을 자동으로 복구하고 있습니다…")
                    self.watchdog=Task {try? await Task.sleep(for:.seconds(25));guard !Task.isCancelled,self.generation==epoch,self.connection==id else {return};socket.cancel()}
                    do {try await agent.run { [weak self] features in await self?.connected(epoch:epoch,id:id,features:features) }} catch {self.services.diagnostic("connector_error_"+String((error as? URLError)?.code.rawValue ?? 0))}
                    agent.cancel()
                    guard self.generation==epoch,self.connection==id,!Task.isCancelled else {return}
                    let response = socket.task.response as? HTTPURLResponse
                    let healthyFor = self.connectedAt.map {ProcessInfo.processInfo.systemUptime-$0} ?? 0
                    self.watchdog?.cancel();self.ping?.cancel();self.pingDeadline?.cancel();self.probe?.cancel()
                    self.monitor?.stop();self.socket = nil;self.agent = nil;self.connectedAt = nil
                    guard self.generation==epoch,!Task.isCancelled else {return}
                    if let status = response?.statusCode,[401,403].contains(status) {
                        self.stop();self.status.provider = .https;self.publish("failed","Cloudflare HTTPS 중계 인증을 확인하지 못했습니다. Cloudflare 승인과 도메인 연결을 확인한 뒤 다시 연결해주세요.");return
                    }
                    self.qualityTracker.reconnected();self.status.quality = self.qualityTracker.snapshot()
                    if self.status.ready {backoff = RemoteReconnectBackoff()}
                    let delay = backoff.nextDelay(healthyFor:healthyFor)
                    let retryAfter = response?.value(forHTTPHeaderField:"Retry-After").flatMap(Double.init).flatMap {$0.isFinite ? min(300,max(0,$0)):nil} ?? 0
                    self.publish("reconnecting","HTTPS 연결을 기다리고 있습니다. 네트워크가 돌아오면 자동으로 다시 연결합니다.")
                    do {try await self.recovery.wait(seconds:max(delay,retryAfter),interruptible:retryAfter <= 0)} catch {return}
                }
            }
        } catch {if generation==epoch {stop();status.provider = .https;publish("failed","HTTPS 접속을 준비하지 못했습니다. 다시 연결해주세요.")};throw error}
    }
    private func connected(epoch:UUID,id:UUID,features:UInt8) {
        guard generation==epoch,connection==id,let socket else {return}
        connectedAt = ProcessInfo.processInfo.systemUptime
        qualityTracker.relayFeatures(features);status.quality = qualityTracker.snapshot()
        watchdog?.cancel();ping?.cancel()
        ping=Task { [weak self] in
            while !Task.isCancelled {
                do {try await Task.sleep(for:.seconds(20))} catch {return}
                guard let self,self.generation==epoch,self.connection==id else {return}
                self.checkSocket(socket,epoch:epoch,id:id,timeout:10)
            }
        }
        verify(epoch:epoch,id:id)
    }
    private func networkAvailable() {
        guard let socket else {return}
        if connectedAt == nil {socket.cancel()}
        else {checkSocket(socket,epoch:generation,id:connection,timeout:3)}
    }
    private func checkSocket(_ socket:CloudflareRelaySocket,epoch:UUID,id:UUID,timeout:TimeInterval) {
        let token = UUID();heartbeat = token;pingDeadline?.cancel()
        let deadline = Task { [weak self] in
            do {try await Task.sleep(for:.seconds(timeout))} catch {return}
            guard let self,self.generation == epoch,self.connection == id,self.heartbeat == token else {return};socket.cancel()
        }
        pingDeadline = deadline;let began = ProcessInfo.processInfo.systemUptime
        socket.task.sendPing { [weak self] error in
            deadline.cancel()
            Task { @MainActor [weak self] in
                guard let self,self.generation == epoch,self.connection == id,self.heartbeat == token else {return}
                if error != nil {socket.cancel();return}
                self.qualityTracker.connectorPing(milliseconds:(ProcessInfo.processInfo.systemUptime-began)*1000)
                self.status.quality = self.qualityTracker.snapshot();self.onStatus(self.status)
            }
        }
    }
    private func verify(epoch:UUID,id:UUID,background:Bool = false) {
        guard let origin=status.publicURL,let gateway else {return}
        probe?.cancel();if !background {publish("checking","공개 HTTPS 주소가 이 Mac으로 연결되는지 확인 중…")}
        probe=Task { [weak self] in
            guard let self else {return}
            for _ in 0..<(background ? 1:15) {
                guard !Task.isCancelled,self.generation==epoch,self.connection==id else {return}
                do {
                    var request=URLRequest(url:URL(string:origin+"/auth/probe")!);request.timeoutInterval=3
                    let reply=try await self.services.probe(request)
                    guard !Task.isCancelled,self.generation==epoch,self.connection==id else {return}
                    if reply.status==200,reply.data.count<1024,let value=try JSONSerialization.jsonObject(with:reply.data) as? [String:String],value["probe"]==gateway.probe {
                        self.publish("ready","HTTPS 443 연결됨 · 실시간 터미널")
                        self.monitor?.stop()
                        let monitor = RemoteTunnelMonitor(origin:origin,nonce:gateway.probe,tracker:self.qualityTracker,probe:self.services.probe,onUpdate:{ [weak self] quality in
                            guard let self,self.generation == epoch,self.connection == id else {return};self.status.quality = quality;self.onStatus(self.status)
                        })
                        self.monitor = monitor;monitor.start();return
                    }
                } catch {}
                do {try await Task.sleep(for:.seconds(1))} catch {return}
            }
            guard !Task.isCancelled,self.generation==epoch,self.connection==id else {return}
            self.publish("routeRequired","HTTPS 중계가 연결됐습니다. 도메인 반영을 기다리며 공개 주소를 자동으로 다시 확인합니다. ‘공개 주소 확인’으로 바로 확인할 수도 있습니다.")
            do {try await self.recovery.wait(seconds:30)} catch {return}
            guard !Task.isCancelled,self.generation == epoch,self.connection == id,self.status.phase == "routeRequired" else {return}
            self.verify(epoch:epoch,id:id,background:true)
        }
    }
    public func checkPublicURL() {if status.phase=="routeRequired" {verify(epoch:generation,id:connection)}}
    public func measureConnection() async {await monitor?.sample()}
}
