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
        let both = RemoteLAN.discoveryURLs(interfaces:[ethernet,wifi])
        try expectEqual(Array(both.prefix(4)),["http://192.168.43.7:8765","http://10.2.3.3:8765","http://192.168.43.9:8765","http://10.2.3.5:8765"])
        try expectEqual(both.count,506); try expectEqual(Set(both).count,506)
        try expect(!both.contains("http://192.168.43.8:8765") && !both.contains("http://10.2.3.4:8765"))
        let busyTable = (10...100).map {"? (192.168.43.\($0)) at 1:2:3:4:5:6 on en0 ifscope [ethernet]"}.joined(separator:"\n") + "\n? (10.2.3.9) at 1:2:3:4:5:6 on en7 ifscope [ethernet]"
        let hints = RemoteLAN.neighborURLs(from:busyTable,interfaces:[wifi,ethernet])
        try expectEqual(hints.count,64); try expectEqual(hints[1],"http://10.2.3.9:8765","A busy Wi-Fi neighbor cache cannot exclude Ethernet")
        try expectEqual(RemoteLAN.discoveryLane(both[0],interfaces:[wifi,ethernet]),"en0")
        try expectEqual(RemoteLAN.discoveryLane(both[1],interfaces:[wifi,ethernet]),"en7")
        let third = RemoteLANInterface(name:"en8",address:"172.20.10.4",netmask:"255.255.255.0",kind:.ethernet)
        let capped = RemoteLAN.discoveryURLs(interfaces:[wifi,ethernet,third])
        try expectEqual(capped.count,512); try expect(capped[2].contains("172.20.10."))
        try expect(RemoteLAN.sharesClientLAN("192.168.43.9",client:"192.168.43.1",interfaces:[wifi,ethernet]))
        try expect(!RemoteLAN.sharesClientLAN("10.2.3.9",client:"192.168.43.1",interfaces:[wifi,ethernet]))
        try expect(RemoteLAN.sharesClientLAN("10.2.3.9",client:"10.2.3.10",interfaces:[wifi,ethernet]))
        try expect(!RemoteLAN.sharesClientLAN("192.168.43.9",client:"10.2.3.10",interfaces:[wifi,ethernet]))
        try expect(!RemoteLAN.sharesClientLAN("10.2.3.9",client:"fe80::1",interfaces:[wifi,ethernet]))
        try expect(RemoteLAN.sharesClientLAN("10.2.3.9",client:"127.0.0.1",interfaces:[wifi,ethernet]))
    }
}
