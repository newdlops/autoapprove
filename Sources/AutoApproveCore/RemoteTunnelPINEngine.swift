import Foundation

extension ApprovalEngine {
    func readTunnelPIN() throws -> RemoteTunnelPIN? {
        do {
            guard let data=try cloudflareServices.readSecret(paths.directory,"remote-tunnel-pin"),!data.isEmpty else {return nil}
            return try RemoteTunnelPIN.decode(data)
        } catch {throw AppError.message("키체인에서 접속 PIN을 읽지 못했습니다. 키체인을 잠금 해제하거나 PIN을 다시 설정해주세요.")}
    }
    public func loadTunnelPIN() throws {tunnelPINConfigured=try readTunnelPIN() != nil}
    public func setTunnelPIN(_ pin:String) async throws {
        try Task.checkCancellation()
        guard tunnelPINSetupID==nil else {throw AppError.message("접속 PIN을 저장하고 있습니다.")}
        let id=UUID();tunnelPINSetupID=id;defer{if tunnelPINSetupID==id {tunnelPINSetupID=nil}}
        let credential=try await Task.detached(priority:.userInitiated) {try RemoteTunnelPIN.create(pin)}.value
        try Task.checkCancellation();guard tunnelPINSetupID==id else {throw CancellationError()}
        let nextKey=try RemoteTunnelGateway.random()
        do {try cloudflareServices.saveSecret(paths.directory,"remote-tunnel-pin",JSONEncoder().encode(credential))}
        catch {throw AppError.message("접속 PIN을 키체인에 저장하지 못했습니다. 키체인을 잠금 해제한 뒤 다시 시도해주세요.")}
        tunnelController?.setPIN(credential,accessKey:nextKey);relayController?.setPIN(credential,accessKey:nextKey)
        tunnelPINConfigured=true
        agentAccounts.stop()
    }
    public func clearTunnelPIN() throws {
        let nextKey=try RemoteTunnelGateway.random()
        do {try cloudflareServices.saveSecret(paths.directory,"remote-tunnel-pin",Data())}
        catch {throw AppError.message("키체인의 접속 PIN을 해제하지 못했습니다. 다시 시도해주세요.")}
        tunnelPINSetupID=nil;tunnelController?.setPIN(nil,accessKey:nextKey);relayController?.setPIN(nil,accessKey:nextKey);tunnelPINConfigured=false
        agentAccounts.stop()
    }
}
