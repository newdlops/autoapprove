import Foundation
import Network
import SystemConfiguration
import Darwin

/// Physical LAN addresses shared by publishing, discovery and peer connections.
/// Tunnel addresses are never offered to a phone on the Mac's hotspot network.
public struct RemoteLANInterface: Equatable, Sendable {
    public enum Kind: Sendable { case wifi, ethernet }
    public let name: String
    public let address: String
    public let netmask: String
    public let kind: Kind
    public init(name: String, address: String, netmask: String, kind: Kind) {
        self.name = name; self.address = address; self.netmask = netmask; self.kind = kind
    }
    fileprivate var mask: UInt32? {
        guard let value = RemoteLAN.ipv4(netmask), value != 0 else { return nil }
        let inverse = ~value
        return inverse & (inverse &+ 1) == 0 ? value : nil
    }
    fileprivate func contains(_ host: UInt32) -> Bool {
        guard let own = RemoteLAN.ipv4(address), let mask else { return false }
        return own & mask == host & mask
    }
}

public enum RemoteLAN {
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var until = Date.distantPast
        var interfaces: [RemoteLANInterface] = []
    }
    private static let cache = Cache()

    public static func isPhysicalInterface(name: String, flags: UInt32) -> Bool {
        name.hasPrefix("en") && flags & UInt32(IFF_UP) != 0 && flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0
    }
    public static func interfaces(refresh: Bool = false) -> [RemoteLANInterface] {
        cache.lock.lock(); defer { cache.lock.unlock() }
        if !refresh && Date() < cache.until { return cache.interfaces }
        var kinds: [String: RemoteLANInterface.Kind] = [:]
        for interface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(interface) else { continue }
            if type == kSCNetworkInterfaceTypeIEEE80211 { kinds[name] = .wifi }
            else if type == kSCNetworkInterfaceTypeEthernet { kinds[name] = .ethernet }
        }
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { cache.until = .distantPast; cache.interfaces = []; return [] }
        defer { freeifaddrs(first) }
        var result: [RemoteLANInterface] = [], cursor = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            guard isPhysicalInterface(name: name, flags: entry.pointee.ifa_flags), let kind = kinds[name],
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == AF_INET,
                  let mask = entry.pointee.ifa_netmask else { continue }
            func numeric(_ value: UnsafeMutablePointer<sockaddr>) -> String? {
                var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(value, socklen_t(value.pointee.sa_len), &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return String(cString: text)
            }
            guard let ip = numeric(address), let netmask = numeric(mask), RemoteNetworkAddress.isLocalHost(ip) else { continue }
            let interface = RemoteLANInterface(name: name, address: ip, netmask: netmask, kind: kind)
            if interface.mask != nil { result.append(interface) }
        }
        cache.interfaces = ordered(result); cache.until = Date().addingTimeInterval(1)
        return cache.interfaces
    }
    public static func ordered(_ interfaces: [RemoteLANInterface]) -> [RemoteLANInterface] {
        interfaces.sorted { ($0.kind == .wifi ? 0 : 1, $0.name, $0.address) < ($1.kind == .wifi ? 0 : 1, $1.name, $1.address) }
    }
    /// Give every physical LAN an early slot, even with a large first subnet.
    public static func interleaved(_ groups: [[String]], excluding: Set<String> = [], limit: Int) -> [String] {
        var result: [String] = [], seen = excluding
        for index in 0..<(groups.map(\.count).max() ?? 0) {
            for group in groups where index < group.count {
                if seen.insert(group[index]).inserted { result.append(group[index]) }
                if result.count >= limit { return result }
            }
        }
        return result
    }
    public static func discoveryURLs(interfaces: [RemoteLANInterface]) -> [String] {
        interleaved(ordered(interfaces).map { RemoteNetworkAddress.discoveryURLs(address:$0.address,netmask:$0.netmask) },
            excluding:Set(interfaces.map {"http://\($0.address):8765"}),limit:512)
    }
    public static func discoveryLane(_ address: String, interfaces: [RemoteLANInterface]) -> String {
        guard let host = URLComponents(string:address)?.host else { return address }
        if let source = route(to:host,interfaces:interfaces) { return source.name }
        return host.split(separator:".").prefix(3).joined(separator:".")
    }
    public static func sharesClientLAN(_ address: String, client: String?, interfaces: [RemoteLANInterface]) -> Bool {
        guard let client, client != "::1", !client.hasPrefix("127.") else { return true }
        guard let source = route(to:client,interfaces:interfaces),
              let destination = route(to:address,interfaces:interfaces) else { return false }
        return source.name == destination.name
    }
    /// Read the existing OS neighbor cache only. -n prevents DNS lookups; no ping or ARP mutation.
    public static func neighborURLs() -> [String] {
        guard let result = try? CommandRunner.run("/usr/sbin/arp", ["-an"], timeout: 1), result.status == 0 else { return [] }
        return neighborURLs(from: result.output, interfaces: interfaces())
    }
    public static func neighborURLs(from text: String, interfaces: [RemoteLANInterface]) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"\(([0-9.]+)\) at ([0-9a-fA-F:]+) on (en[0-9]+)\b"#)
        var result: [String: [String]] = [:], seen = Set<String>()
        for line in text.components(separatedBy: .newlines).prefix(2048) {
            let value = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: value.length)) else { continue }
            let address = value.substring(with: match.range(at: 1)), hardware = value.substring(with: match.range(at: 2)), name = value.substring(with: match.range(at: 3))
            guard hardware != "ff:ff:ff:ff:ff:ff", !interfaces.contains(where: { $0.address == address }),
                  let source = route(to: address, interfaces: interfaces), source.name == name,
                  let host = ipv4(address), let local = ipv4(source.address), let mask = source.mask,
                  host > (local & mask), host < ((local & mask) | ~mask), seen.insert(address).inserted else { continue }
            result[source.name,default:[]].append("http://\(address):8765")
        }
        return interleaved(ordered(interfaces).map { result[$0.name] ?? [] },limit:64)
    }
    public static func route(to address: String, interfaces: [RemoteLANInterface]) -> RemoteLANInterface? {
        guard let host = ipv4(address) else { return nil }
        return ordered(interfaces).filter { $0.contains(host) }.sorted { ($0.mask ?? 0) > ($1.mask ?? 0) }.first
    }
    public static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = false
        parameters.prohibitedInterfaceTypes = [.other, .cellular]
        return parameters
    }
    /// Use a verified peer's published physical address before resolving Bonjour
    /// again. A service can advertise both Ethernet and Wi-Fi (and IPv6), while
    /// only one of those networks is shared with the requesting Mac.
    public static func preferredEndpoint(_ fallback: NWEndpoint, addresses: [String], port: UInt16,
                                         interfaces: [RemoteLANInterface]) -> NWEndpoint {
        let candidates = addresses.enumerated().compactMap { index, address -> (NWEndpoint, Int, Int)? in
            guard let endpoint = try? RemoteNetworkAddress.endpoint(address),
                  case .hostPort(let host, let publishedPort) = endpoint, publishedPort.rawValue == port,
                  let ip = ipv4(String(describing: host)), ip >> 24 != 127,
                  !interfaces.contains(where: { $0.address == String(describing: host) }),
                  let source = route(to: String(describing: host), interfaces: interfaces) else { return nil }
            return (endpoint, source.kind == .wifi ? 0 : 1, index)
        }
        return candidates.min { ($0.1, $0.2) < ($1.1, $1.2) }?.0 ?? fallback
    }
    public static func tcpParameters(to endpoint: NWEndpoint, interfaces: [RemoteLANInterface]) throws -> NWParameters {
        let parameters = tcpParameters()
        guard case .hostPort(let host, _) = endpoint else { return parameters }
        let address = String(describing: host)
        guard let number = ipv4(address) else { return parameters }
        // Local fixtures and a Mac opening its own LAN address use the loopback route.
        if number >> 24 == 127 || interfaces.contains(where: { $0.address == address }) { return parameters }
        guard let source = route(to: address, interfaces: interfaces) else {
            throw RemoteHTTPError(503, "이 Mac은 현재 Wi-Fi·유선 LAN에서 찾을 수 없습니다. 같은 핫스팟에 연결했는지 확인해주세요.")
        }
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(source.address), port: .any)
        parameters.requiredInterfaceType = source.kind == .wifi ? .wifi : .wiredEthernet
        return parameters
    }
    fileprivate static func ipv4(_ address: String) -> UInt32? {
        IPv4Address(address)?.rawValue.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
