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
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var candidates: [(String, [String])] = [], own = Set<String>()
        var cursor = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = entry.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == AF_INET,
                  let mask = entry.pointee.ifa_netmask else { continue }
            func numeric(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
                var value = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, socklen_t(address.pointee.sa_len), &value, socklen_t(value.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return String(cString: value)
            }
            guard let ip = numeric(address), let netmask = numeric(mask) else { continue }
            own.insert("http://\(ip):8765")
            candidates.append((String(cString: entry.pointee.ifa_name), RemoteNetworkAddress.discoveryURLs(address: ip, netmask: netmask)))
        }
        var seen = own
        return Array(candidates.sorted { $0.0 < $1.0 }.flatMap(\.1).filter { seen.insert($0).inserted }.prefix(512))
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
