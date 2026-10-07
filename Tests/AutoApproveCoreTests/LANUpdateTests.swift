import Foundation
import AutoApproveCore

extension ApprovalTests {
    func testLANUpdateRejectsWrongPeerDowngradeArchitectureAndOversize() throws {
        let id = "00000000-0000-4000-8000-000000000001", current = RemoteWebVersion(version: "0.2.52", build: 63)
        let valid = LANUpdateManifest(nodeID: id, release: RemoteWebVersion(version: "0.2.53", build: 64), size: 1_000, sha256: String(repeating: "a", count: 64))
        try valid.validate(nodeID: id, newerThan: current)
        var variants: [LANUpdateManifest] = []
        var value = valid; value.nodeID = UUID().uuidString; variants.append(value)
        value = valid; value.release = current; variants.append(value)
        value = valid; value.release = RemoteWebVersion(version: "0.2.51", build: 99); variants.append(value)
        value = valid; value.architecture = "unsupported"; variants.append(value)
        value = valid; value.size = LANUpdateManifest.maximumSize + 1; variants.append(value)
        value = valid; value.sha256 = String(repeating: "z", count: 64); variants.append(value)
        value = valid; value.protocolVersion = 2; variants.append(value)
        value = valid; value.release.api = 2; variants.append(value)
        for invalid in variants {
            do { try invalid.validate(nodeID: id, newerThan: current); throw AppError.message("Invalid update was accepted") }
            catch { try expect(error.localizedDescription != "Invalid update was accepted") }
        }
    }
    func testLANUpdateArchiveRejectsTraversalLinksDuplicatesAndBombs() throws {
        let entries = ["AutoApprove.app/Contents/Info.plist", "AutoApprove.app/Contents/MacOS/AutoApproveApp"]
        try LANUpdateInstallation.validateArchive(updateZIP(entries))
        for data in [
            updateZIP(entries + ["AutoApprove.app/../escaped"]),
            updateZIP(entries + ["/AutoApprove.app/escaped"]),
            updateZIP(entries + ["AutoApprove.app/linked"], mode: 0xa000),
            updateZIP(entries + [entries[0].uppercased()]),
            updateZIP(entries, uncompressed: 70 * 1_024 * 1_024),
            updateZIP(entries, unicodeExtra: true),
            updateZIP(entries, unixLinkExtra: true),
            Data(updateZIP(entries).dropLast())
        ] {
            do { try LANUpdateInstallation.validateArchive(data); throw AppError.message("Unsafe archive was accepted") }
            catch { try expect(error.localizedDescription != "Unsafe archive was accepted") }
        }
    }
    func testLANUpdatePreferenceSurvivesEngineRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-update-preference-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(directory: directory)
        let first = try ApprovalEngine(paths: paths)
        try expect(first.lanUpdate.enabled)
        try first.setLANUpdateEnabled(false)
        let second = try ApprovalEngine(paths: paths)
        try expect(!second.lanUpdate.enabled); try expectEqual(second.lanUpdate.phase, "off")
        try second.setLANUpdateEnabled(true)
        let third = try ApprovalEngine(paths: paths)
        try expect(third.lanUpdate.enabled)
    }
    private func updateZIP(_ names: [String], mode: UInt64 = 0x8000, uncompressed: UInt64 = 0, unicodeExtra: Bool = false, unixLinkExtra: Bool = false) -> Data {
        func bytes(_ number: UInt64, _ count: Int) -> Data { Data((0..<count).map { UInt8((number >> ($0 * 8)) & 255) }) }
        func fields(_ values: [(UInt64, Int)]) -> Data {
            var data = Data()
            for (number, count) in values { data.append(bytes(number, count)) }
            return data
        }
        var locals = Data(), central = Data()
        for name in names {
            let text = Data(name.utf8), offset = UInt64(locals.count)
            let extra = unicodeExtra || unixLinkExtra ? bytes(unixLinkExtra ? 0x000d : 0x7075, 2) + bytes(0, 2) : Data()
            locals += fields([(0x04034b50, 4), (20, 2), (0, 2), (0, 2), (0, 4), (0, 4), (0, 4), (uncompressed, 4), (UInt64(text.count), 2), (UInt64(extra.count), 2)])
            locals.append(text); locals.append(extra)
            central += fields([(0x02014b50, 4), (0x0314, 2), (20, 2), (0, 2), (0, 2), (0, 4), (0, 4), (0, 4), (uncompressed, 4), (UInt64(text.count), 2), (UInt64(extra.count), 2), (0, 2), (0, 2), (0, 2), (mode << 16, 4), (offset, 4)])
            central.append(text); central.append(extra)
        }
        return locals + central + fields([(0x06054b50, 4), (0, 4), (UInt64(names.count), 2), (UInt64(names.count), 2), (UInt64(central.count), 4), (UInt64(locals.count), 4), (0, 2)])
    }
}
