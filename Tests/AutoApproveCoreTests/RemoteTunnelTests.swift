import Foundation
import AutoApproveCore

private struct TunnelTestFailure: Error { let message:String; init(_ message:String){self.message=message} }

extension ApprovalTests {
    func testTunnelSetupNormalizesDomainsWithoutWeakeningOriginRules() throws {
        for value in ["terminal.example.com"," Terminal.Example.com/ ","https://terminal.example.com:443/"] {
            try expectEqual(try RemoteTunnelSetup.origin(value),"https://terminal.example.com")
        }
        for value in ["","localhost","127.0.0.1","name.local","http://terminal.example.com","terminal.example.com/path","terminal.example.com?key=secret","user@terminal.example.com","terminal.example.com:8766"] {
            try expectThrows(try RemoteTunnelSetup.origin(value))
        }
    }
    func testTunnelSetupExtractsOnlyTokenFromPastedInstallCommands() throws {
        let token="eyJhIjoiSyntheticFixtureToken0123456789_-+/="
        for value in [token,"  "+token+"\n","sudo cloudflared service install "+token,
                      "brew install cloudflared && sudo cloudflared service install "+token,
                      "/opt/homebrew/bin/cloudflared service install '"+token+"'",
                      "cloudflared tunnel run --token "+token,"cloudflared tunnel run --token=\""+token+"\""] {
            try expectEqual(try RemoteTunnelSetup.token(value),token)
        }
        try expectEqual(try RemoteTunnelSetup.token(" \n"),"")
        for value in ["short","token\0value","sudo cloudflared service install", "echo "+token,
                      "cloudflared service install "+token+"; touch /tmp/should-never-run",
                      "cloudflared tunnel run --token-file /tmp/token",String(repeating:"x",count:32769)] {
            try expectThrows(try RemoteTunnelSetup.token(value))
        }
    }
    func testCancelledTunnelSetupKeepsWebAndTunnelOff() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-setup-cancel-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let engine=try ApprovalEngine(paths:AppPaths(directory:root),processReader:{[]},webLoopbackOnly:true)
        defer {engine.stop()}
        let task=Task {try await engine.connectTunnel(RemoteTunnelConfiguration())};task.cancel()
        do {try await task.value;throw TunnelTestFailure("Cancelled setup must not start")}
        catch is CancellationError {} catch {throw error}
        try expectFalse(engine.webStatus.enabled);try expectFalse(engine.tunnelStatus.active)
        try expectFalse(engine.tunnelConfiguration.enabled)
    }
    func testTunnelSetupAutomaticallyOpensWebBeforeLaunchingConnector() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-setup-auto-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let engine=try ApprovalEngine(paths:AppPaths(directory:root),processReader:{[]},webLoopbackOnly:true)
        defer {engine.stop()}
        var configuration=RemoteTunnelConfiguration();configuration.executable="/usr/bin/true"
        try expectFalse(engine.webStatus.enabled)
        try await engine.connectTunnel(configuration)
        try expect(engine.webStatus.ready);try expect(engine.tunnelStatus.active)
        try expect(engine.tunnelStatus.localURL?.hasPrefix("http://127.0.0.1:") == true)
        try expectNil(engine.tunnelShareURL)
        try engine.stopTunnel();try expectFalse(engine.tunnelStatus.active)
        try expectFalse(engine.tunnelConfiguration.enabled)
    }
    func testTunnelOriginsRejectAuthorityConfusionAndPrivateAddresses() throws {
        try expectEqual(try RemoteTunnelConfiguration.origin(" https://Terminal.Example.com:443/ "),"https://terminal.example.com")
        for value in ["http://terminal.example.com","https://127.0.0.1","https://10.0.0.1","https://name.local","https://example.com@127.0.0.1","https://user@example.com","https://example.com/path","https://example.com?key=secret","https://example.com#access=secret","https://example.com:8766","https://.example.com","https://x..example.com","https://-x.example.com","https://[::1]"] {
            do {_ = try RemoteTunnelConfiguration.origin(value);throw TunnelTestFailure("Accepted unsafe tunnel origin: \(value)")}
            catch is TunnelTestFailure {throw TunnelTestFailure("Accepted unsafe tunnel origin: \(value)")}
            catch {}
        }
    }
    func testTunnelConfigurationDefaultsOffAndRoundTripsWithoutCredentials() throws {
        var configuration=RemoteTunnelConfiguration()
        try expectEqual(configuration.enabled,false);try expectEqual(configuration.provider,.quick)
        configuration.provider = .external;configuration.publicURL="https://terminal.example.com/"
        let value=try configuration.validated()
        try expectEqual(value.publicURL,"https://terminal.example.com")
        try expectEqual(try JSONDecoder().decode(RemoteTunnelConfiguration.self,from:JSONEncoder().encode(value)),value)
        let encoded=try JSONEncoder().encode(value)
        try expect(!String(decoding:encoded,as:UTF8.self).contains("token"))
        configuration.port=0
        do {_ = try configuration.validated();throw TunnelTestFailure("Accepted zero tunnel port")}
        catch is TunnelTestFailure {throw TunnelTestFailure("Accepted zero tunnel port")}
        catch {}
    }
}
