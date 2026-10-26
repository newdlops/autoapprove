import Foundation
import AutoApproveCore

private struct TunnelTestFailure: Error { let message:String; init(_ message:String){self.message=message} }

extension ApprovalTests {
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
