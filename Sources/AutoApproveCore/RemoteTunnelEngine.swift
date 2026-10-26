import Foundation

extension ApprovalEngine {
    public var hasTunnelConfiguration:Bool {store.value("remoteTunnel") != nil}
    private func cloudflare() throws -> CloudflareOnboarding {
        if let cloudflareClient {return cloudflareClient}
        let owner:String
        if let saved=store.value("cloudflareOwner"),UUID(uuidString:saved) != nil {owner=saved}
        else {owner=UUID().uuidString.lowercased();try store.set("cloudflareOwner",owner)}
        let client=CloudflareOnboarding(directory:paths.directory,owner:owner,services:cloudflareServices,onStatus:{[weak self] status in self?.cloudflareStatus=status})
        cloudflareClient=client;return client
    }
    public var cloudflareApprovalURL:URL? {cloudflareClient?.approvalURL}
    public func cloudflareAddress(domainID:String)->String? {cloudflareClient?.proposedURL(for:domainID)}
    public func loadCloudflareDomains() async throws {try await cloudflare().restore()}
    public func authorizeCloudflare(executable:String = "") async throws {
        guard !tunnelStatus.active else {throw AppError.message("진행 중인 터널 연결을 종료한 뒤 승인해주세요.")}
        do {
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
        if let cloudflareClient {cloudflareClient.cancel()} else {cloudflareStatus=CloudflareSetupStatus()}
    }
    public func connectCloudflare(domainID:String,executable:String = "") async throws {
        guard !tunnelStatus.active else {throw AppError.message("진행 중인 터널 연결을 종료한 뒤 도메인을 선택해주세요.")}
        let connection=try await cloudflare().provision(domainID:domainID)
        try Task.checkCancellation()
        var configuration=RemoteTunnelConfiguration();configuration.provider = .managed
        configuration.tunnelID=connection.tunnelID;configuration.publicURL=connection.publicURL;configuration.executable=executable
        try await connectTunnel(configuration)
    }
    public var tunnelConfiguration: RemoteTunnelConfiguration {
        guard let raw=store.value("remoteTunnel"), let data=raw.data(using:.utf8), let value=try? JSONDecoder().decode(RemoteTunnelConfiguration.self,from:data) else { return RemoteTunnelConfiguration() }
        return value
    }
    public var tunnelShareURL: URL? { tunnelController?.shareURL }
    public var tunnelAccessKey: String? { tunnelController?.accessKey }
    public var tunnelToolPath: String? { RemoteTunnelController.executable(directory:paths.directory) }
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
            if configuration.provider != .external, configuration.executable.isEmpty, tunnelToolPath == nil {
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
    public func checkTunnelAddress() {tunnelController?.checkPublicURL()}
    public func installTunnelTool() async throws {
        guard !tunnelStatus.active else { throw AppError.message("터널 연결을 종료한 뒤 도구를 설치해주세요.") }
        _ = try await RemoteTunnelTool.install(directory:paths.directory)
        objectWillChange.send()
    }
    public func startTunnel(_ supplied: RemoteTunnelConfiguration, token: String = "") async throws {
        tunnelRestoreAttempted=true
        var configuration=try supplied.validated(); configuration.enabled=true
        guard webStatus.ready, let service=webService else { throw AppError.message("먼저 같은 네트워크에서 웹 접속을 켜주세요.") }
        let secret:String
        if configuration.provider == .named {
            if !token.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                let value=try RemoteTunnelSetup.token(token)
                guard value.utf8.count <= 16384, !value.contains("\0"), !value.contains("\n") else { throw AppError.message("Cloudflare 터널 토큰을 확인해주세요.") }
                try RemoteTunnelCredentials.save(value,directory:paths.directory); secret=value
            } else { secret=try RemoteTunnelCredentials.read(paths.directory) }
        } else { secret="" }
        try store.set("remoteTunnel",String(decoding:JSONEncoder().encode(configuration),as:UTF8.self))
        tunnelController?.stop()
        let controller=RemoteTunnelController(directory:paths.directory,handler:{ [weak service,weak self] request in
            guard let service, let self, self.webService === service, self.webStatus.ready else { return .error(RemoteHTTPError(503,"웹 접속이 종료되었습니다.")) }
            return await service.handle(request)
        },onStatus:{ [weak self] status in self?.tunnelStatus=status })
        tunnelController=controller
        let credential:Data?
        if configuration.provider == .managed,let id=configuration.tunnelID {credential=try cloudflareServices.readSecret(paths.directory,"cloudflare-tunnel:"+id.lowercased())}
        else {credential=nil}
        try await controller.start(configuration,token:secret,credentials:credential)
    }
    public func stopTunnel() throws {
        tunnelSetupID=nil
        var configuration=tunnelConfiguration; configuration.enabled=false
        tunnelRestoreAttempted=true
        tunnelController?.stop(); tunnelController=nil; tunnelStatus=RemoteTunnelStatus()
        // Revoke access even if persisting the disabled setting fails.
        try store.set("remoteTunnel",String(decoding:JSONEncoder().encode(configuration),as:UTF8.self))
    }
    func restoreTunnelIfRequested() {
        guard tunnelConfiguration.enabled, tunnelController == nil, !tunnelRestoreAttempted else { return }
        tunnelRestoreAttempted=true
        Task { [weak self] in
            guard let self, self.tunnelController == nil, self.tunnelConfiguration.enabled, self.webStatus.ready else { return }
            do { try await self.startTunnel(self.tunnelConfiguration) }
            catch { if self.tunnelConfiguration.enabled && self.webStatus.ready { self.tunnelStatus.phase="failed"; self.tunnelStatus.detail=error.localizedDescription } }
        }
    }
}
