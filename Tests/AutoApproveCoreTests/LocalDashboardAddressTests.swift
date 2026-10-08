import Foundation
import Darwin
import AutoApproveCore

extension ApprovalTests {
    func testLocalDashboardNamePreservesHostFileAndOnlyMapsSelf() throws {
        let original = "127.0.0.1 localhost\n::1 localhost\n192.168.1.9 internal.example # keep\n"
        let prepared = try LocalDashboardAddress.prepared(original)
        try expect(prepared.hasPrefix(original))
        try expect(prepared.contains("127.0.0.1 autoapprove\n::1 autoapprove\n"))
        try expectEqual(LocalDashboardAddress.status(in:prepared),.ready)
        try expectEqual(try LocalDashboardAddress.prepared(prepared),prepared,"Installing twice cannot duplicate aliases")
        for conflict in ["10.1.2.3 autoapprove","0.0.0.0 autoapprove","::2 other AUTOAPPROVE."] {
            try expectEqual(LocalDashboardAddress.status(in:original+conflict),.conflict)
            try expectThrows(try LocalDashboardAddress.prepared(original+conflict))
        }
        try expectEqual(LocalDashboardAddress.status(in:"# autoapprove\n127.0.0.1 autoapprove-other .autoapprove\n"),.missing)
        try expectEqual(LocalDashboardAddress.status(in:"::1 AUTOAPPROVE.\n"),.ready)
        let directory = URL(fileURLWithPath:"/private/tmp/aa-local-address-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        let file = directory.appendingPathComponent("hosts"),backup = directory.appendingPathComponent("backup")
        try Data(original.utf8).write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o640],ofItemAtPath:file.path)
        let before = try FileManager.default.attributesOfItem(atPath:file.path)
        try LocalDashboardAddress.apply(to:file,backup:backup)
        try expectEqual(try String(contentsOf:file,encoding:.utf8),prepared)
        try expectEqual(try String(contentsOf:backup,encoding:.utf8),original)
        let after = try FileManager.default.attributesOfItem(atPath:file.path)
        for attribute in [FileAttributeKey.posixPermissions,.ownerAccountID,.groupOwnerAccountID,.systemFileNumber] {
            try expectEqual(before[attribute] as? NSNumber,after[attribute] as? NSNumber)
        }
        try expectEqual((try FileManager.default.attributesOfItem(atPath:backup.path))[.posixPermissions] as? NSNumber,NSNumber(value:0o600))
        try LocalDashboardAddress.apply(to:file,backup:backup)
        let symlink = directory.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at:symlink,withDestinationURL:file)
        try expectThrows(try LocalDashboardAddress.apply(to:symlink,backup:directory.appendingPathComponent("no-backup")))
        try expectEqual(try String(contentsOf:file,encoding:.utf8),prepared)
    }
    func testLocalDashboardOriginKeepsExactSameOriginRules() throws {
        for host in ["autoapprove:8765","AUTOAPPROVE.:8765"] {
            let request = "POST /api/action HTTP/1.1\r\nHost: \(host)\r\nOrigin: http://\(host)\r\nContent-Length: 0\r\n\r\n"
            try RemoteHTTPRequest.parse(Data(request.utf8))!.validateOrigin()
            try expectThrows(try RemoteHTTPRequest.parse(Data(request.replacingOccurrences(of:"Origin: http://\(host)",with:"Origin: http://foreign.local:8765").utf8))!.validateOrigin())
        }
        let foreign = "POST /api/action HTTP/1.1\r\nHost: autoapprove.evil.example:8765\r\nContent-Length: 0\r\n\r\n"
        try expectThrows(try RemoteHTTPRequest.parse(Data(foreign.utf8))!.validateOrigin())
    }
}
