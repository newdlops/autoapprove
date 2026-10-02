import Foundation
import Network
import Darwin

/// A bounded unicast fallback for LANs that do not deliver Bonjour advertisements.
/// It asks only AutoApprove's default HTTP port; it never reads a router's DHCP table.
enum RemotePeerDiscovery {
    struct Found: Sendable {
        let id: String
        let name: String
        let address: String
    }

    static func addresses() -> [String] {
        let interfaces = RemoteLAN.interfaces()
        var seen = Set(interfaces.map { "http://\($0.address):8765" })
        return Array(interfaces.flatMap { RemoteNetworkAddress.discoveryURLs(address: $0.address, netmask: $0.netmask) }
            .filter { seen.insert($0).inserted }.prefix(512))
    }

    static func find(_ address: String) async -> Found? {
        guard !Task.isCancelled, let endpoint = try? RemoteNetworkAddress.endpoint(address) else { return nil }
        do {
            let response = try await RemoteHTTPExchange(endpoint: endpoint, path: "/api/discovery", method: "GET", body: Data(), timeout: 0.8).run()
            if response.status == 200,
               let object = try JSONSerialization.jsonObject(with: response.body) as? JSONObject,
               object["service"] as? String == "autoapprove", object["version"] as? Int == 1,
               let id = object["id"] as? String, UUID(uuidString: id) != nil,
               let name = object["name"] as? String, !name.isEmpty {
                return Found(id: id, name: String(name.prefix(100)), address: address)
            }
            // Older AutoApprove clients expose their identity through /api/state.
            if response.status == 404 && !Task.isCancelled {
                let legacy = try await RemoteHTTPExchange(endpoint: endpoint, path: "/api/state", method: "GET", body: Data(), timeout: 1).run()
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                guard legacy.status == 200, let state = try? decoder.decode(RemoteNodeState.self, from: legacy.body), UUID(uuidString: state.id) != nil else { return nil }
                return Found(id: state.id, name: String(state.name.prefix(100)), address: address)
            }
        } catch { }
        return nil
    }
}

extension RemoteNetworkAddress {
    /// Only the connected private IPv4 subnet, bounded to its local /24 on larger LANs.
    public static func discoveryURLs(address: String, netmask: String) -> [String] {
        guard let ip = IPv4Address(address), let mask = IPv4Address(netmask) else { return [] }
        let bytes = Array(ip.rawValue)
        guard bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 192 && bytes[1] == 168) else { return [] }
        func number(_ value: Data) -> UInt32 { value.reduce(0) { ($0 << 8) | UInt32($1) } }
        let host = number(ip.rawValue), originalMask = number(mask.rawValue)
        let inverse = ~originalMask
        guard originalMask != 0, inverse & (inverse &+ 1) == 0 else { return [] }
        let boundedMask = originalMask | 0xffffff00
        let network = host & boundedMask, broadcast = network | ~boundedMask
        guard broadcast > network + 1 else { return [] }
        return (network + 1..<broadcast).filter { $0 != host }.map { value in
            "http://\((value >> 24) & 255).\((value >> 16) & 255).\((value >> 8) & 255).\(value & 255):8765"
        }
    }
}
