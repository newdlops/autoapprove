import Foundation
import AutoApproveCore

extension ApprovalTests {
    func testDiscoveryNeighborHintsAndNearbyOrder() throws {
        let wifi = RemoteLANInterface(name: "en0", address: "192.168.43.8", netmask: "255.255.255.0", kind: .wifi)
        let ethernet = RemoteLANInterface(name: "en7", address: "10.2.3.4", netmask: "255.255.255.0", kind: .ethernet)
        let table = """
        ? (10.2.3.9) at 1:2:3:4:5:6 on en7 ifscope [ethernet]
        ? (192.168.43.9) at 2:3:4:5:6:7 on en0 ifscope [ethernet]
        ? (192.168.43.8) at 3:4:5:6:7:8 on en0 ifscope [ethernet]
        ? (192.168.43.10) at (incomplete) on en0 ifscope [ethernet]
        ? (192.168.43.255) at ff:ff:ff:ff:ff:ff on en0 ifscope [ethernet]
        ? (10.2.3.10) at 4:5:6:7:8:9 on utun4 ifscope [ethernet]
        ? (8.8.8.8) at 5:6:7:8:9:a on en7 ifscope [ethernet]
        ? (192.168.43.9) at 2:3:4:5:6:7 on en0 ifscope [ethernet]
        """
        try expectEqual(RemoteLAN.neighborURLs(from: table, interfaces: [ethernet,wifi]), ["http://192.168.43.9:8765","http://10.2.3.9:8765"])
        let addresses = RemoteNetworkAddress.discoveryURLs(address: wifi.address, netmask: wifi.netmask)
        try expectEqual(Array(addresses.prefix(4)), ["http://192.168.43.7:8765","http://192.168.43.9:8765","http://192.168.43.6:8765","http://192.168.43.10:8765"])
        try expectEqual(Set(addresses).count, 253)
        try expect(!addresses.contains("http://192.168.43.0:8765") && !addresses.contains("http://192.168.43.255:8765"))
        let wider = RemoteLANInterface(name: "en0", address: "10.2.3.4", netmask: "255.255.0.0", kind: .wifi)
        try expectEqual(RemoteLAN.neighborURLs(from: "? (10.2.8.9) at 1:2:3:4:5:6 on en0 ifscope [ethernet]", interfaces: [wider]), ["http://10.2.8.9:8765"], "Known neighbors on the actual subnet are not restricted by the blind scan's /24 cap")
    }
}
