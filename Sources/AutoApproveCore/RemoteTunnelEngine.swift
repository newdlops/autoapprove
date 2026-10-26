import Foundation

extension ApprovalEngine {
    public var hasTunnelConfiguration:Bool {store.value("remoteTunnel") != nil}
    private func cloudflareOwner() throws -> String {
        if let saved=store.value("cloudflareOwner"),UUID(uuidString:saved) != nil {return saved}
        let owner=UUID().uuidString.lowercased();try store.set("cloudflareOwner",owner);return owner
    }
    private func cloudflare() throws -> CloudflareOnboarding {
        if let cloudflareClient {return cloudflareClient}
        let client=CloudflareOnboarding(directory:paths.directory,owner:try cloudflareOwner(),services:cloudflareServices,onStatus:{[weak self] status in guard self?.cloudflareSetupProvider == .managed else {return};self?.cloudflareStatus=status})
        cloudflareClient=client;return client
    }
    private func workers() throws -> CloudflareWorkersOnboarding {
        if let workersClient {return workersClient}
        let client=CloudflareWorkersOnboarding(directory:paths.directory,owner:try cloudflareOwner(),http:cloudflareServices,tools:workersServices,onStatus:{[weak self] status in guard self?.cloudflareSetupProvider == .https else {return};self?.cloudflareStatus=status})
        workersClient=client;return client
    }
    public var cloudflareApprovalURL:URL? {cloudflareSetupProvider == .https ? workersClient?.approvalURL:cloudflareClient?.approvalURL}
    public func cloudflareAddress(domainID:String,subdomain:String = "aa",provider:RemoteTunnelProvider = .managed)->String? {
        provider == .https ? workersClient?.proposedURL(for:domainID,subdomain:subdomain):cloudflareClient?.proposedURL(for:domainID,subdomain:subdomain)
    }
    public func loadCloudflareDomains(provider:RemoteTunnelProvider = .managed) async throws {
        cloudflareSetupProvider=provider
        if provider == .https {try await workers().restore()} else {try await cloudflare().restore()}
    }
    public func authorizeCloudflare(executable:String = "",provider:RemoteTunnelProvider = .managed) async throws {
        guard !tunnelStatus.active else {throw AppError.message("진행 중인 터널 연결을 종료한 뒤 승인해주세요.")}
        cloudflareSetupProvider=provider
        do {
            if provider == .https {try await workers().authorize();return}
            var tool=executable.isEmpty ? tunnelToolPath : executable
            if tool == nil {
                cloudflareStatus.phase="installing";cloudflareStatus.detail="Cloudflare 연결 도구를 준비하고 있습니다…"
                tool=try await RemoteTunnelTool.install(directory:paths.directory)
            }
            try Task.checkCancellation()
            guard let tool,FileManager.default.isExecutableFile(atPath:tool) else {throw AppError.message("Cloudflare 연결 도구를 실행할 수 없습니다.")}
            try await cloudflare().authorize(executable:tool)
        } catch {
            if error is CancellationError || Task.isCancelled {cancelCloudflareSetup();throw CancellationError()}
            cloudflareStatus.phase="failed";cloudflareStatus.detail=error.localizedDescription;throw error
        }
    }
    public func cancelCloudflareSetup() {
        if cloudflareSetupProvider == .https {if let workersClient {workersClient.cancel()} else {cloudflareStatus=CloudflareSetupStatus()}}
        else {if let cloudflareClient {cloudflareClient.cancel()} else {cloudflareStatus=CloudflareSetupStatus()}}
    }
    public func connectCloudflare(domainID:String,subdomain:String = "aa",executable:String = "",provider:RemoteTunnelProvider = .managed) async throws {
        guard !tunnelStatus.active else {throw AppError.message("진행 중인 터널 연결을 종료한 뒤 도메인을 선택해주세요.")}
        cloudflareSetupProvider=provider
        if provider == .https {
            let origin=try await workers().provision(domainID:domainID,subdomain:subdomain)
            try Task.checkCancellation();var configuration=RemoteTunnelConfiguration();configuration.provider = .https;configuration.publicURL=origin
            try await connectTunnel(configuration);return
        }
        let connection=try await cloudflare().provision(domainID:domainID,subdomain:subdomain)
        try Task.checkCancellation()
        var configuration=RemoteTunnelConfiguration();configuration.provider = .managed
        configuration.tunnelID=connection.tunnelID;configuration.publicURL=connection.publicURL;configuration.executable=executable
        try await connectTunnel(configuration)
    }
    public var tunnelConfiguration: RemoteTunnelConfiguration {
        guard let raw=store.value("remoteTunnel"), let data=raw.data(using:.utf8), let value=try? JSONDecoder().decode(RemoteTunnelConfiguration.self,from:data) else { return RemoteTunnelConfiguration() }
        return value
    }
    public var tunnelShareURL: URL? { relayController?.shareURL ?? tunnelController?.shareURL }
    public var tunnelAccessKey: String? { relayController?.accessKey ?? tunnelController?.accessKey }
    public var tunnelToolPath: String? { RemoteTunnelController.executable(directory:paths.directory) }
    public func measureTunnelConnection() async {
        if let relayController {await relayController.measureConnection()} else {await tunnelController?.measureConnection()}
    }
    /// One explicit user action prepares prerequisites and starts the tunnel.
    public func connectTunnel(_ supplied:RemoteTunnelConfiguration,token:String = "") async throws {
        try Task.checkCancellation()
        guard !tunnelStatus.active else {throw AppError.message("진행 중인 연결을 종료한 뒤 다시 시작해주세요.")}
        var configuration=supplied
        if configuration.provider != .quick {configuration.publicURL=try RemoteTunnelSetup.origin(configuration.publicURL)}
        configuration=try configuration.validated()
        let secret=configuration.provider == .named ? try RemoteTunnelSetup.token(token) : ""
        let id=UUID();tunnelSetupID=id;tunnelRestoreAttempted=true
        defer {if tunnelSetupID == id {tunnelSetupID=nil}}
        func current() throws {try Task.checkCancellation();guard tunnelSetupID == id else {throw CancellationError()}}
        func progress(_ phase:String,_ detail:String) {tunnelStatus.provider=configuration.provider;tunnelStatus.phase=phase;tunnelStatus.detail=detail}
        do {
            if configuration.provider.usesCloudflared, configuration.executable.isEmpty, tunnelToolPath == nil {
                progress("installing","Cloudflare 연결 도구를 내려받고 확인하고 있습니다…")
                _ = try await RemoteTunnelTool.install(directory:paths.directory)
                try current();objectWillChange.send()
            }
            if !webStatus.ready {
                progress("preparing","이 Mac의 웹 접속을 준비하고 있습니다…")
                try setWebEnabled(true)
                for _ in 0..<200 where !webStatus.ready {try current();try await Task.sleep(for:.milliseconds(25))}
                try current()
                guard webStatus.ready else {throw AppError.message("웹 접속을 열지 못했습니다. 연결 설정의 웹 접속 상태를 확인하고 다시 시도해주세요.")}
            }
            try current();try await startTunnel(configuration,token:secret)
        } catch {
            if tunnelSetupID == id {
                if error is CancellationError {try? stopTunnel()}
                else {tunnelStatus.phase="failed";tunnelStatus.detail=error.localizedDescription}
            }
            throw error
        }
    }
    public func checkTunnelAddress() {tunnelController?.checkPublicURL();relayController?.checkPublicURL()}
    public func installTunnelTool() async throws {
        guard !tunnelStatus.active else { throw AppError.message("터널 연결을 종료한 뒤 도구를 설치해주세요.") }
        _ = try await RemoteTunnelTool.install(directory:paths.directory)
        objectWillChange.send()
    }
    public func startTunnel(_ supplied: RemoteTunnelConfiguration, token: String = "") async throws {
        let startEpoch = UUID();tunnelStartEpoch = startEpoch
        tunnelRestoreAttempted=true
        var configuration=try supplied.validated(); configuration.enabled=true
        let pin=try readTunnelPIN();tunnelPINConfigured=pin != nil
        guard webStatus.ready, let service=webService else { throw AppError.message("먼저 같은 네트워크에서 웹 접속을 켜주세요.") }
        let secret:String
        if configuration.provider == .named {
            if !token.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                let value=try RemoteTunnelSetup.token(token)
                guard value.utf8.count <= 16384, !value.contains("\0"), !value.contains("\n") else { throw AppError.message("Cloudflare 터널 토큰을 확인해주세요.") }
                try RemoteTunnelCredentials.save(value,directory:paths.directory); secret=value
            } else { secret=try RemoteTunnelCredentials.read(paths.directory) }
        } else { secret="" }
        let handler:@MainActor(RemoteHTTPRequest) async -> RemoteHTTPResponse = { [weak service,weak self] request in
            guard let service, let self, self.webService === service, self.webStatus.ready else { return .error(RemoteHTTPError(503,"웹 접속이 종료되었습니다.")) }
            return await service.handle(request)
        }
        if configuration.provider == .https {
            guard let credential=try cloudflareServices.readSecret(paths.directory,"cloudflare-worker") else {throw AppError.message("Cloudflare Workers 승인을 마치고 도메인을 연결해주세요.")}
            _ = try JSONDecoder().decode(CloudflareRelayCredential.self,from:credential).validated(for:configuration.publicURL)
            // Management API outages must not take an existing relay offline.
            // The live greeting reports whether the upgraded input is available.
            _ = try? await workers().refreshRelayIfNeeded(origin:configuration.publicURL)
            try Task.checkCancellation()
            guard tunnelStartEpoch == startEpoch,webService === service,webStatus.ready else {throw CancellationError()}
            try store.set("remoteTunnel",String(decoding:JSONEncoder().encode(configuration),as:UTF8.self))
            tunnelController?.stop();tunnelController=nil;relayController?.stop()
            let controller=CloudflareRelayController(handler:handler,services:relayServices,onStatus:{[weak self] status in self?.tunnelStatus=status})
            relayController=controller;try await controller.start(configuration,credential:credential,pin:pin);return
        }
        try store.set("remoteTunnel",String(decoding:JSONEncoder().encode(configuration),as:UTF8.self))
        relayController?.stop();relayController=nil;tunnelController?.stop()
        let controller=RemoteTunnelController(directory:paths.directory,handler:handler,onStatus:{ [weak self] status in self?.tunnelStatus=status })
        tunnelController=controller
        let credential:Data?
        if configuration.provider == .managed,let id=configuration.tunnelID {credential=try cloudflareServices.readSecret(paths.directory,"cloudflare-tunnel:"+id.lowercased())}
        else {credential=nil}
        try await controller.start(configuration,token:secret,credentials:credential,pin:pin)
    }
    public func stopTunnel() throws {
        tunnelStartEpoch = UUID()
        tunnelSetupID=nil
        var configuration=tunnelConfiguration; configuration.enabled=false
        tunnelRestoreAttempted=true
        tunnelController?.stop(); tunnelController=nil; tunnelStatus=RemoteTunnelStatus()
        relayController?.stop();relayController=nil
        // Revoke access even if persisting the disabled setting fails.
        try store.set("remoteTunnel",String(decoding:JSONEncoder().encode(configuration),as:UTF8.self))
    }
    func restoreTunnelIfRequested() {
        guard tunnelConfiguration.enabled, tunnelController == nil,relayController == nil, !tunnelRestoreAttempted else { return }
        tunnelRestoreAttempted=true
        Task { [weak self] in
            guard let self, self.tunnelController == nil,self.relayController == nil, self.tunnelConfiguration.enabled, self.webStatus.ready else { return }
            do { try await self.startTunnel(self.tunnelConfiguration) }
            catch { if self.tunnelConfiguration.enabled && self.webStatus.ready { self.tunnelStatus.phase="failed"; self.tunnelStatus.detail=error.localizedDescription } }
        }
    }
}
