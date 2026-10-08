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
        var release: RemoteWebVersion? = nil
        var urls: [String] = []
        var port: UInt16? = nil
        var portal = false
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
            let response = try await RemoteDiscoveryTraffic.shared.get(endpoint, path: "/api/discovery", timeout: 0.8)
            if response.status == 200, let peer = decode(response.body, address: address) { return peer }
            // Older AutoApprove clients expose their identity through /api/state.
            if response.status == 404 && !Task.isCancelled {
                let legacy = try await RemoteDiscoveryTraffic.shared.get(endpoint, path: "/api/state", timeout: 1)
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                guard legacy.status == 200, let state = try? decoder.decode(RemoteNodeState.self, from: legacy.body), UUID(uuidString: state.id) != nil else { return nil }
                return Found(id: state.id, name: String(state.name.prefix(100)), address: address,
                    urls: state.webURLs ?? [], port: state.webPort)
            }
        } catch { }
        return nil
    }

    static func probe(_ endpoint: NWEndpoint, expectedID: String, address: String = "") async -> Found? {
        do {
            let response = try await RemoteDiscoveryTraffic.shared.get(endpoint, path: "/api/discovery", expectedID: expectedID)
            if response.status == 404 {
                let legacy = try await RemoteDiscoveryTraffic.shared.get(endpoint, path: "/api/state", expectedID: expectedID)
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                if legacy.status == 200, let state = try? decoder.decode(RemoteNodeState.self, from: legacy.body), state.id == expectedID {
                    return Found(id: state.id, name: String(state.name.prefix(100)), address: address, release: state.release, urls: state.webURLs ?? [], port: state.webPort)
                }
                return nil
            }
            guard response.status == 200, let peer = decode(response.body, address: address), peer.id == expectedID else { return nil }
            return peer
        } catch { return nil }
    }
    private static func decode(_ data: Data, address: String) -> Found? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? JSONObject,
              object["service"] as? String == "autoapprove", object["version"] as? Int == 1,
              let id = object["id"] as? String, UUID(uuidString: id) != nil,
              let name = object["name"] as? String, !name.isEmpty else { return nil }
        var release: RemoteWebVersion?
        if let value = object["release"], let data = try? JSONSerialization.data(withJSONObject: value),
           let decoded = try? JSONDecoder().decode(RemoteWebVersion.self, from: data), decoded.isCompatible { release = decoded }
        let port = (object["port"] as? Int).flatMap(UInt16.init(exactly:)).flatMap { $0 > 0 ? $0 : nil }
        return Found(id: id, name: String(name.prefix(100)), address: address, release: release,
            urls: Array((object["urls"] as? [String] ?? []).prefix(16)), port: port, portal: object["portal"] as? Bool ?? false)
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
        return (network + 1..<broadcast).filter { $0 != host }.sorted {
            let first = abs(Int64($0) - Int64(host)), second = abs(Int64($1) - Int64(host))
            return (first, $0) < (second, $1)
        }.map { value in
            "http://\((value >> 24) & 255).\((value >> 16) & 255).\((value >> 8) & 255).\(value & 255):8765"
        }
    }
}
