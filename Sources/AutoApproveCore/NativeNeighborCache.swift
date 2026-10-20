import Foundation
import Darwin

/// A fresh, read-only IPv4 link-layer snapshot. It is a discovery hint, never
/// process identity or permission to send input. No neighbor data survives a read.
enum NativeNeighborCache {
    struct Entry: Equatable {
        let address: String
        let interfaceName: String
        let broadcast: Bool
    }
    typealias Query = (UnsafeMutableRawPointer?, inout Int) throws -> Void
    static let maximumBytes = 32 * 1024 * 1024
    static let maximumEntries = 2048

    static func read() throws -> [Entry] {
        try entries(from: snapshot(), interfaceName: name)
    }

    static func snapshot(query: Query = kernelQuery) throws -> Data {
        for _ in 0..<3 {
            try Task.checkCancellation()
            var length = 0
            try query(nil, &length)
            guard length >= 0, length <= maximumBytes else { throw POSIXError(.EOVERFLOW) }
            if length == 0 { return Data() }
            var bytes = Data(count: length)
            do { try bytes.withUnsafeMutableBytes { try query($0.baseAddress, &length) } }
            catch let error as POSIXError where error.code == .ENOMEM { continue }
            guard length >= 0, length <= bytes.count else { throw POSIXError(.EIO) }
            bytes.removeSubrange(length..<bytes.count)
            return bytes
        }
        throw POSIXError(.ENOMEM)
    }

    private static func kernelQuery(_ output: UnsafeMutableRawPointer?, _ length: inout Int) throws {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        errno = 0
        guard sysctl(&mib, UInt32(mib.count), output, &length, nil, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func name(_ index: UInt32) -> String? {
        guard index > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        return if_indextoname(index, &buffer) == nil ? nil : String(cString: buffer)
    }

    static func entries(from data: Data, interfaceName: (UInt32) -> String?) throws -> [Entry] {
        guard data.count <= maximumBytes else { throw POSIXError(.EOVERFLOW) }
        return try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var offset = 0, examined = 0, result: [Entry] = []
            var names: [UInt32: String?] = [:]
            let headerSize = MemoryLayout<rt_msghdr>.size
            while offset < bytes.count, examined < maximumEntries {
                try Task.checkCancellation()
                guard bytes.count - offset >= headerSize else { throw POSIXError(.EINVAL) }
                let header = bytes.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
                let length = Int(header.rtm_msglen)
                guard length >= headerSize, length <= bytes.count - offset,
                      header.rtm_version == RTM_VERSION, header.rtm_type == RTM_GET,
                      header.rtm_addrs >= 0, header.rtm_addrs & ~((1 << RTAX_MAX) - 1) == 0 else { throw POSIXError(.EINVAL) }
                let end = offset + length
                var cursor = offset + headerSize, destination: Range<Int>?, link: Range<Int>?
                for field in 0..<Int(RTAX_MAX) where header.rtm_addrs & (1 << field) != 0 {
                    guard end - cursor >= 2 else { throw POSIXError(.EINVAL) }
                    let size = Int(bytes[cursor]), padded = max(4, (size + 3) & ~3)
                    guard padded <= end - cursor else { throw POSIXError(.EINVAL) }
                    if field == RTAX_DST { destination = cursor..<(cursor + size) }
                    if field == RTAX_GATEWAY { link = cursor..<(cursor + size) }
                    cursor += padded
                }
                guard cursor == end, let destination, let link,
                      destination.count >= 8, link.count >= 8 else { throw POSIXError(.EINVAL) }
                offset = end; examined += 1
                guard bytes[destination.lowerBound + 1] == AF_INET,
                      bytes[link.lowerBound + 1] == AF_LINK else { continue }
                let start = link.lowerBound
                let nameLength = Int(bytes[start + 5]), hardwareLength = Int(bytes[start + 6]), selectorLength = Int(bytes[start + 7])
                guard nameLength + hardwareLength + selectorLength <= link.count - 8 else { throw POSIXError(.EINVAL) }
                guard hardwareLength > 0 else { continue }
                let index = UInt32(bytes.loadUnaligned(fromByteOffset: start + 2, as: UInt16.self))
                let resolved: String?
                if let cached = names[index] { resolved = cached }
                else { resolved = interfaceName(index); names[index] = .some(resolved) }
                guard let resolved else { continue }
                let ip = destination.lowerBound + 4, hardware = start + 8 + nameLength
                let address = "\(bytes[ip]).\(bytes[ip + 1]).\(bytes[ip + 2]).\(bytes[ip + 3])"
                let broadcast = hardwareLength == 6 && (0..<6).allSatisfy { bytes[hardware + $0] == 255 }
                result.append(Entry(address: address, interfaceName: resolved, broadcast: broadcast))
            }
            return result
        }
    }
}
